--[[
	MovementService.luau
	Owns the Boids/separation Heartbeat loop. Completely decoupled from AI logic.

	Responsibilities:
	  - Register/unregister active enemy instances for separation processing
	  - Maintain a SpatialGrid of all registered enemies for O(k) neighbour queries
	  - Run staggered Boids repulsion each Heartbeat to prevent enemy mesh-stacking
	    without using physics collisions (which are disabled between enemies)

	Separation algorithm (upgraded from O(n²) all-pairs to O(k) spatial grid):
	  Each Heartbeat:
	    1. Update the SpatialGrid with all registered enemies' current positions.
	       SpatialGrid:Update() early-exits if the enemy hasn't changed cells,
	       so this is O(n) with very low constant for static/slow enemies.
	    2. For each enemy in the current stagger batch, call
	       SteeringBehaviors.CalculateSeparation(enemy, grid, cfg) which only
	       queries enemies in the same + adjacent grid cells → O(k) where
	       k = average number of neighbours in the separation radius.
	    3. The resulting repulsion Vector2 is ADDED to PlaneVelocity (additive,
	       not overwriting) so it blends naturally with flow-field movement intent.

	Staggering:
	  Only 1/StaggerDivisor of all registered enemies are processed each frame.
	  At 50 enemies + StaggerDivisor 4 → ~12 enemies/frame at 20 Hz → ~250/sec.
	  Grid update always runs on ALL enemies (O(n) early-exit) before the batch.

	Performance comparison:
	  Old (O(n²)): 50 enemies → 50 × 50 = 2500 pair-checks per stagger batch.
	  New (O(k)):  50 enemies, radius 3.5, avg 3 neighbours → 50 × 3 = 150 pair-checks.
	  At 100 enemies the difference is 10000 vs 300 — 33× fewer comparisons.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local SpatialGrid = require(Shared:WaitForChild("SpatialGrid"))
local SteeringBehaviors = require(script.Parent.Parent.Enemies.SteeringBehaviors)

local MovementService = {
	Name = "MovementService",
}

-- Flat array for fast stagger-index iteration. Any object with
-- { RootPart: BasePart, LinearVelocity: LinearVelocity, State: string, _destroyed: boolean }
local registeredEnemies: { any } = {}
local staggerIndex = 0

-- Spatial grid for O(k) neighbour queries.
-- Cell size = Separation.Radius × 2 is the optimal choice:
--   - Each cell holds enemies that could possibly interact with any enemy in the same cell.
--   - QueryRadius only needs to check the central cell + its 8 neighbours (9 cells total).
--   - Any cell size smaller wastes time checking empty cells; larger wastes time on distant enemies.
-- We defer creation to Start() so EnemyConfig is guaranteed to be loaded.
local enemyGrid: any = nil

-- ── Garbage sweep ─────────────────────────────────────────────────────────────
-- How often (seconds) to compact registeredEnemies and evict dead grid entries.
-- 4 seconds is long enough that the sweep never shows up in per-frame profiling,
-- and short enough that ghost entries don't accumulate meaningfully between runs.
local SWEEP_INTERVAL: number = 4
local _sweepAccumulator: number = 0

-- ============================================================
-- PUBLIC: REGISTER / UNREGISTER
-- Called by EnemyService after instantiating a new enemy class.
-- ============================================================

function MovementService:Register(enemy: any)
	table.insert(registeredEnemies, enemy)
	-- Add to the spatial grid immediately so the first separation tick can find it.
	if enemyGrid and enemy.RootPart and enemy.RootPart.Parent then
		enemyGrid:Register(enemy, enemy.RootPart.Position)
	end
end

function MovementService:Unregister(enemy: any)
	local idx = table.find(registeredEnemies, enemy)
	if idx then
		-- Swap-remove for O(1) removal without shifting the whole array
		local last = #registeredEnemies
		registeredEnemies[idx] = registeredEnemies[last]
		registeredEnemies[last] = nil
	end
	-- Remove from spatial grid so it no longer appears as a neighbour.
	if enemyGrid then
		enemyGrid:Remove(enemy)
	end
end

-- ============================================================
-- PRIVATE: DEAD-ENTRY SWEEP
-- Evicts destroyed enemies from registeredEnemies and enemyGrid.
-- Runs on a timer, not every frame, so it never appears in per-frame profiling.
-- ============================================================

local function sweepDeadEntries()
	debug.profilebegin("MovementService_Sweep")

	-- While-loop with swap-remove: correct O(n) compaction with no extra
	-- allocation and no skipped elements.
	--
	-- Why a while loop instead of a numeric for:
	--   After a swap-remove at index i, the element that was at [last] is now
	--   at [i] and has not been checked yet. A numeric for would advance i
	--   past it. The while loop re-checks [i] before advancing.
	local i = 1
	local swept = 0
	while i <= #registeredEnemies do
		local enemy = registeredEnemies[i]
		local isDead = enemy._destroyed
			or not enemy.RootPart
			or not enemy.RootPart.Parent

		if isDead then
			-- Evict from the spatial grid so it stops appearing as a neighbour.
			if enemyGrid then
				enemyGrid:Remove(enemy)
			end
			-- Swap-remove: O(1), preserves array density, order doesn't matter.
			local last = #registeredEnemies
			registeredEnemies[i] = registeredEnemies[last]
			registeredEnemies[last] = nil
			swept += 1
			-- Do NOT increment i — the swapped element at [i] needs checking.
		else
			i += 1
		end
	end

	if swept > 0 then
		print(string.format(
			"[MovementService] Sweep removed %d ghost entr%s — %d active",
			swept,
			if swept == 1 then "y" else "ies",
			#registeredEnemies
		))
	end

	debug.profileend() -- MovementService_Sweep
end

-- ============================================================
-- PRIVATE: BOIDS SEPARATION (O(k) with SpatialGrid)
-- ============================================================

local function updateSeparation()
	-- ── PROFILER: outer span covers the entire update budget ─────────────────
	-- MicroProfiler label: "MovementService_Update"
	-- Look for this bar on the Heartbeat row. The two child spans below
	-- (GridSync and StaggerBatch) show the split between the two phases.
	debug.profilebegin("MovementService_Update")

	local cfg = EnemyConfig.Separation
	if not cfg or not cfg.Enabled then
		debug.profileend() -- MovementService_Update (early exit: disabled)
		return
	end

	local count = #registeredEnemies
	if count < 2 then
		debug.profileend() -- MovementService_Update (early exit: <2 enemies)
		return
	end

	-- ── Step 1: Sync all enemy positions into the spatial grid ────────────────
	-- SpatialGrid:Update() computes the new cell for each enemy and only writes
	-- to the grid if the cell has changed — dead cheap for stationary enemies.
	-- This must run on ALL enemies before the staggered separation loop so the
	-- grid is current for whichever batch we're about to process.
	--
	-- MEMORY NOTE: entries where enemy._destroyed == true are skipped here but
	-- never removed from registeredEnemies or enemyGrid. Over a long session
	-- (hundreds of spawns) stale entries accumulate. If frame time trends upward
	-- as a session runs, this loop is the first place to investigate.
	-- Fix: EnemyService must reliably call MovementService:Unregister() on death.
	debug.profilebegin("MovementService_GridSync")
	for _, enemy in registeredEnemies do
		if enemy._destroyed or not enemy.RootPart or not enemy.RootPart.Parent then
			continue
		end
		enemyGrid:Update(enemy, enemy.RootPart.Position)
	end
	debug.profileend() -- MovementService_GridSync

	-- ── Step 2: Staggered separation — process 1/StaggerDivisor per frame ────
	local divisor: number = cfg.StaggerDivisor or 4
	local batchSize = math.max(1, math.ceil(count / divisor))

	-- MicroProfiler label: "MovementService_StaggerBatch"
	-- Width of this bar scales with batchSize. If it grows over time at a fixed
	-- enemy count, the SteeringBehaviors call inside is the inner bottleneck
	-- (visible as "MovementService_Separation" child bars).
	debug.profilebegin("MovementService_StaggerBatch")

	for i = 1, batchSize do
		local idx = (staggerIndex + i - 1) % count + 1
		local enemy = registeredEnemies[idx]

		if not enemy or enemy._destroyed then
			continue
		end

		-- Skip states where separation would fight other forces.
		-- Attack + ChargeAttack: enemy has called StopMovement(); additive Boids force
		--   would push it sideways during the windup and cause hit detection to miss.
		-- LeapAttack: coroutine owns velocity directly.
		-- Arming: Kamikaze is stationary; Boids should not override that.
		if
			enemy.State == "Dead"
			or enemy.State == "Hitstun"
			or enemy.State == "Attack"
			or enemy.State == "ChargeAttack"
			or enemy.State == "LeapAttack"
			or enemy.State == "Arming"
			-- Vertical states: XZ trajectory is locked by BaseEnemy Tick.
			-- Additive Separation force would deflect airborne enemies sideways,
			-- which causes physics chaos (bouncing off each other mid-air).
			or enemy.State == "Jumping"
			or enemy.State == "Falling"
			or enemy.State == "Landing"
		then
			continue
		end
		if not enemy.RootPart or not enemy.RootPart.Parent then
			continue
		end
		if not enemy.LinearVelocity then
			continue
		end

		-- ── O(k) separation via SpatialGrid ───────────────────────────────────
		-- SteeringBehaviors.CalculateSeparation calls enemyGrid:QueryRadiusPrecise()
		-- which only checks enemies in the same + adjacent cells → O(k neighbours).
		--
		-- MicroProfiler label: "MovementService_Separation"
		-- This is the innermost span and fires once per enemy per batch.
		-- If this bar dominates, the culprit is either a large separation radius
		-- (too many neighbours per cell) or a high StaggerDivisor (too large a batch).
		debug.profilebegin("MovementService_Separation")
		local separationVec = SteeringBehaviors.CalculateSeparation(enemy, enemyGrid, cfg)
		debug.profileend() -- MovementService_Separation

		-- Additive blend into existing PlaneVelocity (doesn't overwrite movement intent)
		if separationVec.Magnitude > 0.01 then
			enemy.LinearVelocity.PlaneVelocity += separationVec
		end
	end

	debug.profileend() -- MovementService_StaggerBatch

	-- Advance stagger cursor for next frame
	staggerIndex = (staggerIndex + batchSize) % math.max(count, 1)

	debug.profileend() -- MovementService_Update
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function MovementService:Init()
	print("[MovementService] Initializing...")
end

function MovementService:Start()
	-- Create the spatial grid with optimal cell size for the separation radius.
	-- cellSize = 2 × Radius ensures each query covers exactly 9 cells (3×3 ring).
	local radius = (EnemyConfig.Separation and EnemyConfig.Separation.Radius) or 3.5
	enemyGrid = SpatialGrid.new(radius * 2)

	RunService.Heartbeat:Connect(function(dt: number)
		-- ── Periodic ghost sweep ───────────────────────────────────────────────
		-- Runs every SWEEP_INTERVAL seconds. Compact registeredEnemies and
		-- evict dead entries from enemyGrid that Unregister() missed.
		-- Accumulate before updateSeparation so a spike in separation doesn't
		-- delay the sweep indefinitely on a heavily loaded frame.
		_sweepAccumulator += dt
		if _sweepAccumulator >= SWEEP_INTERVAL then
			_sweepAccumulator = 0
			sweepDeadEntries()
		end

		-- ── Separation update + 3 ms spike warning ────────────────────────────
		local t0 = os.clock()
		updateSeparation()
		local elapsed = os.clock() - t0

		-- 3 ms threshold: at 60 Hz the entire server frame budget is ~16 ms.
		-- One system consuming >3 ms is a meaningful fraction of that budget
		-- and warrants investigation before it worsens under higher enemy counts.
		-- Print the enemy count so the spike message is immediately actionable.
		if elapsed > 0.003 then
			warn(string.format(
				"[MovementService] Spike: updateSeparation took %.2f ms | %d enemies registered",
				elapsed * 1000,
				#registeredEnemies
			))
		end
	end)
	print("[MovementService] Started — O(k) SpatialGrid separation active")
end

return MovementService
