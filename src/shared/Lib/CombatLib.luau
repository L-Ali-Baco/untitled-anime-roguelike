--[[
    CombatLib.luau
    Shared combat utility functions.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))

local CombatLib = {}

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

--[[
    Finds models with the Enemy tag or TrainingDummy tag within a radius.
]]
function CombatLib.getEnemiesInRadius(position: Vector3, radius: number, excludeList: { Instance }?): { Model }
	local enemies = {}
	-- OPTIMIZATION: Reuse OverlapParams to avoid allocation
	overlapParams.FilterDescendantsInstances = excludeList or {}

	local parts = workspace:GetPartBoundsInRadius(position, radius, overlapParams)
	local checked = {}

	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not checked[model] then
			checked[model] = true
			if
				CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag)
				or CollectionService:HasTag(model, "TrainingDummy")
			then
				local hum = model:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					table.insert(enemies, model)
				end
			end
		end
	end

	return enemies
end

return CombatLib
