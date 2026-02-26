--[[
    DirectorService.luau
    Server-side Director System ("The Storm").
    
    Responsibilities:
    - Track run time and calculate difficulty
    - Scale enemy stats based on difficulty
    - Trigger random events (elites, hordes, etc.)
    - Broadcast difficulty updates to clients for visual effects
    
    Inspired by Risk of Rain 2's Director system.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local DirectorConfig = require(Shared:WaitForChild("Config"):WaitForChild("DirectorConfig"))

local DirectorService = {
	Name = "DirectorService",
}

-- State
local runStartTime = 0
local currentDifficulty = DirectorConfig.BaseDifficulty
local isRunning = false
local lastUpdateTime = 0

-- Event cooldowns
local eventCooldowns = {
	EliteSpawn = 0,
	HordeWave = 0,
	TreasureGoblin = 0,
	LightningStrike = 0,
}

-- =========================================================
-- CREDIT BUDGET DIRECTOR STATE
-- These variables drive the primary Lull / Ramp spawn loop.
-- See updateCreditDirector() below for the state machine.
-- =========================================================
local directorCredits = 0 -- Current credit balance
local directorState = "Lull" -- "Ramp" | "Lull"
local lullEndTime = 0 -- tick() when the current lull expires
local lastSpawnTick = 0 -- tick() of the last credit-funded spawn

-- References to other services (set in Start)
local EnemyService = nil

--[[
    Calculate current difficulty based on run time
]]
local function calculateDifficulty(): number
	if not isRunning then
		return DirectorConfig.BaseDifficulty
	end

	local runTime = tick() - runStartTime
	local minutesElapsed = runTime / 60

	local difficulty = DirectorConfig.BaseDifficulty + (minutesElapsed * DirectorConfig.DifficultyPerMinute)
	difficulty = math.min(difficulty, DirectorConfig.MaxDifficulty)

	return difficulty
end

--[[
    Get the current difficulty tier info
]]
local function getCurrentTier(difficulty: number): { Name: string, Color: Color3 }
	local currentTier = DirectorConfig.Tiers[1]

	for _, tier in DirectorConfig.Tiers do
		if difficulty >= tier.MinDifficulty then
			currentTier = tier
		end
	end

	return currentTier
end

--[[
    Calculate stat multipliers for enemies based on current difficulty
    Returns: { Health: number, Damage: number, Speed: number }
]]
local function getStatMultipliers(difficulty: number): { Health: number, Damage: number, Speed: number }
	-- Lerp from 1.0 to max multiplier based on difficulty progression
	local progress = (difficulty - DirectorConfig.BaseDifficulty)
		/ (DirectorConfig.MaxDifficulty - DirectorConfig.BaseDifficulty)
	progress = math.clamp(progress, 0, 1)

	return {
		Health = 1.0 + (DirectorConfig.MaxHealthMultiplier - 1.0) * progress,
		Damage = 1.0 + (DirectorConfig.MaxDamageMultiplier - 1.0) * progress,
		Speed = 1.0 + (DirectorConfig.MaxSpeedMultiplier - 1.0) * progress,
	}
end

--[[
    Get random spawn position around players
]]
local function getSpawnPositionNearPlayers(radius: number): Vector3?
	local players = Players:GetPlayers()
	if #players == 0 then
		return nil
	end

	-- Pick a random player
	local player = players[math.random(#players)]
	local character = player.Character
	if not character or not character.PrimaryPart then
		return nil
	end

	local playerPos = character.PrimaryPart.Position

	-- Random angle around player
	local angle = math.random() * math.pi * 2
	local distance = radius * 0.5 + math.random() * radius * 0.5 -- 50-100% of radius

	local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)

	return playerPos + offset
end

--[[
    Try to trigger an elite enemy spawn
]]
local function tryEliteSpawn(difficulty: number, now: number, force: boolean?): boolean
	local config = DirectorConfig.Events.EliteSpawn
	if not config.Enabled and not force then
		return false
	end

	if not force then
		if difficulty < config.MinDifficulty then
			return false
		end
		if now - eventCooldowns.EliteSpawn < config.Cooldown then
			return false
		end
		if math.random() > config.ChancePerCheck then
			return false
		end
	end

	-- Spawn elite!
	local spawnPos = getSpawnPositionNearPlayers(40)
	if not spawnPos then
		if force then
			warn("[DirectorService] Cannot spawn elite: No valid spawn position")
		end
		return false
	end

	if EnemyService then
		-- Spawn a Brute as elite (tankier base type)
		local enemy = EnemyService:SpawnEnemy("Brute", spawnPos)
		if enemy then
			-- Apply elite modifiers (use attributes, no Humanoid)
			local maxHP: number = (enemy:GetAttribute("MaxHealth") :: number?) or 100
			enemy:SetAttribute("MaxHealth", math.floor(maxHP * config.HealthMultiplier))
			enemy:SetAttribute("Health", enemy:GetAttribute("MaxHealth"))

			-- Scale size
			local rootPart = enemy:FindFirstChild("HumanoidRootPart")
			if rootPart then
				enemy:ScaleTo(config.SizeMultiplier)
			end

			-- Apply color tint
			for _, part in enemy:GetDescendants() do
				if part:IsA("BasePart") then
					part.Color = config.Color
					part.Material = Enum.Material.Neon
				end
			end

			-- Tag as elite
			enemy:SetAttribute("IsElite", true)
			enemy.Name = "Elite_" .. enemy.Name

			eventCooldowns.EliteSpawn = now
			print("[DirectorService] ELITE SPAWN at difficulty", string.format("%.2f", difficulty))

			-- Notify clients
			local eventRemote = Remotes:GetEvent(DirectorConfig.Remotes.EventTriggered)
			if eventRemote then
				eventRemote:FireAllClients({
					EventType = "EliteSpawn",
					Position = spawnPos,
					EnemyModel = enemy,
				})
			end

			return true
		end
	end

	return false
end

--[[
    Try to trigger a horde wave
]]
local function tryHordeWave(difficulty: number, now: number, force: boolean?): boolean
	local config = DirectorConfig.Events.HordeWave
	if not config.Enabled and not force then
		return false
	end

	if not force then
		if difficulty < config.MinDifficulty then
			return false
		end
		if now - eventCooldowns.HordeWave < config.Cooldown then
			return false
		end
		if math.random() > config.ChancePerCheck then
			return false
		end
	end

	-- Get player position for spawn center
	local players = Players:GetPlayers()
	if #players == 0 then
		return false
	end

	local targetPlayer = players[math.random(#players)]
	local character = targetPlayer.Character
	if not character or not character.PrimaryPart then
		return false
	end

	local centerPos = character.PrimaryPart.Position

	-- Calculate enemy count
	local difficultyBonus = math.floor((difficulty - config.MinDifficulty) * config.EnemyCountPerDifficulty)
	local enemyCount = config.EnemyCount + difficultyBonus

	-- Warn clients
	local warningRemote = Remotes:GetEvent(DirectorConfig.Remotes.HordeWarning)
	if warningRemote then
		warningRemote:FireAllClients({
			Position = centerPos,
			EnemyCount = enemyCount,
			Delay = config.AnnounceDuration,
		})
	end

	print("[DirectorService] HORDE WARNING! Spawning", enemyCount, "enemies in", config.AnnounceDuration, "seconds")

	-- Delayed spawn
	task.delay(config.AnnounceDuration, function()
		if not EnemyService then
			return
		end

		for i = 1, enemyCount do
			local angle = (i / enemyCount) * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * config.SpawnRadius, 0, math.sin(angle) * config.SpawnRadius)

			local spawnPos = centerPos + offset
			EnemyService:SpawnEnemy("Minion", spawnPos)
		end

		print("[DirectorService] HORDE SPAWNED:", enemyCount, "enemies")

		-- Notify clients
		local eventRemote = Remotes:GetEvent(DirectorConfig.Remotes.EventTriggered)
		if eventRemote then
			eventRemote:FireAllClients({
				EventType = "HordeWave",
				Position = centerPos,
				EnemyCount = enemyCount,
			})
		end
	end)

	eventCooldowns.HordeWave = now
	return true
end

--[[
    updateCreditDirector
    ─────────────────────────────────────────────────────────
    The primary enemy spawn driver. Replaces the old per-event
    random roll system as the main source of new enemies.

    CREDIT GROWTH:
        credits/sec = BaseGrowthRate + (diff - 1.0) × ScalingGrowthRate
        This scales naturally with difficulty so late-game
        waves arrive faster without tuning spawn intervals.

    PACING STATE MACHINE:
        Lull  → Director earns credits quietly. No spawns.
                Transitions to Ramp when credits >= SpendThreshold
                AND the lull timer has expired.
        Ramp  → Spends credits every SpawnTickInterval seconds.
                Picks elite (Brute) or grunt based on difficulty.
                Transitions to Lull when credits <= LullThreshold.

    ELITE SCALING:
        eliteChance = clamp((difficulty - 2.0) × 0.2, 0, 0.35)
        • At difficulty 1.0 → 0%   Brute chance
        • At difficulty 2.0 → 0%   Brute chance (starts here)
        • At difficulty 3.75 → 35% Brute chance (capped)
    ─────────────────────────────────────────────────────────
]]
local function updateCreditDirector(now: number)
	if not isRunning then
		return
	end
	if not EnemyService then
		return
	end

	local cfg = DirectorConfig.Credits
	if not cfg then
		-- Config not yet updated — silently skip
		return
	end

	-- ── 1. Earn credits (scales with current difficulty) ──────
	-- Growth rate is proportional to difficulty so harder runs
	-- generate pressure faster, matching the RoR2 experience.
	local growthRate = cfg.BaseGrowthRate + (currentDifficulty - DirectorConfig.BaseDifficulty) * cfg.ScalingGrowthRate
	-- Accumulate over the UpdateInterval tick period
	directorCredits = math.min(directorCredits + growthRate * DirectorConfig.UpdateInterval, cfg.MaxCredits)

	-- ── 2. Lull → Ramp transition ─────────────────────────────
	if directorState == "Lull" then
		if directorCredits >= cfg.SpendThreshold and now >= lullEndTime then
			directorState = "Ramp"
			print(
				string.format(
					"[Director] ► RAMP   | Credits: %d | Difficulty: %.2f",
					math.floor(directorCredits),
					currentDifficulty
				)
			)
		end
		return -- No spawning during Lull
	end

	-- ── 3. Ramp → Lull transition ─────────────────────────────
	if directorCredits <= cfg.LullThreshold then
		directorState = "Lull"
		lullEndTime = now + cfg.LullDuration
		print(string.format("[Director] ● LULL   | Recharging for %.1fs", cfg.LullDuration))
		return
	end

	-- ── 4. Enemy cap: pause spending if at capacity ───────────
	-- ── 4. Enemy cap: pause spending if at capacity ───────────
	-- Cap is defined in EnemyConfig.AI.MaxActiveEnemies (default 50).
	local enemyCount = EnemyService:GetEnemyCount()
	local enemyCap = 50 -- fallback
	do
		local ok, ec = pcall(function()
			return require(
				game:GetService("ReplicatedStorage")
					:WaitForChild("Shared")
					:WaitForChild("Config")
					:WaitForChild("EnemyConfig")
			).AI.MaxActiveEnemies
		end)
		if ok and type(ec) == "number" then
			enemyCap = ec
		end
	end
	if enemyCount >= enemyCap then
		return
	end

	-- ── 5. Spawn tick throttle ────────────────────────────────
	-- SpawnTickInterval controls the rhythm of a wave.
	-- The Director won't spawn faster than this even with full credits.
	if now - lastSpawnTick < cfg.SpawnTickInterval then
		return
	end
	lastSpawnTick = now

	-- ── 6. Pick enemy type ────────────────────────────────────
	-- Elite chance scales smoothly from 0% (diff 2.0) to 35% (diff 3.75+).
	-- Elites cost 5 credits so they appear naturally less often.
	local spawnType: string
	local spawnCost: number

	local eliteChance = math.clamp((currentDifficulty - 2.0) * 0.2, 0, 0.35)
	if math.random() < eliteChance and directorCredits >= cfg.SpawnCosts.Elite then
		spawnType = "Brute"
		spawnCost = cfg.SpawnCosts.Elite
	else
		-- Weighted grunt table: Minions are most common, others flavour the mix
		local grunts = {
			"Minion",
			"Minion",
			"Minion", -- 3/7 ≈ 43%
			"MossFrog",
			"MossFrog", -- 2/7 ≈ 29%
			"Shooter", -- 1/7 ≈ 14%
			"Brute", -- 1/7 ≈ 14% (low-cost "budget elite")
		}
		-- Block Brute if we can't afford the elite cost
		local roll = grunts[math.random(#grunts)]
		if roll == "Brute" and directorCredits < cfg.SpawnCosts.Elite then
			roll = "Minion" -- downgrade to grunt
		end
		spawnType = roll
		spawnCost = if roll == "Brute" then cfg.SpawnCosts.Elite else cfg.SpawnCosts.Grunt
	end

	-- ── 7. Find spawn position near a random player ───────────
	local spawnPos = getSpawnPositionNearPlayers(40)
	if not spawnPos then
		return
	end

	-- ── 8. Spend credits and call EnemyService ────────────────
	local enemy = EnemyService:SpawnEnemy(spawnType, spawnPos)
	if enemy then
		directorCredits = directorCredits - spawnCost
		-- Uncomment for verbose spawn logging:
		-- print(string.format("[Director] Spawned %-10s | -%d cr | Bank: %d",
		--     spawnType, spawnCost, math.floor(directorCredits)))
	end
end

--[[
    Main update loop
]]
local function onHeartbeat(deltaTime: number)
	if not isRunning then
		return
	end

	local now = tick()

	-- Throttle updates
	if now - lastUpdateTime < DirectorConfig.UpdateInterval then
		return
	end
	lastUpdateTime = now

	-- Calculate difficulty
	local oldDifficulty = currentDifficulty
	currentDifficulty = calculateDifficulty()

	-- Get multipliers
	local multipliers = getStatMultipliers(currentDifficulty)

	-- Broadcast difficulty update to clients (for visuals)
	local tier = getCurrentTier(currentDifficulty)
	local difficultyRemote = Remotes:GetEvent(DirectorConfig.Remotes.DifficultyUpdate)
	if difficultyRemote then
		difficultyRemote:FireAllClients({
			Difficulty = currentDifficulty,
			TierName = tier.Name,
			TierColor = tier.Color,
			Multipliers = multipliers,
			RunTime = now - runStartTime,
		})
	end

	-- Log tier changes
	local oldTier = getCurrentTier(oldDifficulty)
	if tier.Name ~= oldTier.Name then
		print("[DirectorService] DIFFICULTY TIER:", tier.Name, "(" .. string.format("%.2f", currentDifficulty) .. "x)")
	end

	-- ── Primary spawn driver: Credit Budget ───────────────────
	updateCreditDirector(now)

	-- ── Supplemental events (elite/horde on random triggers) ──
	-- These fire rarely on top of the credit-funded waves,
	-- adding surprise spikes. Forced via /elite and /horde commands.
	tryEliteSpawn(currentDifficulty, now)
	tryHordeWave(currentDifficulty, now)
end

-- Public API --

--[[
    Get current difficulty multiplier
]]
function DirectorService:GetDifficulty(): number
	return currentDifficulty
end

--[[
    Get current difficulty tier info
]]
function DirectorService:GetCurrentTier(): { Name: string, Color: Color3 }
	return getCurrentTier(currentDifficulty)
end

--[[
    Get stat multipliers for spawning enemies
]]
function DirectorService:GetStatMultipliers(): { Health: number, Damage: number, Speed: number }
	return getStatMultipliers(currentDifficulty)
end

--[[
    Get current spawn interval based on difficulty
]]
function DirectorService:GetSpawnInterval(): number
	local progress = (currentDifficulty - DirectorConfig.BaseDifficulty)
		/ (DirectorConfig.MaxDifficulty - DirectorConfig.BaseDifficulty)
	progress = math.clamp(progress, 0, 1)

	return DirectorConfig.BaseSpawnInterval
		- (DirectorConfig.BaseSpawnInterval - DirectorConfig.MinSpawnInterval) * progress
end

--[[
    Get spawn count based on difficulty
]]
function DirectorService:GetSpawnCount(): number
	local progress = (currentDifficulty - DirectorConfig.BaseDifficulty)
		/ (DirectorConfig.MaxDifficulty - DirectorConfig.BaseDifficulty)
	progress = math.clamp(progress, 0, 1)

	return math.floor(
		DirectorConfig.SpawnCountBase + (DirectorConfig.SpawnCountMax - DirectorConfig.SpawnCountBase) * progress
	)
end

--[[
    Get run time in seconds
]]
function DirectorService:GetRunTime(): number
	if not isRunning then
		return 0
	end
	return tick() - runStartTime
end

--[[
    Check if a run is active
]]
function DirectorService:IsRunning(): boolean
	return isRunning
end

--[[
    Start a new run (resets difficulty)
]]
function DirectorService:StartRun()
	runStartTime = tick()
	currentDifficulty = DirectorConfig.BaseDifficulty
	isRunning = true
	lastUpdateTime = 0

	-- Reset credit director state
	directorCredits = 0
	directorState = "Lull"
	lullEndTime = 0
	lastSpawnTick = 0

	-- Reset event cooldowns
	for event in eventCooldowns do
		eventCooldowns[event] = 0
	end

	print("[DirectorService] RUN STARTED - Difficulty begins at", DirectorConfig.BaseDifficulty)

	-- Initial broadcast
	local tier = getCurrentTier(currentDifficulty)
	local difficultyRemote = Remotes:GetEvent(DirectorConfig.Remotes.DifficultyUpdate)
	if difficultyRemote then
		difficultyRemote:FireAllClients({
			Difficulty = currentDifficulty,
			TierName = tier.Name,
			TierColor = tier.Color,
			Multipliers = getStatMultipliers(currentDifficulty),
			RunTime = 0,
		})
	end
end

--[[
    End the current run
]]
function DirectorService:EndRun()
	isRunning = false
	-- Reset credit state so no phantom credits carry into the next run
	directorCredits = 0
	directorState = "Lull"
	lullEndTime = 0
	lastSpawnTick = 0
	local runTime = tick() - runStartTime
	print(
		"[DirectorService] RUN ENDED - Duration:",
		string.format("%.1f", runTime),
		"seconds, Final difficulty:",
		string.format("%.2f", currentDifficulty)
	)
end

--[[
    Get credit director debug info (for dev UI / tooling)
    Returns the current credit balance and pacing state.
]]
function DirectorService:GetCreditDebug(): { Credits: number, State: string, GrowthRate: number }
	local cfg = DirectorConfig.Credits
	local growthRate = 0
	if cfg then
		growthRate = cfg.BaseGrowthRate + (currentDifficulty - DirectorConfig.BaseDifficulty) * cfg.ScalingGrowthRate
	end
	return {
		Credits = math.floor(directorCredits),
		State = directorState,
		GrowthRate = math.floor(growthRate * 10) / 10,
	}
end

--[[
    Force set difficulty (for testing)
]]
function DirectorService:SetDifficulty(difficulty: number)
	currentDifficulty = math.clamp(difficulty, DirectorConfig.BaseDifficulty, DirectorConfig.MaxDifficulty)

	-- Adjust run start time so the timer matches the difficulty (fake the time)
	-- diff = base + (mins * rate)
	-- mins = (diff - base) / rate
	local targetMinutes = (currentDifficulty - DirectorConfig.BaseDifficulty) / DirectorConfig.DifficultyPerMinute
	runStartTime = tick() - (targetMinutes * 60)

	print("[DirectorService] Difficulty manually set to", currentDifficulty)
end

--[[
    Handle debug commands
]]
local function setupDebugCommands()
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(msg)
			local args = string.split(msg, " ")
			local cmd = string.lower(args[1])

			if cmd == "/diff" or cmd == "/difficulty" then
				local amount = tonumber(args[2])
				if amount then
					DirectorService:SetDifficulty(amount)
				end
			elseif cmd == "/elite" then
				print("Forcing Elite Spawn...")
				tryEliteSpawn(100, tick(), true) -- Force spawn
			elseif cmd == "/horde" then
				print("Forcing Horde Wave...")
				tryHordeWave(100, tick(), true) -- Force wave
			elseif cmd == "/reset" then
				DirectorService:StartRun()
			elseif cmd == "/time" then
				local mult = tonumber(args[2]) or 10
				DirectorConfig.DifficultyPerMinute = mult
				print("Time scaling set to " .. mult .. "x normal speed")
			end
		end)
	end)
end

--[[
    Initialize the service
]]
function DirectorService:Init()
	print("[DirectorService] Initializing...")

	-- Initialize remotes
	Remotes:InitServer()

	-- Setup debug commands
	setupDebugCommands()
end

--[[
    Start the service
]]
function DirectorService:Start()
	print("[DirectorService] Starting...")

	-- Get reference to EnemyService
	EnemyService = require(script.Parent.EnemyService)

	-- Start the update loop
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Auto-start run when first player joins
	local function onPlayerAdded(player)
		if not isRunning and #Players:GetPlayers() >= 1 then
			-- Small delay to let player spawn
			task.delay(3, function()
				if not isRunning then
					self:StartRun()
				end
			end)
		end
	end

	Players.PlayerAdded:Connect(onPlayerAdded)

	-- Check if players already exist
	if #Players:GetPlayers() > 0 then
		onPlayerAdded(Players:GetPlayers()[1])
	end

	-- Make globally accessible for other services
	_G.DirectorService = self

	print("[DirectorService] Started successfully")
end

return DirectorService
