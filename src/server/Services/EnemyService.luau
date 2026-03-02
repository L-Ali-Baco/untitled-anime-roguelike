--[[
	EnemyService.luau
	Server-side enemy orchestrator.

	NOW A THIN MANAGER — all AI logic lives in individual enemy class modules.

	Responsibilities:
	  - Maintain activeEnemies registry: { [Model]: BaseEnemyInstance }
	  - Build and inject the "services bag" so enemy classes can fire remotes
	    and deal damage without circular requires
	  - SpawnEnemy(type, pos): load the correct subclass, instantiate it, register it
	  - Run the AI Heartbeat: call enemy:Tick(dt) on each active enemy
	  - Track player I-frames (dodge immunity) and expose via services bag
	  - Expose the public API used by Director and Spawner (unchanged surface)

	Adding a new enemy type:
	  1. Create src/server/Enemies/MyEnemy.luau  (inherits BaseEnemy)
	  2. Add "MyEnemy" entry to ENEMY_CLASS_LOADERS below
	  3. Add "MyEnemy" config block to EnemyConfig.luau
	  That's it. No other files need touching.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

local EnemyService = {
	Name = "EnemyService",
}

-- ============================================================
-- STATE
-- ============================================================

-- Registry: Model → enemy class instance (BaseEnemy subclass)
local activeEnemies: { [Model]: any } = {}

-- I-frame expiry timestamps: set when player starts a dodge
-- Stored as os.clock() timestamps — server-side, tamper-proof
local playerIFrames: { [Player]: number } = {}
local playerLastDash: { [Player]: number } = {}

-- AI update budget accumulator
local aiUpdateAccumulator = 0

-- Attack token counters: { [Player]: number of enemies in attack state vs that player }
-- Maintained via notifyAttackStart/notifyAttackEnd in the services bag.
-- Replaces the O(n²) full-table scan that the original canAttack used.
local attackerCounts: { [Player]: number } = {}

-- Running enemy count — O(1) alternative to iterating activeEnemies for cap checks.
local activeEnemyCount = 0

-- EnemyStateChanged deduplication: tracks the last-sent state and send time per model.
-- Prevents spamming 600 remote deliveries/second on busy fights.
local lastSentState: { [Model]: string } = {}
local lastStateSentTime: { [Model]: number } = {}

-- Cached service references (populated in Start)
local MovementServiceRef: any = nil
local FlowFieldServiceRef: any = nil
local EconomyServiceRef: any = nil

-- ============================================================
-- ENEMY CLASS REGISTRY
-- Maps type string → lazy loader function.
-- Lazy loading means classes only require() when first spawned,
-- keeping boot time fast even with many enemy types.
-- ============================================================

local ENEMY_CLASS_LOADERS: { [string]: () -> any } = {
	Brute = function()
		return require(script.Parent.Parent.Enemies.Brute)
	end,
	Shooter = function()
		return require(script.Parent.Parent.Enemies.Shooter)
	end,
	Minion = function()
		return require(script.Parent.Parent.Enemies.Minion)
	end,
	MossFrog = function()
		return require(script.Parent.Parent.Enemies.MossFrog)
	end,
	Keg = function()
		return require(script.Parent.Parent.Enemies.Keg)
	end,
}

-- Cache loaded classes so we only require() once per type per server session
local loadedClasses: { [string]: any } = {}

local function getEnemyClass(enemyType: string): any?
	if loadedClasses[enemyType] then
		return loadedClasses[enemyType]
	end
	local loader = ENEMY_CLASS_LOADERS[enemyType]
	if not loader then
		warn(("[EnemyService] No class loader registered for type: %s"):format(enemyType))
		return nil
	end
	local ok, result = pcall(loader)
	if not ok then
		warn(("[EnemyService] Failed to load class %s: %s"):format(enemyType, result))
		return nil
	end
	loadedClasses[enemyType] = result
	return result
end

-- ============================================================
-- SERVICES BAG
-- Injected into every enemy instance at construction.
-- Provides callbacks so enemy classes can communicate outward
-- without holding a direct reference to EnemyService (breaks circular require).
-- ============================================================

local function buildServicesBag(): any
	return {
		-- Apply damage + knockback to a player (shield, resistance, I-frame handled here)
		dealDamage = function(player: Player, damage: number, knockback: Vector3?)
			EnemyService:_dealDamageToPlayer(player, damage, knockback)
		end,

		-- Tell the player their attack was dodged
		blockDamage = function(player: Player, enemy: Model, position: Vector3, amount: number)
			local remote = Remotes:GetEvent("DamageBlocked")
			if remote then
				remote:FireClient(player, {
					Enemy = enemy,
					Position = position,
					DamageBlocked = amount,
				})
			end
		end,

		-- Replicate attack VFX data to all clients
		fireEnemyAttack = function(payload: { [string]: any })
			local remote = Remotes:GetEvent("EnemyAttack")
			if remote then
				remote:FireAllClients(payload)
			end
		end,

		-- Replicate AI state change (for client VFX/animation controller).
		-- Rate-limited: fires at most once per 0.1 s per enemy, and only when state changes.
		-- Dead state bypasses the rate limit so death VFX always fires.
		fireEnemyStateChanged = function(model: Model, state: string)
			local now = os.clock()
			local isDead = state == "Dead"
			if not isDead then
				if lastSentState[model] == state then
					return -- Same state; no change to replicate
				end
				if (now - (lastStateSentTime[model] or 0)) < 0.1 then
					return -- Rate cap: max 10 Hz per enemy
				end
			end
			lastSentState[model] = state
			lastStateSentTime[model] = now
			local remote = Remotes:GetEvent("EnemyStateChanged")
			if remote then
				remote:FireAllClients(model, state)
			end
		end,

		-- Called by BaseEnemy._onDeath(): deregister from registry and replicate death
		fireEnemyDied = function(payload: { [string]: any })
			local model: Model = payload.Target
			local enemy = activeEnemies[model]
			-- Remove from registry immediately so Director credit accounting is accurate
			if activeEnemies[model] then
				activeEnemyCount = math.max(0, activeEnemyCount - 1)
			end
			activeEnemies[model] = nil
			lastSentState[model] = nil
			lastStateSentTime[model] = nil
			if enemy and MovementServiceRef then
				MovementServiceRef:Unregister(enemy)
			end
			-- Notify EconomyService so it can spawn gold orbs at the death position.
			-- Called before FireAllClients so the model is still in workspace and
			-- GetBoundingBox() in EconomyService returns a valid position.
			if EconomyServiceRef then
				EconomyServiceRef:OnEnemyDied(payload)
			end
			local remote = Remotes:GetEvent("EnemyDied")
			if remote then
				remote:FireAllClients(payload)
			end
		end,

		-- Returns the I-frame expiry os.clock() for a player (nil = no I-frames active)
		getIFrameExpiry = function(player: Player): number?
			return playerIFrames[player]
		end,

		-- Attack token check: O(1) lookup against the maintained counter.
		-- Enemies call notifyAttackStart/notifyAttackEnd on state transitions.
		canAttack = function(player: Player): boolean
			local max = (EnemyConfig.AttackTokens and EnemyConfig.AttackTokens.Normal) or 2
			return (attackerCounts[player] or 0) < max
		end,

		-- Increment the token counter when an enemy enters an attack state.
		notifyAttackStart = function(player: Player)
			attackerCounts[player] = (attackerCounts[player] or 0) + 1
		end,

		-- Decrement the token counter when an enemy leaves an attack state.
		notifyAttackEnd = function(player: Player)
			local current = attackerCounts[player] or 0
			attackerCounts[player] = math.max(0, current - 1)
		end,

		-- ── Flow field navigation callbacks ─────────────────────────────────────
		-- These are optional: if FlowFieldService hasn't baked yet or the
		-- enemy is outside the grid, GetDirection returns Vector3.zero and
		-- BaseEnemy:MoveTowardTarget falls back to direct targeting automatically.

		-- Returns the flow-field unit direction from `pos` toward `player`.
		-- O(1): four table lookups in the pre-computed BFS cost map.
		getFlowDirection = function(pos: Vector3, player: Player): Vector3
			if FlowFieldServiceRef then
				return FlowFieldServiceRef:GetDirection(pos, player)
			end
			return Vector3.zero
		end,

		-- Returns true when the flow field for `player` is stale (player has moved
		-- more than one cell width since the last BFS) or doesn't exist yet.
		shouldRebuildFlow = function(player: Player, targetPos: Vector3): boolean
			return FlowFieldServiceRef ~= nil and FlowFieldServiceRef:ShouldRebuild(player, targetPos)
		end,

		-- Triggers a BFS rebuild for `player` targeting `targetPos`.
		-- Self-deduplicating: after the first call, ShouldRebuild returns false
		-- for all other enemies in the same Heartbeat batch.
		rebuildFlow = function(player: Player, targetPos: Vector3)
			if FlowFieldServiceRef then
				FlowFieldServiceRef:RebuildForPlayer(player, targetPos)
			end
		end,
	}
end

-- Built once in Start() after EnemyService is fully constructed
local servicesBag: any = nil

-- ============================================================
-- INTERNAL: DAMAGE UTILITY
-- Centralised here so all enemy subclasses share the same
-- shield, resistance, and humanoid logic.
-- ============================================================

function EnemyService:_dealDamageToPlayer(player: Player, damage: number, knockback: Vector3?)
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	-- Flat damage reduction from armour/buffs
	local resistance: number = (character:GetAttribute("DamageResistance") :: number?) or 0
	if resistance > 0 then
		damage = damage * (1 - math.clamp(resistance, 0, 1))
	end

	-- Shield absorbs damage first
	local currentShield: number = (character:GetAttribute("Shield") :: number?) or 0
	if currentShield > 0 then
		if currentShield >= damage then
			character:SetAttribute("Shield", currentShield - damage)
			damage = 0
		else
			damage = damage - currentShield
			character:SetAttribute("Shield", 0)
		end
	end

	if damage > 0 then
		humanoid:TakeDamage(damage)
	end

	if knockback and rootPart and knockback.Magnitude > 0.01 then
		rootPart.AssemblyLinearVelocity += knockback
	end
end

-- ============================================================
-- INTERNAL: MODEL CREATION HELPERS
-- ============================================================

-- Apply Director difficulty multipliers to a config copy and set model attributes.
function EnemyService:_applyDirectorScaling(config: { [string]: any }, enemyModel: Model): { [string]: any }
	local healthMult = 1.0
	local speedMult = 1.0
	local damageMult = 1.0

	local DirectorService = _G.DirectorService
	if DirectorService and DirectorService:IsRunning() then
		local mults = DirectorService:GetStatMultipliers()
		healthMult = mults.Health
		speedMult = mults.Speed
		damageMult = mults.Damage
	end

	-- Shallow copy then override scaled fields
	local scaledConfig: { [string]: any } = {}
	for k, v in config do
		scaledConfig[k] = v
	end
	scaledConfig.Damage = config.Damage * damageMult

	-- EnemyLib sets Health, MaxHealth, WalkSpeed attributes on the model
	local scaledHealth = math.floor(config.Health * healthMult)
	local scaledSpeed = config.WalkSpeed * speedMult
	EnemyLib:SetupAttributes(enemyModel, scaledHealth, scaledHealth, scaledSpeed)

	-- Store multipliers as attributes for debugging / item interactions
	enemyModel:SetAttribute("HealthMultiplier", healthMult)
	enemyModel:SetAttribute("DamageMultiplier", damageMult)
	enemyModel:SetAttribute("SpeedMultiplier", speedMult)

	return scaledConfig
end

-- Fallback coloured box model for types without a real asset
function EnemyService:_createPlaceholderModel(enemyType: string, position: Vector3): Model
	local COLOR_MAP = {
		Brute = Color3.fromRGB(200, 50, 50),
		Shooter = Color3.fromRGB(200, 200, 50),
		MossFrog = Color3.fromRGB(60, 140, 60),
		Keg = Color3.fromRGB(255, 120, 0), -- Bright orange — visually distinct bomber
	}
	local SIZE_MAP = {
		Brute = Vector3.new(3, 3, 1.5),
		MossFrog = Vector3.new(2.5, 1.5, 2.5),
		Keg = Vector3.new(1.5, 1.5, 1.5), -- Small and compact
	}

	local model = Instance.new("Model")
	model.Name = enemyType

	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = SIZE_MAP[enemyType] or Vector3.new(2, 2, 1)
	torso.Position = position
	torso.Anchored = false
	torso.CanCollide = true
	torso.Color = COLOR_MAP[enemyType] or Color3.fromRGB(150, 150, 150)
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1, 1, 1)
	head.Position = position + Vector3.new(0, 2, 0)
	head.Color = torso.Color
	head.Anchored = false
	head.CanCollide = false
	head.Parent = model

	local weld = Instance.new("Weld")
	weld.Part0 = torso
	weld.Part1 = head
	weld.C0 = CFrame.new(0, 1.5, 0)
	weld.Parent = torso

	model.PrimaryPart = torso
	return model
end

-- ============================================================
-- PUBLIC API  (surface unchanged from original EnemyService)
-- ============================================================

--[[
	Spawn a new enemy of the given type at position.
	Returns the Model on success, nil if cap reached or type unknown.
]]
function EnemyService:SpawnEnemy(enemyType: string, position: Vector3, parent: Instance?): Model?
	local config = EnemyConfig.Types[enemyType]
	if not config then
		warn(("[EnemyService] Unknown enemy type: %s"):format(enemyType))
		return nil
	end

	-- Enforce global enemy cap (O(1) via maintained counter)
	if activeEnemyCount >= EnemyConfig.AI.MaxActiveEnemies then
		return nil
	end

	-- Load model: prefer asset from ReplicatedStorage.Shared.Assets.Enemies
	local enemyModel: Model? = nil
	local assetsFolder = Shared:FindFirstChild("Assets")
	if assetsFolder then
		local enemiesFolder = assetsFolder:FindFirstChild("Enemies")
		if enemiesFolder then
			local asset = enemiesFolder:FindFirstChild(enemyType)
			if asset then
				enemyModel = asset:Clone()
			end
		end
	end
	if not enemyModel then
		enemyModel = self:_createPlaceholderModel(enemyType, position)
	end

	enemyModel.Parent = parent or workspace

	-- Always reposition to the requested spawn point.
	-- PivotTo works with or without PrimaryPart (uses bounding-box centre as fallback),
	-- so the old `if PrimaryPart` guard was wrong: asset models without PrimaryPart set
	-- would silently stay at their ReplicatedStorage storage position.
	local _, modelSize = enemyModel:GetBoundingBox()
	enemyModel:PivotTo(CFrame.new(position + Vector3.new(0, modelSize.Y / 2 + 1, 0)))

	-- Scale stats by current difficulty
	local scaledConfig = self:_applyDirectorScaling(config, enemyModel)

	-- Instantiate the correct subclass (falls back to BaseEnemy if missing)
	local EnemyClass = getEnemyClass(enemyType)
	if not EnemyClass then
		warn(("[EnemyService] Falling back to BaseEnemy for unknown type: %s"):format(enemyType))
		EnemyClass = require(script.Parent.Parent.Enemies.BaseEnemy)
	end

	local ok, enemy = pcall(function()
		return EnemyClass.new(enemyModel, scaledConfig, servicesBag)
	end)
	if not ok then
		warn(("[EnemyService] Failed to instantiate %s: %s"):format(enemyType, enemy))
		enemyModel:Destroy()
		return nil
	end

	-- Activation delay: enemy stands frozen before AI activates
	local activationDelay = (EnemyConfig.Spawn and EnemyConfig.Spawn.ActivationDelay) or 0
	if activationDelay > 0 then
		enemy._activationEndTime = os.clock() + activationDelay
	end

	-- Register with MovementService for Boids separation
	if MovementServiceRef then
		MovementServiceRef:Register(enemy)
	end

	activeEnemies[enemyModel] = enemy
	activeEnemyCount += 1
	return enemyModel
end

--[[
	Register an already-existing enemy Model (e.g. manually placed in the workspace).
	Called automatically during Start() workspace scan.
]]
function EnemyService:RegisterEnemy(enemyModel: Model, enemyType: string?): any?
	local typeKey = enemyType or enemyModel.Name
	local config = EnemyConfig.Types[typeKey]
	if not config then
		config = EnemyConfig.Types.Minion
		typeKey = "Minion"
	end

	local scaledConfig = self:_applyDirectorScaling(config, enemyModel)
	local EnemyClass = getEnemyClass(typeKey) or require(script.Parent.Parent.Enemies.BaseEnemy)

	local ok, enemy = pcall(function()
		return EnemyClass.new(enemyModel, scaledConfig, servicesBag)
	end)
	if not ok then
		warn(("[EnemyService] RegisterEnemy failed for %s: %s"):format(typeKey, enemy))
		return nil
	end

	if MovementServiceRef then
		MovementServiceRef:Register(enemy)
	end

	activeEnemies[enemyModel] = enemy
	activeEnemyCount += 1
	return enemy
end

function EnemyService:ApplyHitstun(enemyModel: Model, duration: number?)
	local enemy = activeEnemies[enemyModel]
	if enemy then
		enemy:ApplyHitstun(duration)
	end
end

function EnemyService:GetEnemyCount(): number
	return activeEnemyCount
end

function EnemyService:GetActiveEnemies(): { [Model]: any }
	return activeEnemies
end

-- ============================================================
-- DEBUG COMMANDS  (/enemy <type>)
-- ============================================================

local function setupDebugCommands()
	-- Connect the chat handler for a single player.
	-- Extracted so it can be called for players already in-game (Studio playtest)
	-- as well as future joiners via PlayerAdded.
	local function connectChatted(player: Player)
		player.Chatted:Connect(function(msg: string)
			local args = string.split(msg, " ")
			local cmd = string.lower(args[1])

			if cmd == "/enemy" then
				local inputType = args[2] or "Minion"
				local resolvedType: string? = nil
				for typeName in EnemyConfig.Types do
					if string.lower(typeName) == string.lower(inputType) then
						resolvedType = typeName
						break
					end
				end
				if not resolvedType then
					print("[EnemyService] Unknown type:", inputType)
					return
				end
				local char = player.Character
				if not char or not char.PrimaryPart then
					return
				end
				local spawnPos = char.PrimaryPart.Position + char.PrimaryPart.CFrame.LookVector * 12
				EnemyService:SpawnEnemy(resolvedType, spawnPos)
			end
		end)
	end

	-- Hook players already present (e.g. developer in Studio playtest)
	for _, player in Players:GetPlayers() do
		connectChatted(player)
	end
	Players.PlayerAdded:Connect(connectChatted)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function EnemyService:Init()
	print("[EnemyService] Initializing...")
	Remotes:InitServer()
end

function EnemyService:Start()
	print("[EnemyService] Starting...")

	-- Cache service references (already started by bootstrap)
	MovementServiceRef = require(script.Parent.MovementService)
	FlowFieldServiceRef = require(script.Parent.FlowFieldService)
	EconomyServiceRef = require(script.Parent.EconomyService)

	-- Build the services bag now so closures capture the live EnemyService
	servicesBag = buildServicesBag()

	-- I-frame tracking via the dodge remote
	local iframeRemote = Remotes:GetEvent("IFrameStateChanged")
	if iframeRemote then
		iframeRemote.OnServerEvent:Connect(function(player: Player, isDashing: boolean)
			if isDashing then
				local now = os.clock()
				local MIN_DASH_INTERVAL = 0.3 -- Server-side cooldown enforcement
				local lastDash = playerLastDash[player] or 0
				if now - lastDash < MIN_DASH_INTERVAL then
					return -- Rate-limited
				end
				playerLastDash[player] = now
				playerIFrames[player] = now + MIN_DASH_INTERVAL
			else
				playerIFrames[player] = 0
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		playerIFrames[player] = nil
		playerLastDash[player] = nil
	end)

	-- Scan workspace for intentionally placed enemy models at server start.
	-- Only registers models that have a ManualEnemy = true attribute explicitly set.
	-- This prevents accidentally left-over test models from being picked up —
	-- the debug /enemy command always spawns via SpawnEnemy() which creates a fresh model,
	-- so workspace models are only for map-designers who want enemies pre-placed in the level.
	for _, obj in workspace:GetDescendants() do
		if obj:IsA("Model")
			and EnemyConfig.Types[obj.Name]
			and not activeEnemies[obj]
			and obj:GetAttribute("ManualEnemy") == true
		then
			self:RegisterEnemy(obj :: Model, obj.Name)
		end
	end

	-- ── Main AI Heartbeat ─────────────────────────────────────────────
	-- Runs at EnemyConfig.AI.UpdateRate Hz (default 20 Hz = 0.05s intervals).
	-- Each active enemy's Tick(dt) is wrapped in pcall so one broken enemy
	-- cannot stall the loop for all others (fail-safe bootstrap philosophy).
	RunService.Heartbeat:Connect(function(dt: number)
		aiUpdateAccumulator += dt
		if aiUpdateAccumulator < EnemyConfig.AI.UpdateRate then
			return
		end
		aiUpdateAccumulator = 0

		for model, enemy in activeEnemies do
			-- Guard: model was destroyed outside normal death flow (e.g. /clear)
			if not model.Parent then
				-- Release attack token if this enemy was mid-attack when forcibly removed
				if enemy.State == "Attack" or enemy.State == "LeapAttack" or enemy.State == "ChargeAttack" then
					if enemy.Target and typeof(enemy.Target) == "Instance" and enemy.Target:IsA("Player") then
						attackerCounts[enemy.Target] = math.max(0, (attackerCounts[enemy.Target] or 0) - 1)
					end
				end
				activeEnemyCount = math.max(0, activeEnemyCount - 1)
				activeEnemies[model] = nil
				lastSentState[model] = nil
				lastStateSentTime[model] = nil
				if MovementServiceRef then
					MovementServiceRef:Unregister(enemy)
				end
				continue
			end

			pcall(enemy.Tick, enemy, dt)
		end
	end)

	-- Clear attack counter when a player leaves (prevents stale entries)
	Players.PlayerRemoving:Connect(function(player)
		attackerCounts[player] = nil
		playerIFrames[player] = nil
		playerLastDash[player] = nil
	end)

	-- Make available globally for DirectorService (keeps existing API)
	_G.EnemyService = self

	setupDebugCommands()
	print("[EnemyService] Started — OOP enemy system active")
end

return EnemyService
