--[[
    ProcService.luau
    Handles "On-Hit", "On-Kill", and "On-Crit" effects from items.
    
    Responsibilities:
    - Listen for combat events or be called by CombatService
    - Check player inventory for items with 'Procs'
    - Roll RNG and trigger effects (Chain Lightning, Explosions, etc.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ItemRegistry = require(Shared:WaitForChild("Config"):WaitForChild("ItemRegistry"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))
local CombatLib = require(Shared:WaitForChild("Lib"):WaitForChild("CombatLib"))

local MathUtil = require(Shared:WaitForChild("Lib"):WaitForChild("MathUtil"))
local ItemService = require(script.Parent.ItemService)

local ProcService = {
	Name = "ProcService",
}

-- References
local CombatService = nil -- Circular dependency if required directly? We'll see.
-- CombatService calls ProcService, ProcService might need to deal damage via CombatService logic?
-- Better to handle damage directly here or replicate essential logic.

-- Cooldowns for procs per player/item to prevent spam on rapid-fire classes.
-- Structure: { [Player]: { [ProcId]: expiryTick } }
local procCooldowns: { [Player]: { [string]: number } } = {}

-- Minimum seconds between proc triggers for the same player+proc combination.
-- This prevents Scrapper (0.12s fire rate) from spamming ChainLightning 8x/sec.
local PROC_COOLDOWN = 0.25

local function checkAndSetProcCooldown(player: Player, procId: string): boolean
	local now = tick()
	if not procCooldowns[player] then
		procCooldowns[player] = {}
	end
	local expiry = procCooldowns[player][procId] or 0
	if now < expiry then
		return false -- still on cooldown
	end
	procCooldowns[player][procId] = now + PROC_COOLDOWN
	return true
end

--[[
    Effect: Chain Lightning (Static Filament)
    Stacking increases chain targets (more enemies hit), not raw damage.
    At 50 stacks without diminishing returns: 50×0.4 = 20× base damage per zap.
    With this formula: approaches 2.0× as a hard cap.
]]
local function triggerChainLightning(
	attacker: Player,
	primaryTarget: Model,
	procData: any,
	stackCount: number,
	inventory: { [string]: number }?
)
	-- Diminishing returns: base=0.4, hard cap=2.0 (5× the single-stack value)
	local damageMult = MathUtil.HyperbolicScale(stackCount, procData.Damage, 2.0)
	-- Fetch player's dynamic base damage from StatLib
	local baseDamage = StatLib:GetStat(attacker, "Damage", 10, inventory) * (CombatConfig.Server.DamageMultiplier or 1)

	local radius = procData.Radius or 20
	-- Extra stacks increase chain count (more satisfying than raw damage)
	local maxChain = math.min(3 + (stackCount - 1), 10) -- caps at 10 chains
	local enemies = CombatLib.getEnemiesInRadius(primaryTarget:GetPivot().Position, radius, { primaryTarget })

	local chainCount = 0
	for _, enemy in enemies do
		if chainCount >= maxChain then
			break
		end
		-- Bypasses CombatService intentionally: proc damage must not re-trigger procs.
		EnemyLib:TakeDamage(enemy, baseDamage * damageMult)
		chainCount += 1
		-- TODO: Fire remote for lightning VFX
	end
end

--[[
    Effect: Explosion (Volatile Casing)
    Stacking increases explosion radius (capped at 40 studs) and damage.
    At 50 stacks without caps: radius=260, damage=75× — screen-filling instant kills.
    With this formula: radius caps at 40, damage approaches 5.0× base.
]]
local function triggerExplosion(
	attacker: Player,
	deadTarget: Model,
	procData: any,
	stackCount: number,
	inventory: { [string]: number }?
)
	-- Radius: grows with stacks but hard-capped at 40 studs
	local radius = math.min(procData.Radius + (3 * (stackCount - 1)), 40)
	-- Damage: diminishing returns, base=1.5 (150%), hard cap=5.0 (500%)
	local damageMult = MathUtil.HyperbolicScale(stackCount, procData.Damage, 5.0)
	-- Fetch player's dynamic base damage from StatLib
	local baseDamage = StatLib:GetStat(attacker, "Damage", 10, inventory) * (CombatConfig.Server.DamageMultiplier or 1)

	local pos = deadTarget:GetPivot().Position
	local enemies = CombatLib.getEnemiesInRadius(pos, radius, { deadTarget })

	for _, enemy in enemies do
		EnemyLib:TakeDamage(enemy, baseDamage * damageMult)
	end
end

--[[
    Process On-Hit Procs
]]
function ProcService:ProcessHit(attacker: Player, target: Model, damageDealt: number, isCrit: boolean)
	local inventory = ItemService:GetPlayerInventory(attacker)

	for itemKey, count in pairs(inventory) do
		local item = ItemRegistry.GetItem(itemKey)
		if item and item.Procs then
			for _, proc in pairs(item.Procs) do
				-- Check trigger type
				local shouldTrigger = false
				if proc.Type == "OnHit" then
					shouldTrigger = true
				end
				if proc.Type == "OnCrit" and isCrit then
					shouldTrigger = true
				end

				if shouldTrigger then
					-- Cooldown gate first (cheap check before RNG)
					if checkAndSetProcCooldown(attacker, proc.Id) then
						-- Roll chance
						if math.random() <= proc.Chance then
							if proc.Id == "ChainLightning" then
								triggerChainLightning(attacker, target, proc, count, inventory)
							elseif proc.Id == "Vacuum" then
								-- triggerVacuum(...)
							end
						end
					end
				end
			end
		end
	end
end

--[[
    Process On-Kill Procs
]]
function ProcService:ProcessKill(attacker: Player, target: Model)
	local inventory = ItemService:GetPlayerInventory(attacker)

	for itemKey, count in pairs(inventory) do
		local item = ItemRegistry.GetItem(itemKey)
		if item and item.Procs then
			for _, proc in pairs(item.Procs) do
				if proc.Type == "OnKill" then
					if checkAndSetProcCooldown(attacker, proc.Id) then
						if math.random() <= proc.Chance then
							if proc.Id == "Explosion" then
								triggerExplosion(attacker, target, proc, count, inventory)
							end
						end
					end
				end
			end
		end
	end
end

function ProcService:Init()
	print("[ProcService] Initialized")
end

function ProcService:Start()
	-- Clean up cooldown table when players leave
	Players.PlayerRemoving:Connect(function(player)
		procCooldowns[player] = nil
	end)
	print("[ProcService] Started")
end

return ProcService
