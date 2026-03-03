--[[
	StoneActivatorService.luau
	Stage 1 teleporter event — "The Stone Activator".

	Flow:
	  1. Start(): clone W1StoneActivator + StoneActivationBorder from
	             RS.Shared.Assets.Models.StoneActivator for each BasePart in
	             Workspace.Map.BeaconSpawns. Both are floor-seated using pivot math.

	  2. Player triggers prompt → beginLockdown():
	     • Spawn a flat red-neon cylinder (ZONE_RADIUS diameter, ground-level).
	     • Tell DirectorService to enter Horde Mode (LOCKDOWN_DURATION seconds).
	     • Fire StoneActivatorStateChanged "Lockdown".

	  3. Heartbeat while Lockdown:
	     • Charge increases only when ≥1 player is inside the zone.
	       (Charge pauses — does not drain — while zone is empty.)
	     • StoneActivatorProgress fired at ~10 Hz.

	  4. At 100% charge → completeEvent():
	     • EnemyService:KillAllEnemies() — instantly kills all active enemies.
	     • _G.StageNumber += 1.
	     • DirectorService:EndLockdown().
	     • Zone cylinder + all border meshes destroyed; stones destroyed.
	     • Fire StoneActivatorStateChanged "Completed".
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local StoneActivatorService = {
	Name = "StoneActivatorService",
}

-- ── Config ──────────────────────────────────────────────────────────────────
-- ZONE_RADIUS is the single source of truth for the challenge area.
-- It drives: the Heartbeat player-proximity check, the neon zone cylinder diameter,
-- and the CanCollide wall. Set this to match the physical radius of your
-- StoneActivationBorder mesh so the visuals and charge logic stay in sync.
local ZONE_RADIUS = 55 -- Studs; matches StoneActivationBorder rock perimeter radius
local CHARGE_TIME = 60 -- Seconds to reach 100% at full player presence
local LOCKDOWN_DURATION = 60 -- Seconds of Director Horde Mode
local PROGRESS_THROTTLE = 0.1 -- Remote fire interval (10 Hz)

-- ── Border animation config ───────────────────────────────────────────────────
-- At spawn the border is sunk BORDER_SINK_IDLE studs below the floor and fully
-- transparent — completely invisible to players until the event starts.
-- On activation it tweens upward (BORDER_SINK_IDLE - BORDER_SINK_ACTIVE) studs so
-- its final position is BORDER_SINK_ACTIVE studs below the floor (grounded look).
-- CanCollide / CanTouch / CanQuery are only enabled after the tween's Completed
-- event fires, never mid-animation, so no part can ever phase through the player.
local BORDER_SINK_IDLE = 10 -- Studs below floor at spawn (fully hidden)
local BORDER_SINK_ACTIVE = 2 -- Studs below floor once risen (grounded look)
local BORDER_RISE_TIME = 1.5 -- Seconds for the rise tween
local BORDER_SCALE_Y = 1.2 -- Vertical stretch applied to each border BasePart

-- ── States ───────────────────────────────────────────────────────────────────
local State = {
	Idle = "Idle",
	Lockdown = "Lockdown",
	Completed = "Completed",
}

-- ── Module state ─────────────────────────────────────────────────────────────
local currentState = State.Idle
local chargeProgress = 0 -- 0–100
local stoneModel: Model? = nil
local lastProgressSend = 0
local allStones: { Model } = {} -- module-level so the remote listener can read it
local stoneToBorderMap: { [Model]: Model } = {} -- keeps track of which border belongs to which stone
local stoneToHullMap: { [Model]: { BasePart } } = {} -- Keeps track of the invisible hull for each stone
local stoneToSafetyNetMap: { [Model]: BasePart } = {} -- Keeps track of the safety net for each stone
local stoneToSafetyNetListener: { [Model]: RBXScriptConnection } = {} -- Stores Touched listener for delayed activation
local lastTeleport: { [Player]: number } = {} -- Teleport debounce dictionary per player
local heartbeatConnection: RBXScriptConnection? = nil

-- [DEBUG] Fall-through monitor: threshold Y below which we consider a
-- character to have phased through the floor. Set in beginLockdown from
-- the stone's pivot Y (approximates the floor surface).
local debugFloorThresholdY: number? = nil

-- ── Service references (set in Start) ────────────────────────────────────────
local EnemyServiceRef: any = nil
local DirectorServiceRef: any = nil
local ChestServiceRef: any = nil

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function getStonePosition(): Vector3?
	if not stoneModel then
		return nil
	end
	return stoneModel:GetPivot().Position
end

-- Returns true when at least one player's HRP is within ZONE_RADIUS of the stone.
local function anyPlayerInsideZone(): boolean
	local center = getStonePosition()
	if not center then
		return false
	end
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and char.PrimaryPart then
			if (char.PrimaryPart.Position - center).Magnitude <= ZONE_RADIUS then
				return true
			end
		end
	end
	return false
end

local function spawnInvisibleHull(center: Vector3)
	local numParts = 12
	local thickness = 5
	local height = 60
	local angleStep = (math.pi * 2) / numParts

	local outerRadius = ZONE_RADIUS + thickness
	local width = 2 * outerRadius * math.tan(angleStep / 2) + 2

	local hullParts = {}
	for i = 1, numParts do
		local angle = (i - 1) * angleStep
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))

		local partCenter = center + dir * (ZONE_RADIUS + (thickness / 2))
		local spawnPos = Vector3.new(partCenter.X, center.Y + (height / 2) - 5, partCenter.Z)

		local part = Instance.new("Part")
		part.Name = "HullPart_" .. i
		part.Size = Vector3.new(width, height, thickness)
		part.CFrame = CFrame.lookAt(spawnPos, spawnPos + dir)
		part.Anchored = true
		part.Transparency = 1
		part.CanCollide = true
		part.CanTouch = false
		part.CanQuery = false
		part.Parent = workspace

		table.insert(hullParts, part)
	end

	if stoneModel then
		stoneToHullMap[stoneModel] = hullParts
	end
end

-- ── Core event logic ─────────────────────────────────────────────────────────

local function completeEvent()
	if currentState == State.Completed then
		return
	end
	currentState = State.Completed
	chargeProgress = 100

	-- Instantly kill every active enemy
	if EnemyServiceRef then
		EnemyServiceRef:KillAllEnemies()
	end

	-- Advance stage counter
	_G.StageNumber = (_G.StageNumber or 1) + 1
	print(("[StoneActivatorService] Stage complete! Advancing to stage %d"):format(_G.StageNumber))

	-- Release Director from Horde Mode
	if DirectorServiceRef and DirectorServiceRef.EndLockdown then
		DirectorServiceRef:EndLockdown()
	end

	-- Stop the charge loop — no further Heartbeat work needed this session.
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	-- Spawn reward chest before destroying the stone so we still have its position.
	local chestPos = getStonePosition()
	if chestPos and ChestServiceRef and ChestServiceRef.SpawnChest then
		local offsetPos = chestPos + Vector3.new(6, 0, 0)
		ChestServiceRef:SpawnChest(offsetPos, _G.StageNumber or 1)
		print("[StoneActivatorService] Reward chest spawned")
	else
		warn("[StoneActivatorService] ChestService not found — no reward chest spawned")
	end

	-- Destroy only the specific border, hull, and safety net associated with the active stone.
	if stoneModel then
		local border = stoneToBorderMap[stoneModel]
		if border and border.Parent then
			border:Destroy()
		end
		stoneToBorderMap[stoneModel] = nil

		local hullParts = stoneToHullMap[stoneModel]
		if hullParts then
			for _, part in hullParts do
				if part and part.Parent then
					part:Destroy()
				end
			end
		end
		stoneToHullMap[stoneModel] = nil

		local net = stoneToSafetyNetMap[stoneModel]
		if net and net.Parent then
			net:Destroy()
		end
		stoneToSafetyNetMap[stoneModel] = nil

		local netListener = stoneToSafetyNetListener[stoneModel]
		if netListener then
			netListener:Disconnect()
		end
		stoneToSafetyNetListener[stoneModel] = nil
	end

	-- Destroy every stone activator instance to clear the map.
	for _, stone in allStones do
		if stone and stone.Parent then
			-- Ensure any remaining mapped items are also cleaned up if multiple existed
			local border = stoneToBorderMap[stone]
			if border then
				border:Destroy()
			end

			local hullParts = stoneToHullMap[stone]
			if hullParts then
				for _, p in hullParts do
					p:Destroy()
				end
			end

			local net = stoneToSafetyNetMap[stone]
			if net then
				net:Destroy()
			end

			local netListener = stoneToSafetyNetListener[stone]
			if netListener then
				netListener:Disconnect()
			end

			stoneToBorderMap[stone] = nil
			stoneToHullMap[stone] = nil
			stoneToSafetyNetMap[stone] = nil
			stoneToSafetyNetListener[stone] = nil

			stone:Destroy()
		end
	end
	table.clear(allStones)
	stoneModel = nil

	local remote = Remotes:GetEvent("StoneActivatorStateChanged")
	if remote then
		remote:FireAllClients(State.Completed, chargeProgress)
	end

	print("[StoneActivatorService] EVENT COMPLETE — enemies killed, stones + borders + cylinder destroyed")
end

local function beginLockdown(activatingPlayer: Player, triggeredModel: Model)
	if currentState ~= State.Idle then
		return
	end
	stoneModel = triggeredModel -- set active stone for zone position and heartbeat
	currentState = State.Lockdown
	chargeProgress = 0

	print(("[StoneActivatorService] LOCKDOWN initiated by %s"):format(activatingPlayer.Name))

	-- Capture approximate floor Y for the fall-through debug monitor.
	-- Stone pivot after seatModelOnFloor sits slightly above the actual floor;
	-- subtract 3 as a small buffer — any player below this is clearly underground.
	local stonePos = getStonePosition()
	debugFloorThresholdY = if stonePos then stonePos.Y - 3 else nil
	if debugFloorThresholdY then
		print(("[SAService][PHYSICS-DBG] Fall-through monitor active. Alert Y < %.2f"):format(debugFloorThresholdY))
	end

	if stonePos then
		spawnInvisibleHull(stonePos)
	end

	-- Delayed Activation: Connect the SafetyNet Touched listener explicitly on lockdown.
	local net = stoneToSafetyNetMap[triggeredModel]
	if net then
		stoneToSafetyNetListener[triggeredModel] = net.Touched:Connect(function(otherPart)
			local char = otherPart.Parent
			local player = Players:GetPlayerFromCharacter(char)

			if char and player and char:FindFirstChild("Humanoid") then
				local hrp = char:FindFirstChild("HumanoidRootPart")

				-- Velocity Check: Only rescue if they are actually falling down (Y < -20)
				if hrp and hrp.AssemblyLinearVelocity.Y < -20 then
					local now = os.clock()

					-- Cooldown: Enforce a 3-second teleport debounce
					if not lastTeleport[player] or (now - lastTeleport[player]) > 3 then
						lastTeleport[player] = now

						local stonePivot = triggeredModel:GetPivot()
						local _, bbSize = triggeredModel:GetBoundingBox()
						local topY = stonePivot.Position.Y + (bbSize.Y / 2)
						char:PivotTo(CFrame.new(stonePivot.Position.X, topY + 3, stonePivot.Position.Z))
					end
				end
			end
		end)
	end

	-- ── Border rise animation ──────────────────────────────────────────────────
	-- Rise delta: BORDER_SINK_IDLE (10) − BORDER_SINK_ACTIVE (2) = 8 studs upward.
	-- Physics safety protocol:
	--   Step 1 — make the rocks visible immediately (Transparency = 0) so the
	--             player can see them rising before they can interact with them.
	--   Step 2 — tween every BasePart's CFrame upward; parts remain non-collidable
	--             throughout the animation (CanCollide/CanTouch/CanQuery still false).
	--   Step 3 — enable physics only inside sentinelTween.Completed, which fires
	--             after the ACTUAL tween finishes, never mid-animation.  This is the
	--             only correct gate — task.delay drifts under server load and can
	--             fire early, which is what causes the fall-through glitch.
	local riseAmount = BORDER_SINK_IDLE - BORDER_SINK_ACTIVE -- 8 studs
	local riseInfo = TweenInfo.new(BORDER_RISE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local border = stoneToBorderMap[triggeredModel]

	-- Step 1: reveal border parts before they start moving.
	if border then
		for _, part in border:GetDescendants() do
			if part:IsA("BasePart") then
				part.Transparency = 0
			end
		end
	end

	-- Step 2: start all tweens and keep a reference to the last one as a sentinel.
	-- All parts share the same TweenInfo so they all complete at the same instant;
	-- connecting to any single tween's Completed is sufficient.
	--
	-- ⚠ AXIS BUG HISTORY — why we use `+ Vector3` instead of `* CFrame.new`:
	--   `partCFrame * CFrame.new(0, Y, 0)` translates along the PART'S LOCAL Y.
	--   Rock parts inside the border model are rotated at various angles for visual
	--   variety; a rock tilted 45° would slide diagonally instead of straight up.
	--   When CanCollide later enables, those parts sit in wrong positions (some
	--   inside the floor, some inside the playspace) and the physics resolver fires
	--   ejection impulses that push players/enemies downward through thin floors.
	--   `part.CFrame + Vector3.new(0, Y, 0)` translates position in WORLD Y only,
	--   preserving the part's original rotation. This is always correct here.
	local sentinelTween: Tween? = nil
	local debugFirstPart = true -- log one sample to verify travel direction
	if border then
		for _, part in border:GetDescendants() do
			if part:IsA("BasePart") then
				local targetCFrame = part.CFrame + Vector3.new(0, riseAmount, 0)

				-- [DEBUG] Print the first part's start and intended end Y so we
				-- can confirm rocks are rising vertically, not diagonally.
				if debugFirstPart then
					debugFirstPart = false
					local startY = part.CFrame.Position.Y
					local endY = targetCFrame.Position.Y
					local localYDelta = (part.CFrame * CFrame.new(0, riseAmount, 0)).Position.Y - startY
					warn(
						(
							"[SAService][PHYSICS-DBG] First border part '%s':"
							.. " worldStartY=%.2f worldEndY=%.2f (Δworld=%.2f Δlocal=%.2f)"
							.. " — if Δworld ≠ Δlocal the part was tilted & old code was wrong"
						):format(part.Name, startY, endY, endY - startY, localYDelta)
					)
				end

				local tween = TweenService:Create(part, riseInfo, {
					CFrame = targetCFrame,
				})
				tween:Play()
				sentinelTween = tween
			end
		end
	end

	-- Humanoid Safety: toggle PlatformStand during the rise animation
	if stonePos then
		for _, player in Players:GetPlayers() do
			local char = player.Character
			if char and char:FindFirstChild("Humanoid") then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp and (hrp.Position - stonePos).Magnitude <= ZONE_RADIUS + 20 then
					char.Humanoid.PlatformStand = true
					task.delay(0.5, function()
						if char and char:FindFirstChild("Humanoid") then
							char.Humanoid.PlatformStand = false
						end
					end)
				end
			end
		end
	end

	-- Step 3: Visual Decoupling means we NO LONGER enable CanCollide on the rocks.
	-- They remain purely visual. The Invisible Hull handles collision.
	if not sentinelTween then
		warn("[StoneActivatorService] No border parts found — rise animation skipped")
	end

	-- Re-resolve service references lazily (guaranteed started since a player is in-game)
	if not DirectorServiceRef then
		DirectorServiceRef = _G.DirectorService
	end
	if not ChestServiceRef then
		ChestServiceRef = _G.ChestService
	end

	if DirectorServiceRef and DirectorServiceRef.BeginLockdown then
		DirectorServiceRef:BeginLockdown(LOCKDOWN_DURATION)
	else
		warn("[StoneActivatorService] DirectorService not found — horde mode not activated")
	end

	local remote = Remotes:GetEvent("StoneActivatorStateChanged")
	if remote then
		print("[StoneActivatorService] Firing StoneActivatorStateChanged → Lockdown")
		remote:FireAllClients(State.Lockdown, 0)
	else
		warn("[StoneActivatorService] StoneActivatorStateChanged remote NOT FOUND — HUD will not show")
	end
end

-- ── Heartbeat ─────────────────────────────────────────────────────────────────

local function onHeartbeat(dt: number)
	if currentState ~= State.Lockdown then
		return
	end

	-- [DEBUG] Fall-through monitor — warn immediately when a player's HRP
	-- drops below approximate floor level. Check every ~0.25 s to avoid
	-- per-frame overhead (lastProgressSend already throttles at 0.1 s, so
	-- we just reuse the clock comparison at a coarser interval).
	if debugFloorThresholdY then
		local now = os.clock()
		if math.floor(now * 4) ~= math.floor((now - dt) * 4) then -- fires ~4×/s
			for _, player in Players:GetPlayers() do
				local char = player.Character
				if char and char.PrimaryPart then
					local hrpY = char.PrimaryPart.Position.Y
					if hrpY < debugFloorThresholdY then
						warn(
							("[SAService][FALL-THROUGH] %s HRP Y=%.2f (threshold=%.2f) at %.2f s into lockdown"):format(
								player.Name,
								hrpY,
								debugFloorThresholdY,
								os.clock() - (chargeProgress / 100 * CHARGE_TIME) -- rough elapsed
							)
						)
					end
				end
			end
		end
	end

	-- Charge only when a player is present inside the zone
	if anyPlayerInsideZone() then
		chargeProgress = math.min(100, chargeProgress + (dt / CHARGE_TIME) * 100)
	end
	-- No drain when zone is empty — progress simply pauses

	-- Throttled progress broadcast (~10 Hz)
	local now = os.clock()
	if now - lastProgressSend >= PROGRESS_THROTTLE then
		lastProgressSend = now
		local remote = Remotes:GetEvent("StoneActivatorProgress")
		if remote then
			remote:FireAllClients(chargeProgress)
		end
	end

	if chargeProgress >= 100 then
		completeEvent()
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function StoneActivatorService:Init()
	print("[StoneActivatorService] Initializing...")
	Remotes:InitServer()

	-- ── Collision group setup ──────────────────────────────────────────────────
	-- "ArenaWalls" is used by rising border parts so they never exert collision-
	-- resolution pressure against the floor geometry (Default group) or against
	-- enemy GroundCollision boxes (Enemies group).
	--
	-- IMPORTANT: "Enemies" must be registered HERE, not relied on from BaseEnemy.
	-- BaseEnemy registers the group implicitly the first time an enemy spawns
	-- (via `part.CollisionGroup = "Enemies"`), but that happens in gameplay —
	-- AFTER Init().  CollisionGroupSetCollidable requires both groups to already
	-- exist in the PhysicsService registry; if "Enemies" is missing the call
	-- silently fails when wrapped in pcall, leaving the rule un-applied.
	local function safeRegister(name: string)
		local ok, err = pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, name)
		if not ok then
			-- "already registered" is not an error; anything else is.
			if not string.find(tostring(err), "already") then
				warn(("[SAService][PHYSICS] RegisterCollisionGroup('%s') FAILED: %s"):format(name, err))
			end
		end
	end

	local function safeNoCollide(a: string, b: string)
		local ok, err = pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, a, b, false)
		if ok then
			print(("[SAService][PHYSICS] %s ↔ %s = no-collide ✓"):format(a, b))
		else
			warn(("[SAService][PHYSICS] CollisionGroupSetCollidable('%s','%s') FAILED: %s"):format(a, b, err))
		end
	end

	-- Group layout:
	--   Default    — floor/map geometry (Roblox built-in; cannot be renamed)
	--   Characters — player character BaseParts
	--   Enemies    — enemy GroundCollision boxes (registered here & by BaseEnemy on first spawn)
	--   ArenaWalls — rising border parts during the Stone Activator event
	--
	-- Collision matrix (✓ = collidable, ✗ = no-collide):
	--   Default    ↔ Characters  = ✓ (players stand on floor — Roblox default, no rule needed)
	--   Default    ↔ Enemies     = ✓ (enemies stand on floor — Roblox default, no rule needed)
	--   Enemies    ↔ Characters  = ✗ enemy GroundCollision boxes must NEVER push player rigs;
	--                               code-driven knockback (AssemblyLinearVelocity) still works
	--   ArenaWalls ↔ Default     = ✗ anchored walls don't exert pressure on floor geometry
	--   ArenaWalls ↔ Enemies     = ✗ walls don't eject enemy GroundCollision boxes
	--   ArenaWalls ↔ Characters  = ✗ CRITICAL: anchored rock parts must never eject player rigs.
	--                               When CanCollide enables on a risen pillar whose geometry clips
	--                               the player, the physics resolver fires a solid-body ejection
	--                               impulse.  On thin floors that impulse is directed downward and
	--                               phases the player through the floor.  Making this no-collide
	--                               removes the ejection entirely; visual containment is handled
	--                               by the rocks' imposing size rather than physics collision.
	safeRegister("Characters")
	safeRegister("ArenaWalls")
	safeRegister("Enemies") -- must exist before SetCollidable; BaseEnemy creates it on first spawn (too late)
	safeRegister("SafetyNet")

	safeNoCollide("Enemies", "Characters") -- enemies can't push players through floors
	safeNoCollide("ArenaWalls", "Default") -- walls don't push floor geometry
	safeNoCollide("ArenaWalls", "Enemies") -- walls don't eject enemy GroundCollision boxes
	safeNoCollide("ArenaWalls", "Characters") -- walls don't eject player rigs (see matrix note above)
	safeNoCollide("SafetyNet", "Default") -- SafetyNet never collides with map floor
end

function StoneActivatorService:Start()
	EnemyServiceRef = require(script.Parent.EnemyService)

	-- ── Locate templates ──────────────────────────────────────────────────────
	-- Asset path: RS.Shared.Assets.Models.StoneActivator.*
	-- Fallback for W1StoneActivator: find an already-placed instance in workspace.
	local stoneFolder = Shared:FindFirstChild("Assets")
		and Shared.Assets:FindFirstChild("Models")
		and Shared.Assets.Models:FindFirstChild("StoneActivator")
	local stoneTemplate = stoneFolder and stoneFolder:FindFirstChild("W1StoneActivator")
	-- Border lives one level deeper: .../StoneActivator/Border/StoneActivationBorder
	local borderFolder = stoneFolder and stoneFolder:FindFirstChild("Border")
	local borderTemplate = borderFolder and borderFolder:FindFirstChild("StoneActivationBorder")

	if stoneTemplate then
		print("[StoneActivatorService] Template ready: RS.Shared.Assets.Models.StoneActivator.W1StoneActivator")
	else
		stoneModel = workspace:FindFirstChild("W1StoneActivator", true)
		if stoneModel then
			print("[StoneActivatorService] Using W1StoneActivator already in workspace")
		else
			warn(
				"[StoneActivatorService] W1StoneActivator not found at RS.Shared.Assets.Models.StoneActivator — place the model there or in workspace. Service disabled."
			)
			return
		end
	end

	print("[StoneActivatorService] Border Template Found:", borderTemplate ~= nil)
	if not borderTemplate then
		warn(
			"[StoneActivatorService] StoneActivationBorder not found at"
				.. " RS.Shared.Assets.Models.StoneActivator.Border.StoneActivationBorder"
				.. " — borders will be skipped"
		)
	end

	-- ── DEBUG: Spawn a stone at every BeaconSpawn to verify all locations ──────
	-- To revert to production (single random pick), replace this block with a
	-- math.random(#spawnParts) pick, single clone, and single prompt connection.
	local map = workspace:FindFirstChild("Map")
	local spawnsFolder = map and map:FindFirstChild("BeaconSpawns")
	if not spawnsFolder then
		warn("[StoneActivatorService] Workspace.Map.BeaconSpawns not found — stone stays at origin")
	end

	local spawnParts: { BasePart } = {}
	if spawnsFolder then
		for _, child in spawnsFolder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(spawnParts, child :: BasePart)
			end
		end
		if #spawnParts == 0 then
			warn("[StoneActivatorService] BeaconSpawns folder is empty")
		end
	end

	-- module-level lists; clear in case Start() is ever re-entered.
	table.clear(allStones)
	table.clear(stoneToBorderMap)
	table.clear(stoneToHullMap)
	table.clear(stoneToSafetyNetMap)
	table.clear(stoneToSafetyNetListener)
	table.clear(lastTeleport)

	-- ── Shared floor-seating math ─────────────────────────────────────────────
	-- Anti-float: seat a model's bottom face exactly on the spawn part's floor.
	-- GetBoundingBox() returns (bbCFrame, bbSize).
	-- PivotTo moves the PIVOT, not the bounding-box centre, so we measure how far
	-- the pivot sits above the bb-bottom and offset accordingly.
	local function seatModelOnFloor(model: Model, pick: BasePart)
		local bbCF, bbSize = model:GetBoundingBox()
		local floorY = pick.Position.Y - pick.Size.Y / 2
		local bbBottomY = bbCF.Position.Y - bbSize.Y / 2
		local pivotAboveBBBottom = model:GetPivot().Position.Y - bbBottomY
		model:PivotTo(CFrame.new(pick.Position.X, floorY + pivotAboveBBBottom, pick.Position.Z))
	end

	local function placeStone(pick: BasePart): Model
		local stone: Model
		if stoneTemplate then
			stone = stoneTemplate:Clone()
			-- Anchor before entering workspace for the same reason as the border:
			-- prevents a one-frame physics collision at the template's origin position.
			for _, part in stone:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			stone.Parent = workspace
		else
			stone = stoneModel :: Model -- workspace-fallback: single instance, placed once
		end

		seatModelOnFloor(stone, pick)

		print(("[StoneActivatorService][DEBUG] Stone placed at '%s'"):format(pick.Name))

		-- The 'Safety Net'
		local floorY = pick.Position.Y - pick.Size.Y / 2
		local safetyNet = Instance.new("Part")
		safetyNet.Name = "SafetyNet_" .. pick.Name
		safetyNet.Size = Vector3.new(200, 5, 200)
		safetyNet.CFrame = CFrame.new(pick.Position.X, floorY - 15, pick.Position.Z)
		safetyNet.Anchored = true
		safetyNet.Transparency = 1
		safetyNet.CanCollide = true -- So 'collides with Characters' works
		safetyNet.CanTouch = true
		safetyNet.CanQuery = false
		safetyNet.CollisionGroup = "SafetyNet"
		safetyNet.Parent = workspace

		stoneToSafetyNetMap[stone] = safetyNet

		-- Pre-spawn the border mesh alongside the stone.
		if borderTemplate then
			print(("[StoneActivatorService][DEBUG] Cloning StoneActivationBorder for spawn '%s'"):format(pick.Name))
			local border = borderTemplate:Clone()

			-- ⚠ Configure ALL parts BEFORE parenting to workspace.
			-- Roblox's physics engine begins simulating the instant a part enters
			-- workspace.  If the template has CanCollide = true and we set it to
			-- false AFTER parenting, the engine sees a solid part for one physics
			-- step and can eject any overlapping character downward — this is the
			-- fall-through glitch.  Setting properties first costs nothing and is
			-- completely safe because physics never runs on an unparented model.
			for _, desc in border:GetDescendants() do
				if desc:IsA("ProximityPrompt") then
					-- Strip any ProximityPrompts baked into the border template.
					-- A stale prompt with KeyboardKeyCode = E is what makes the
					-- interaction hint display "E" instead of "F".
					desc:Destroy()
				elseif desc:IsA("BasePart") then
					desc.Anchored = true
					desc.Transparency = 1 -- invisible until event starts
					desc.CanCollide = false -- enabled only after rise tween completes
					desc.CanTouch = false
					desc.CanQuery = false
					-- ArenaWalls group: no collision pressure against Default (floor)
					-- or Enemies — prevents floor-phasing when CanCollide enables.
					desc.CollisionGroup = "ArenaWalls"
					-- Stretch wall height so it reads as a solid barrier once risen.
					desc.Size = Vector3.new(desc.Size.X, desc.Size.Y * BORDER_SCALE_Y, desc.Size.Z)
				end
			end
			-- Tag the model so raycasts in Brute._doLeapAttack can exclude walls
			-- from the landing ground-detect ray (avoids snapping on top of a wall).
			CollectionService:AddTag(border, "ArenaWall")

			-- Now safe to enter workspace — parts are already ghost-flagged.
			border.Parent = workspace

			-- Seat XZ flush with the spawn floor, then sink BORDER_SINK_IDLE studs
			-- down so the rock tops are well underground and invisible at idle.
			seatModelOnFloor(border, pick)
			border:PivotTo(border:GetPivot() * CFrame.new(0, -BORDER_SINK_IDLE, 0))
			print(
				("[StoneActivatorService][DEBUG] Border idle pivot (sunk %d studs): %s"):format(
					BORDER_SINK_IDLE,
					tostring(border:GetPivot().Position)
				)
			)

			stoneToBorderMap[stone] = border
		end

		return stone
	end

	local function attachPrompt(stone: Model)
		-- Prefer PrimaryPart as the anchor; fall back to any root-level BasePart,
		-- then any deeply nested one. Avoids parenting to tiny decorative internals.
		local anchorPart: BasePart? = stone.PrimaryPart
		if not anchorPart then
			for _, child in stone:GetChildren() do
				if child:IsA("BasePart") then
					anchorPart = child :: BasePart
					break
				end
			end
		end
		if not anchorPart then
			anchorPart = stone:FindFirstChildWhichIsA("BasePart", true)
		end
		if not anchorPart then
			warn("[StoneActivatorService] No BasePart on stone — ProximityPrompt skipped")
			return
		end

		-- Destroy every pre-existing ProximityPrompt on the model so Studio-embedded
		-- prompts with wrong KeyboardKeyCode/Enabled values can never shadow ours.
		for _, desc in stone:GetDescendants() do
			if desc:IsA("ProximityPrompt") then
				desc:Destroy()
			end
		end

		-- Set ALL properties before parenting.  A ProximityPrompt's default
		-- KeyboardKeyCode is E; parenting it first lets the client UI latch
		-- onto that default for one frame, which is why the hint shows "E"
		-- even though we set F immediately after.  Configuring before Parent
		-- ensures the client never sees the prompt with the wrong key.
		local prompt = Instance.new("ProximityPrompt")
		-- KeyboardKeyCode = F is intentional: when within MaxActivationDistance,
		-- Roblox's ProximityPrompt sinks F via its internal ContextAction so the
		-- stone triggers and InputController sees gameProcessed = true, skipping
		-- combat binds.  Outside range, F falls through to InputController normally.
		prompt.ActionText = "Activate"
		prompt.ObjectText = "Stone Activator"
		prompt.HoldDuration = 0
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.MaxActivationDistance = 15
		prompt.RequiresLineOfSight = false
		prompt.Enabled = true
		prompt.Parent = anchorPart -- parent last, after all properties are set

		print(
			("[StoneActivatorService] Prompt attached to part '%s' (Enabled=%s, MaxDist=%d)"):format(
				anchorPart.Name,
				tostring(prompt.Enabled),
				prompt.MaxActivationDistance
			)
		)

		prompt.Triggered:Connect(function(player: Player)
			if currentState ~= State.Idle then
				return -- Prevent double triggers or re-entering if suddenly overlapped
			end

			print(("[StoneActivatorService] Prompt TRIGGERED by %s — calling beginLockdown"):format(player.Name))

			-- Immediately disable and destroy the triggered prompt
			prompt.Enabled = false
			prompt:Destroy()

			-- Disable all sibling prompts so only one lockdown can start
			for _, s in allStones do
				for _, desc in s:GetDescendants() do
					if desc:IsA("ProximityPrompt") then
						desc.Enabled = false
						desc:Destroy()
					end
				end
			end
			beginLockdown(player, stone)
		end)
	end

	if #spawnParts > 0 then
		for _, pick in spawnParts do
			local stone = placeStone(pick)
			table.insert(allStones, stone)
			if not stoneTemplate then
				break -- workspace-fallback has only one stone; don't loop further
			end
		end
	else
		-- No spawn parts: use the template at its default position, or the workspace fallback.
		if stoneTemplate then
			local stone = stoneTemplate:Clone()
			stone.Parent = workspace
			table.insert(allStones, stone)
			warn("[StoneActivatorService] No BeaconSpawns found — stone placed at template origin")
		elseif stoneModel then
			table.insert(allStones, stoneModel :: Model)
		else
			warn("[StoneActivatorService] No stone to place — service disabled")
			return
		end
	end

	stoneModel = allStones[1] -- default active stone; overwritten by beginLockdown on trigger
	for _, stone in allStones do
		attachPrompt(stone)
	end

	-- ── Assign player character parts to the "Characters" collision group ─────
	-- Enemy GroundCollision boxes are in the "Enemies" group.  The Init() rule
	-- "Enemies ↔ Characters = no-collide" only takes effect once character parts
	-- are actually IN the "Characters" group — this hook does that assignment.
	-- We also watch DescendantAdded so hats/accessories that load after CharacterAdded
	-- are covered without an additional polling loop.
	local function assignCharactersGroup(character: Model)
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.CollisionGroup = "Characters"
			end
		end
		character.DescendantAdded:Connect(function(inst)
			if inst:IsA("BasePart") then
				inst.CollisionGroup = "Characters"
			end
		end)
		print(("[SAService][PHYSICS] Characters group assigned to '%s' rig"):format(character.Name))
	end

	-- Cover players already in-game when Start() runs (e.g. a respawn before service boot)
	for _, player in Players:GetPlayers() do
		if player.Character then
			assignCharactersGroup(player.Character)
		end
		player.CharacterAdded:Connect(assignCharactersGroup)
	end
	-- Cover players who join after Start() completes
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(assignCharactersGroup)
	end)

	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

	-- Listen for keyboard interact requests from clients (InputController.OnInteractPressed → F key).
	-- Server validates proximity so clients can't trigger from across the map.
	local activateRemote = Remotes:GetEvent("RequestStoneActivate")
	if activateRemote then
		activateRemote.OnServerEvent:Connect(function(player: Player)
			if currentState ~= State.Idle then
				return
			end
			local char = player.Character
			if not char or not char.PrimaryPart then
				return
			end
			local hrpPos = char.PrimaryPart.Position
			for _, stone in allStones do
				if (hrpPos - stone:GetPivot().Position).Magnitude <= 20 then
					beginLockdown(player, stone)
					return
				end
			end
		end)
	else
		warn("[StoneActivatorService] RequestStoneActivate remote not found — keyboard interact disabled")
	end

	if stoneModel then
		print(("[StoneActivatorService] Started — stone at %s"):format(tostring(stoneModel:GetPivot().Position)))
	end
end

return StoneActivatorService
