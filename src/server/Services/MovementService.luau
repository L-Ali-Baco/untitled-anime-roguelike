--[[
	MovementService.luau
	Owns the Boids/separation Heartbeat loop. Completely decoupled from AI logic.

	Responsibilities:
	  - Register/unregister active enemy instances for separation processing
	  - Run staggered Boids repulsion each Heartbeat to prevent enemy mesh-stacking
	    without using physics collisions (which are disabled between enemies)

	Separation algorithm:
	  For each processed enemy, sum repulsion vectors from all neighbours within
	  Separation.Radius. The resulting vector is ADDED to the enemy's existing
	  PlaneVelocity so it blends naturally with movement intent rather than
	  overwriting it. Horizontal-only (Y is ignored).

	Staggering:
	  Only 1/StaggerDivisor of all registered enemies are processed each frame.
	  At 50 enemies + StaggerDivisor 4 → ~12 enemies/frame at 20 Hz → ~250/sec.
	  This keeps per-frame cost flat regardless of enemy count.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))

local MovementService = {
	Name = "MovementService",
}

-- Flat array for fast stagger-index iteration. Any object with
-- { RootPart: BasePart, LinearVelocity: LinearVelocity, State: string, _destroyed: boolean }
local registeredEnemies: { any } = {}
local staggerIndex = 0

-- ============================================================
-- PUBLIC: REGISTER / UNREGISTER
-- Called by EnemyService after instantiating a new enemy class.
-- ============================================================

function MovementService:Register(enemy: any)
	table.insert(registeredEnemies, enemy)
end

function MovementService:Unregister(enemy: any)
	local idx = table.find(registeredEnemies, enemy)
	if idx then
		-- Swap-remove for O(1) removal without shifting the whole array
		local last = #registeredEnemies
		registeredEnemies[idx] = registeredEnemies[last]
		registeredEnemies[last] = nil
	end
end

-- ============================================================
-- PRIVATE: BOIDS SEPARATION
-- ============================================================

local function updateSeparation()
	local cfg = EnemyConfig.Separation
	if not cfg or not cfg.Enabled then
		return
	end

	local count = #registeredEnemies
	if count < 2 then
		return
	end

	local divisor: number = cfg.StaggerDivisor or 4
	local batchSize = math.max(1, math.ceil(count / divisor))

	for i = 1, batchSize do
		local idx = (staggerIndex + i - 1) % count + 1
		local enemy = registeredEnemies[idx]

		if not enemy or enemy._destroyed then
			continue
		end
		-- Skip states where separation would fight other forces
		if enemy.State == "Dead" or enemy.State == "Hitstun" or enemy.State == "LeapAttack" then
			continue
		end
		if not enemy.RootPart or not enemy.RootPart.Parent then
			continue
		end
		if not enemy.LinearVelocity then
			continue
		end

		local myPos = enemy.RootPart.Position
		local separationVec = Vector2.zero

		for _, other in registeredEnemies do
			if other == enemy or other._destroyed then
				continue
			end
			if not other.RootPart or not other.RootPart.Parent then
				continue
			end

			local otherPos = other.RootPart.Position
			-- Horizontal-only distance (enemies on different floors ignore each other)
			local horizDiff = Vector2.new(myPos.X - otherPos.X, myPos.Z - otherPos.Z)
			local dist = horizDiff.Magnitude

			if dist < cfg.Radius and dist > 0.01 then
				-- Push strength: linear falloff — full push at 0, zero at Radius
				local strength = cfg.Strength * (1 - dist / cfg.Radius)
				separationVec += horizDiff.Unit * strength
			end
		end

		-- Additive blend into existing PlaneVelocity (doesn't overwrite movement intent)
		if separationVec.Magnitude > 0.01 then
			enemy.LinearVelocity.PlaneVelocity += separationVec
		end
	end

	-- Advance stagger cursor for next frame
	staggerIndex = (staggerIndex + batchSize) % math.max(count, 1)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function MovementService:Init()
	print("[MovementService] Initializing...")
end

function MovementService:Start()
	RunService.Heartbeat:Connect(function(_dt: number)
		updateSeparation()
	end)
	print("[MovementService] Started — staggered Boids separation active")
end

return MovementService
