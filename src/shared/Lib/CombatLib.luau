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
function CombatLib.getEnemiesInRadius(position: Vector3, radius: number, excludeList: { Instance }?): { Model }
	local enemies = {}

	-- Reuse cached params and update filter list
	sharedOverlapParams.FilterDescendantsInstances = excludeList or {}

	local parts = workspace:GetPartBoundsInRadius(position, radius, sharedOverlapParams)

	-- Clear references to avoid memory leaks
	sharedOverlapParams.FilterDescendantsInstances = {}
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
