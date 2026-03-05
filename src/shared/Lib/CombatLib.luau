--[[
    CombatLib.luau
    Shared combat utility functions.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))

local CombatLib = {}

-- Cached OverlapParams to avoid allocation on every call
local sharedOverlapParams = OverlapParams.new()
sharedOverlapParams.FilterType = Enum.RaycastFilterType.Exclude

--[[
    Finds models with the Enemy tag or TrainingDummy tag within a radius.
]]
function CombatLib.getEnemiesInRadius(position: Vector3, radius: number, excludeList: { Instance }?, grid: any?): { Model }
	local enemies = {}
	local checked = {}

	if grid then
		-- O(k) spatial grid query
		local candidates = grid:QueryRadiusPrecise(position, radius, function(e: any): Vector3
			return e.RootPart and e.RootPart.Parent and e.RootPart.Position or position
		end)

		-- Helper to check if model is in excludeList
		local function isExcluded(model: Model): boolean
			if not excludeList then return false end
			for _, excluded in excludeList do
				if model == excluded or model:IsDescendantOf(excluded) then
					return true
				end
			end
			return false
		end

		for _, entity in candidates do
			local model = entity.Model
			if model and not checked[model] and not isExcluded(model) then
				checked[model] = true
				-- Only process if alive (grid handles tag/type implicitly as it only stores enemies)
				-- We double-check health/IsDead attribute just like the naive path
				local isAlive = false
				if model:GetAttribute("IsEnemy") then
					local health = model:GetAttribute("Health") or 0
					if health > 0 and not model:GetAttribute("IsDead") then
						isAlive = true
					end
				else
					local hum = model:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 then
						isAlive = true
					end
				end

				if isAlive then
					table.insert(enemies, model)
				end
			end
		end
	else
		-- Fallback: O(n) naive part bounds query
		-- Reuse cached params and update filter list
		sharedOverlapParams.FilterDescendantsInstances = excludeList or {}

		local parts = workspace:GetPartBoundsInRadius(position, radius, sharedOverlapParams)

		-- Clear references to avoid memory leaks
		sharedOverlapParams.FilterDescendantsInstances = {}

		for _, part in parts do
			local model = part:FindFirstAncestorOfClass("Model")
			if model and not checked[model] then
				checked[model] = true
				if
					CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag)
					or CollectionService:HasTag(model, "TrainingDummy")
				then
					-- Attribute-based enemies (IsEnemy / Health / IsDead)
					if model:GetAttribute("IsEnemy") then
						local health = model:GetAttribute("Health") or 0
						if health > 0 and not model:GetAttribute("IsDead") then
							table.insert(enemies, model)
						end
					else
						-- Fallback: Humanoid-based (TrainingDummy, legacy targets)
						local hum = model:FindFirstChildOfClass("Humanoid")
						if hum and hum.Health > 0 then
							table.insert(enemies, model)
						end
					end
				end
			end
		end
	end

	return enemies
end

return CombatLib
