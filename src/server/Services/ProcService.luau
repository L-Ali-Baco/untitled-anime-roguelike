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

local ItemService = require(script.Parent.ItemService)

local ProcService = {
	Name = "ProcService",
}

-- References
local CombatService = nil -- Circular dependency if required directly? We'll see.
-- CombatService calls ProcService, ProcService might need to deal damage via CombatService logic?
-- Better to handle damage directly here or replicate essential logic.

-- Cooldowns for procs per player/item to prevent infinite loops or lag
local procCooldowns = {} -- [Player][ProcID] = time

--[[
    Helper: Get enemies in radius
]]
local function getEnemiesInRadius(position: Vector3, radius: number, excludeModel: Model?): { Model }
	local enemies = {}
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { excludeModel }

	local parts = workspace:GetPartBoundsInRadius(position, radius, overlapParams)
	local checked = {}

	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not checked[model] then
			checked[model] = true
			if EnemyLib:IsAlive(model) then
				if
					CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag)
					or CollectionService:HasTag(model, "TrainingDummy")
				then
					table.insert(enemies, model)
				end
			end
		end
	end

	return enemies
end

--[[
    Effect: Chain Lightning (Static Filament)
]]
local function triggerChainLightning(
	attacker: Player,
	primaryTarget: Model,
	procData: any,
	stackCount: number,
	inventory: { [string]: number }?
)
	local damageMult = procData.Damage * stackCount

	-- Fetch player's dynamic base damage from StatLib
	local baseDamage = StatLib:GetStat(attacker, "Damage", 10, inventory) * (CombatConfig.Server.DamageMultiplier or 1)

	local radius = procData.Radius or 20
	local enemies = getEnemiesInRadius(primaryTarget:GetPivot().Position, radius, primaryTarget)

	-- Pick random targets (limit 3 for now)
	local chainCount = 0
	local maxChain = 3

	for _, enemy in enemies do
		if chainCount >= maxChain then
			break
		end

		-- Deal damage via EnemyLib (Directly for now, bypassing CombatService to avoid infinite loops)
		-- TODO: Should this trigger *other* procs? Usually no.
		EnemyLib:TakeDamage(enemy, baseDamage * damageMult)
		chainCount += 1

		-- VFX
		local procRemote = Remotes:GetEvent("ProcTriggered")
		if procRemote then
			procRemote:FireAllClients({
				Type = "ChainLightning",
				Source = primaryTarget,
				Target = enemy,
			})
		end

		print("ZAP! " .. enemy.Name)
	end
end

--[[
    Effect: Explosion (Volatile Casing)
]]
local function triggerExplosion(
	attacker: Player,
	deadTarget: Model,
	procData: any,
	stackCount: number,
	inventory: { [string]: number }?
)
	local radius = procData.Radius + (5 * (stackCount - 1)) -- Scaling radius
	local damageMult = procData.Damage * stackCount

	-- Fetch player's dynamic base damage from StatLib
	local baseDamage = StatLib:GetStat(attacker, "Damage", 10, inventory) * (CombatConfig.Server.DamageMultiplier or 1)

	local pos = deadTarget:GetPivot().Position
	local enemies = getEnemiesInRadius(pos, radius, deadTarget)

	for _, enemy in enemies do
		EnemyLib:TakeDamage(enemy, baseDamage * damageMult)
	end

	print("BOOM! Radius:", radius)
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
					-- Roll chance
					if math.random() <= proc.Chance then
						-- Trigger!
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
					-- Roll chance
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

function ProcService:Init()
	print("[ProcService] Initialized")
end

function ProcService:Start()
	print("[ProcService] Started")
end

return ProcService
