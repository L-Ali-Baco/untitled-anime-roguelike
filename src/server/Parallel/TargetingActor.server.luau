--!strict
--[[
	TargetingActor.server.luau
	==========================
	This script runs INSIDE a Roblox Actor instance. Each Actor is an independent
	execution context that can run Luau code in a dedicated OS thread, enabling
	true multi-core parallelism on the server.

	═══════════════════════════════════════════════════════════════════════════════
	PARALLEL LUAU — HOW IT WORKS (THEORY)
	═══════════════════════════════════════════════════════════════════════════════

	ROBLOX'S THREADING MODEL (without Parallel Luau):
	  Roblox runs a single Lua state on the main thread. All Heartbeat callbacks,
	  RemoteEvent handlers, and coroutines share this one thread. Even though you
	  can have thousands of coroutines, they all time-slice on the SAME CPU core.
	  Luau has no OS-level threads without the Parallel Luau API.

	ACTORS:
	  An Actor is a special Roblox Instance that serves as an isolation boundary
	  for a Luau VM. Scripts (Script / LocalScript) placed INSIDE an Actor
	  instance run in their own Luau state, decoupled from the main thread. The
	  Actor is the unit of parallelism — you spawn N Actors to get N parallel
	  execution contexts.

	  Actors communicate with each other (and with the main thread) exclusively
	  via two mechanisms:
	    1. Actor:SendMessage(topic, ...) — sends a message to a specific Actor.
	    2. Actor:BindToMessage(topic, fn) — synchronous handler (main thread only).
	    3. Actor:BindToMessageParallel(topic, fn) — handler that runs in PARALLEL.

	  There is NO shared mutable state between Actors. Luau tables, closures,
	  and upvalues are NOT shared. The only safe inter-actor data structures are:
	    - SharedTable — a Roblox API for a thread-safe key-value store.
	    - Immutable primitives passed via SendMessage (numbers, strings, Vector3s,
	      CFrames, booleans — all are copied by value, not by reference).

	task.desynchronize() — MOVING OFF THE MAIN THREAD:
	  Within a Script that runs inside an Actor, calling task.desynchronize()
	  yields the current coroutine from the main thread and resumes it on a
	  worker thread from Roblox's internal thread pool.

	  While desynchronized, you CAN:
	    - Read Instance properties (position, attributes, etc.) — reads are safe.
	    - Perform pure computation (math, table operations, string manipulation).
	    - Write to SharedTable entries.

	  While desynchronized, you CANNOT (causes an error or undefined behaviour):
	    - Write to Instance properties (fires a "cannot write in parallel" error).
	    - Call most Roblox services (TweenService, CollectionService, etc.).
	    - Fire RemoteEvents or BindableEvents.
	    - Spawn new tasks or connect to signals.

	task.synchronize() — RETURNING TO THE MAIN THREAD:
	  Yields the parallel coroutine and resumes it on the main thread in the
	  next available step. After synchronize(), all Instance write operations
	  and service calls are safe again.

	WORKFLOW FOR AI TARGET SELECTION:
	  Main thread (ParallelTargetingService) sends enemy data to each Actor.
	  Actor receives the message → calls task.desynchronize() → runs distance
	  math in parallel → writes results to a SharedTable → calls task.synchronize()
	  → sends result back to main thread via a BindableEvent or another message.

	PERFORMANCE EXPECTATION:
	  With 4 Actors on a 4-core server, computing 100 enemies × 4 players =
	  400 distance checks splits into 4 batches of 25 enemies each, running on
	  4 cores simultaneously. Wall-clock time ≈ single-actor time / 4.
	  In practice, overhead from message passing and thread scheduling means
	  real speedup is ~2.5–3×, not 4×. Still meaningful for 200+ enemies.

	SETUP IN STUDIO:
	  1. In ServerScriptService, create a folder named "Actors".
	  2. Inside "Actors", create 4 Actor instances named "TargetingActor1" through
	     "TargetingActor4" (or however many CPU cores you want to saturate).
	  3. Place THIS script inside EACH Actor (you can use a ModuleScript trick or
	     just duplicate it — Scripts inside Actors are independent instances).
	  4. ParallelTargetingService.luau (the orchestrator) lives in Services/ as
	     a normal server Script, NOT inside an Actor.
]]

-- ── Grab this Actor's identity ────────────────────────────────────────────────

-- script:GetActor() returns the Actor that owns this script.
-- This is how we bind message handlers scoped to this specific Actor.
local actor: Actor = script:GetActor() :: Actor

-- Guard: this script MUST run inside an Actor. If run as a plain Script it
-- will error here rather than silently malfunctioning.
assert(actor ~= nil, "TargetingActor.server.luau must be a child of an Actor instance.")

-- ── Shared Output Table ────────────────────────────────────────────────────────

-- SharedTable is Roblox's thread-safe dictionary. We use it to write results
-- from the parallel thread back to the main thread without message overhead.
-- The orchestrator (ParallelTargetingService) reads from this table after all
-- actors signal completion.
--
-- The table is created in the orchestrator and passed to this actor via the
-- "Init" message. We store it in this upvalue so the "ComputeTargets" handler
-- can access it without re-fetching.
local outputTable: SharedTable? = nil

-- Actor index (1-4). Set via the Init message so each actor writes to a
-- unique key in the SharedTable, avoiding write conflicts.
local actorIndex: number = 0

-- ── Init Handler ──────────────────────────────────────────────────────────────

--[[
	Receives one-time setup data from the orchestrator.
	Called once when ParallelTargetingService initialises the actor.

	@param sharedOut  SharedTable  The shared output table.
	@param index      number       This actor's index (1-N).
]]
actor:BindToMessage("Init", function(sharedOut: SharedTable, index: number)
	outputTable = sharedOut
	actorIndex = index
	-- No parallel work in Init — just store configuration.
end)

-- ── ComputeTargets Handler ────────────────────────────────────────────────────

--[[
	Receives a batch of enemy data and player positions, computes the closest
	player for each enemy in PARALLEL, then writes results to the SharedTable.

	Message payload:
	  enemyBatch     {number}   Flat array: [enemyId, posX, posZ, posY, enemyId, ...]
	                            We use a flat number array (not a table of tables)
	                            because SendMessage copies values — a nested table
	                            of tables would deep-copy every frame, which is
	                            expensive. Flat numeric arrays are maximally compact.

	  playerPositions {number}  Flat array: [p1X, p1Z, p1Y, p2X, p2Z, p2Y, ...]
	                            One entry per living player (max 4 × 3 = 12 numbers).

	  batchId        number     Monotonically increasing counter so the orchestrator
	                            can detect stale results if a batch completes late.
]]
actor:BindToMessageParallel(
	"ComputeTargets",
	function(enemyBatch: { number }, playerPositions: { number }, batchId: number)
		-- We are already in parallel context because BindToMessageParallel
		-- fires the handler off the main thread automatically.
		-- No need to call task.desynchronize() here.

		-- Validate the output table is ready (Init must have been called first).
		if not outputTable then
			warn(string.format("[TargetingActor %d] OutputTable not set. Drop batch %d.", actorIndex, batchId))
			return
		end

		-- ── Parse player positions ────────────────────────────────────────
		-- playerPositions is a flat array: [X, Z, Y, X, Z, Y, ...]
		-- We only need XZ for ground-plane distance (Y is vertical).
		-- Pre-parse into a compact array of {x, z} pairs.
		local playerCount = #playerPositions / 3
		-- Pre-allocate with table.create to avoid repeated resizing.
		local px = table.create(playerCount) :: { number } -- player X coords
		local pz = table.create(playerCount) :: { number } -- player Z coords

		for i = 1, playerCount do
			local base = (i - 1) * 3 -- stride of 3 (X, Z, Y)
			px[i] = playerPositions[base + 1]
			pz[i] = playerPositions[base + 2]
			-- Y (playerPositions[base + 3]) ignored for XZ-plane distance.
		end

		-- ── Process each enemy in the batch ──────────────────────────────
		-- enemyBatch is a flat array: [enemyId, X, Z, Y, enemyId, X, Z, Y, ...]
		-- Stride of 4 numbers per enemy.
		local stride = 4
		local enemyCount = #enemyBatch / stride

		-- We will collect results as a flat array and write once to SharedTable.
		-- Writing per-enemy to SharedTable in a tight loop would hammer the
		-- mutex lock on every write; batching into a local table first is faster.
		-- Result format: [enemyId, closestPlayerId, distSq, enemyId, ...]
		local results = table.create(enemyCount * 3) :: { number }
		local ri = 0 -- result write index

		for e = 1, enemyCount do
			local base = (e - 1) * stride
			local enemyId = enemyBatch[base + 1] -- unique enemy ID (integer)
			local ex = enemyBatch[base + 2] -- enemy world X
			local ez = enemyBatch[base + 3] -- enemy world Z
			-- Y (enemyBatch[base + 4]) ignored for ground-plane targeting.

			-- Find the closest player by squared distance.
			-- Squared distance avoids sqrt — comparing distSq values is
			-- mathematically equivalent to comparing distances.
			local bestPlayerId = 0
			local bestDistSq = math.huge

			for p = 1, playerCount do
				local dx = ex - px[p]
				local dz = ez - pz[p]
				local distSq = dx * dx + dz * dz -- XZ squared distance

				if distSq < bestDistSq then
					bestDistSq = distSq
					bestPlayerId = p -- player index (1-based)
				end
			end

			-- Write to local result buffer (fast, no lock contention).
			ri += 1
			results[ri] = enemyId
			ri += 1
			results[ri] = bestPlayerId
			ri += 1
			results[ri] = bestDistSq
		end

		-- ── Write results to SharedTable ──────────────────────────────────
		-- We return to synchronised context to write to SharedTable safely.
		-- SharedTable IS thread-safe, but task.synchronize() is good practice
		-- when we're about to signal the orchestrator that results are ready.
		task.synchronize()

		-- Write the result array under this actor's key.
		-- Key format: "results_<actorIndex>_<batchId>"
		-- The batchId suffix lets the orchestrator discard stale batches.
		local resultKey = string.format("results_%d_%d", actorIndex, batchId)
		SharedTable.rawset(outputTable, resultKey, results)

		-- Signal completion. The orchestrator listens for "done_<actorIndex>".
		-- We use a simple integer (the batchId) as the signal value.
		local doneKey = string.format("done_%d", actorIndex)
		SharedTable.rawset(outputTable, doneKey, batchId)
		-- The orchestrator's polling loop (in ParallelTargetingService) will
		-- see all done_<i> == batchId and know this batch is fully complete.
	end
)
