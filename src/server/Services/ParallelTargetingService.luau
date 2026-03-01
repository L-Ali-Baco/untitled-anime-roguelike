--!strict
--[[
	ParallelTargetingService.luau
	==============================
	Orchestrates parallel enemy target-selection using Roblox Actors.
	This service lives in the MAIN thread (ServerScriptService.Server.Services).
	It distributes enemy batches to N TargetingActors, collects results from the
	SharedTable, and exposes GetTargets() for EnemyService / BaseEnemy to consume.

	ARCHITECTURE OVERVIEW:
	  ┌─────────────────────────────────────────────────────────────┐
	  │  Main Thread (ParallelTargetingService)                     │
	  │                                                             │
	  │  Heartbeat:                                                 │
	  │    1. Gather enemy positions from EnemyService              │
	  │    2. Gather player positions from Players service          │
	  │    3. Split enemies into N batches (one per Actor)          │
	  │    4. actor:SendMessage("ComputeTargets", batch, ...)       │
	  │    5. Wait for all actors to write done_<i> == batchId      │
	  │    6. Read results from SharedTable                         │
	  │    7. Store in _targetCache[enemyId] = {playerId, distSq}  │
	  └─────────────────────────────────────────────────────────────┘
	          │SendMessage          ▲ SharedTable writes
	          ▼                     │
	  ┌─────────────────────────────────────────────────────────────┐
	  │  Parallel Threads (TargetingActor × N)                     │
	  │                                                             │
	  │  BindToMessageParallel("ComputeTargets"):                   │
	  │    - Compute closest player for each enemy in batch         │
	  │    - task.synchronize()                                     │
	  │    - Write results + done signal to SharedTable             │
	  └─────────────────────────────────────────────────────────────┘

	INTEGRATION WITH EnemyService:
	  EnemyService calls ParallelTargetingService:GetTarget(enemyId) each tick
	  instead of computing distance inline. The result is 1-frame stale (computed
	  during the previous Heartbeat), which is imperceptible for AI decisions.

	SETUP REQUIRED IN STUDIO:
	  1. ServerScriptService.Server.Actors/ — folder of Actor instances.
	  2. Each Actor contains a copy of TargetingActor.server.luau.
	  3. Actor count = NUM_ACTORS constant below (default 4).
	     Match this to the number of physical server CPU cores (typically 4–8
	     on Roblox's cloud servers; 4 is a safe default).
]]

-- ── Imports ──────────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-- ── Constants ─────────────────────────────────────────────────────────────────

-- Number of Actor workers. Each actor runs on its own OS thread.
-- Diminishing returns beyond the physical core count of the server.
local NUM_ACTORS: number = 4

-- How often (seconds) we recompute targets. AI decisions don't need
-- sub-frame precision — once every 0.1 s (6 Heartbeats at 60 Hz) is plenty.
local COMPUTE_INTERVAL: number = 0.1

-- Maximum time (seconds) to wait for all actors to report done before
-- giving up and using the last-known results. Prevents a stalled actor
-- from blocking the main thread indefinitely.
local ACTOR_TIMEOUT: number = 0.5

-- ── Service Declaration ───────────────────────────────────────────────────────

local ParallelTargetingService = {}
ParallelTargetingService.Name = "ParallelTargetingService"

-- ── Private State ─────────────────────────────────────────────────────────────

-- Array of Actor instances.
local _actors: { Actor } = {}

-- The SharedTable written to by actors and read by this service.
local _sharedOutput: SharedTable

-- Monotonically increasing batch counter. Incremented each compute cycle.
-- Used to match results to the correct batch and discard stale data.
local _batchId: number = 0

-- Result cache: maps enemyId (number) -> { playerId: number, distSq: number }
-- Written by _processResults(), read by GetTarget().
local _targetCache: { [number]: { playerId: number, distSq: number } } = {}

-- Timer accumulator for the compute interval.
local _timer: number = 0

-- External reference to the enemy registry.
-- Injected in Init() to avoid circular requires.
-- Expected shape: { [enemyId]: { rootPart: BasePart, id: number } }
local _enemyRegistry: { [number]: { rootPart: BasePart, id: number } } = {}

-- ── Init ──────────────────────────────────────────────────────────────────────

function ParallelTargetingService:Init()
	-- Create the SharedTable that actors write results into.
	-- SharedTable is constructed on the main thread; actors receive it
	-- via the Init message and use SharedTable.rawset() to write.
	_sharedOutput = SharedTable.new()

	-- Locate the Actors folder.
	-- Structure: ServerScriptService > Server > Actors > TargetingActor1..N
	local actorsFolder = ServerScriptService:FindFirstChild("Server")
		and ServerScriptService.Server:FindFirstChild("Actors")
	assert(actorsFolder, "[ParallelTargetingService] Missing ServerScriptService.Server.Actors folder.")

	-- Collect all Actor instances and send them the Init message.
	local index = 0
	for _, child in actorsFolder:GetChildren() do
		if child:IsA("Actor") then
			index += 1
			_actors[index] = child :: Actor
			-- Send the SharedTable and actor index to the actor's Init handler.
			-- SendMessage is fire-and-forget; the actor processes it asynchronously.
			child:SendMessage("Init", _sharedOutput, index)
		end
	end

	assert(
		#_actors > 0,
		"[ParallelTargetingService] No Actor instances found in Actors folder."
	)
	assert(
		#_actors == NUM_ACTORS,
		string.format(
			"[ParallelTargetingService] Expected %d actors, found %d. Update NUM_ACTORS or add/remove actors.",
			NUM_ACTORS,
			#_actors
		)
	)
end

-- ── Start ─────────────────────────────────────────────────────────────────────

function ParallelTargetingService:Start()
	-- Drive compute cycles via Heartbeat rather than a while loop.
	-- Heartbeat is called after physics simulation, so enemy positions
	-- reflect the latest physics state when we read them.
	RunService.Heartbeat:Connect(function(dt: number)
		_timer += dt
		if _timer < COMPUTE_INTERVAL then
			return
		end
		_timer = 0
		self:_computeTargets()
	end)
end

-- ── Inject Enemy Registry ─────────────────────────────────────────────────────

--[[
	ParallelTargetingService:SetEnemyRegistry(registry)

	Called by EnemyService during its Init phase to provide the live enemy table.
	Uses injection rather than require(EnemyService) to avoid circular dependencies.

	@param registry  {[number]: {rootPart: BasePart, id: number}}
]]
function ParallelTargetingService:SetEnemyRegistry(
	registry: { [number]: { rootPart: BasePart, id: number } }
)
	_enemyRegistry = registry
end

-- ── Private: Compute Targets ──────────────────────────────────────────────────

--[[
	ParallelTargetingService:_computeTargets()

	Main compute cycle. Runs on the main thread. Gathers data, distributes to
	actors, waits for completion, and processes results.
]]
function ParallelTargetingService:_computeTargets()
	-- ── Gather player positions ───────────────────────────────────────────
	-- Build a flat number array for efficient SendMessage copying.
	-- Format: [X, Z, Y, X, Z, Y, ...]  (stride 3 per player)
	local playerPositions: { number } = {}
	local activePlayers = Players:GetPlayers()
	local playerIdMap: { [number]: Player } = {} -- index → Player
	local pi = 0

	for _, player in activePlayers do
		local char = player.Character
		if char then
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				pi += 1
				playerIdMap[pi] = player
				local pos = hrp.Position
				playerPositions[pi * 3 - 2] = pos.X
				playerPositions[pi * 3 - 1] = pos.Z
				playerPositions[pi * 3] = pos.Y
			end
		end
	end

	-- No players alive → nothing to target. Clear cache and return.
	if pi == 0 then
		table.clear(_targetCache)
		return
	end

	-- ── Gather enemy data ─────────────────────────────────────────────────
	-- Flat array: [enemyId, X, Z, Y, enemyId, X, Z, Y, ...]  (stride 4)
	local allEnemyData: { number } = {}
	local enemyIdList: { number } = {} -- ordered list of enemy IDs in the array
	local ei = 0

	for enemyId, enemy in _enemyRegistry do
		if enemy.rootPart and enemy.rootPart.Parent then
			ei += 1
			enemyIdList[ei] = enemyId
			local pos = enemy.rootPart.Position
			local base = (ei - 1) * 4
			allEnemyData[base + 1] = enemyId
			allEnemyData[base + 2] = pos.X
			allEnemyData[base + 3] = pos.Z
			allEnemyData[base + 4] = pos.Y
		end
	end

	-- No enemies → nothing to compute.
	if ei == 0 then
		return
	end

	-- ── Split enemies into batches ────────────────────────────────────────
	-- Distribute enemies as evenly as possible across NUM_ACTORS workers.
	-- Each batch is a flat number array (same format as allEnemyData).
	_batchId += 1
	local currentBatchId = _batchId
	local numActors = #_actors
	local stride = 4 -- numbers per enemy entry

	-- Pre-clear the done signals for this batch so we don't misread old values.
	for i = 1, numActors do
		SharedTable.rawset(_sharedOutput, string.format("done_%d", i), -1)
	end

	-- Compute batch boundaries and send to actors.
	local enemiesPerActor = math.ceil(ei / numActors)
	for actorIdx = 1, numActors do
		local startEnemy = (actorIdx - 1) * enemiesPerActor + 1
		local endEnemy = math.min(actorIdx * enemiesPerActor, ei)

		if startEnemy > ei then
			-- This actor gets an empty batch if enemy count < numActors.
			-- Send an empty array so the actor still fires its done signal.
			_actors[actorIdx]:SendMessage("ComputeTargets", {}, playerPositions, currentBatchId)
		else
			-- Slice the flat array for this actor's batch.
			local batch: { number } = {}
			local bi = 0
			for e = startEnemy, endEnemy do
				local srcBase = (e - 1) * stride
				bi += 1
				batch[bi] = allEnemyData[srcBase + 1] -- enemyId
				bi += 1
				batch[bi] = allEnemyData[srcBase + 2] -- X
				bi += 1
				batch[bi] = allEnemyData[srcBase + 3] -- Z
				bi += 1
				batch[bi] = allEnemyData[srcBase + 4] -- Y
			end
			_actors[actorIdx]:SendMessage("ComputeTargets", batch, playerPositions, currentBatchId)
		end
	end

	-- ── Wait for all actors to complete ──────────────────────────────────
	-- Poll the SharedTable for done signals. We use task.wait(0) to yield
	-- the current frame rather than busy-waiting, allowing other Heartbeat
	-- tasks to run. The timeout guard prevents indefinite blocking if an
	-- actor stalls (e.g. due to a bug in TargetingActor.server.luau).
	local deadline = os.clock() + ACTOR_TIMEOUT
	local allDone = false

	while not allDone and os.clock() < deadline do
		allDone = true
		for i = 1, numActors do
			local doneKey = string.format("done_%d", i)
			local doneVal = SharedTable.get(_sharedOutput, doneKey)
			if doneVal ~= currentBatchId then
				allDone = false
				break
			end
		end
		if not allDone then
			-- Yield for one scheduler tick without sleeping a fixed duration.
			-- task.wait(0) yields until the next Heartbeat, keeping CPU usage low.
			task.wait()
		end
	end

	if not allDone then
		warn(string.format(
			"[ParallelTargetingService] Batch %d timed out after %.2f s. Using stale results.",
			currentBatchId,
			ACTOR_TIMEOUT
		))
		return -- keep _targetCache from the last successful batch
	end

	-- ── Process results ───────────────────────────────────────────────────
	-- Read each actor's result flat array and populate _targetCache.
	-- Result format from actors: [enemyId, playerId, distSq, ...]  (stride 3)
	for i = 1, numActors do
		local resultKey = string.format("results_%d_%d", i, currentBatchId)
		local rawResults = SharedTable.get(_sharedOutput, resultKey)

		-- rawResults may be nil if the actor received an empty batch.
		if rawResults and type(rawResults) == "table" then
			local n = #rawResults
			local rs = 3 -- result stride
			for r = 1, n / rs do
				local base = (r - 1) * rs
				local enemyId = rawResults[base + 1]
				local closestPlayerId = rawResults[base + 2]
				local closestDistSq = rawResults[base + 3]

				-- Write to the cache. This is read by EnemyService on the main
				-- thread — the write happens here on the main thread too (we're
				-- past task.synchronize() in the actor), so no race condition.
				_targetCache[enemyId] = {
					playerId = closestPlayerId, -- 1-based index into activePlayers
					distSq = closestDistSq,
				}
			end
		end

		-- Clean up result keys to keep SharedTable compact.
		SharedTable.rawset(_sharedOutput, resultKey, nil)
	end
end

-- ── Public: GetTarget ─────────────────────────────────────────────────────────

--[[
	ParallelTargetingService:GetTarget(enemyId) -> (Player?, number)

	Returns the closest player and squared distance for the given enemy,
	based on results from the last completed compute cycle.

	Results are at most COMPUTE_INTERVAL seconds stale — imperceptible for AI.
	Returns nil, math.huge if no result is cached (e.g. first frame after spawn).

	@param enemyId  number  The unique ID of the enemy (from its registry entry).
	@return         Player? The closest player (may be nil if no players alive).
	@return         number  Squared distance to that player (math.huge if none).
]]
function ParallelTargetingService:GetTarget(enemyId: number): (Player?, number)
	local cached = _targetCache[enemyId]
	if not cached then
		return nil, math.huge
	end

	-- Resolve the player from the ID. Players may have disconnected since the
	-- last compute cycle, so we validate before returning.
	local activePlayers = Players:GetPlayers()
	local player = activePlayers[cached.playerId]
	if not player or not player.Character then
		return nil, math.huge
	end

	return player, cached.distSq
end

-- ── Public: InvalidateEnemy ───────────────────────────────────────────────────

--[[
	ParallelTargetingService:InvalidateEnemy(enemyId)

	Removes a dead/despawned enemy from the target cache.
	Call this from EnemyService when an enemy is removed from the registry.

	@param enemyId  number
]]
function ParallelTargetingService:InvalidateEnemy(enemyId: number)
	_targetCache[enemyId] = nil
end

-- ── Return ────────────────────────────────────────────────────────────────────

return ParallelTargetingService
