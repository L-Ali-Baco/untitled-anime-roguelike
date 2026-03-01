--[[
    CombatLib.luau
    Shared combat utility functions.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))

local CombatLib = {}

--[[
    Finds models with the Enemy tag or TrainingDummy tag within a radius.
    Optimized: O(N) distance check on active tagged instances instead of workspace spatial query.
]]
function CombatLib.getEnemiesInRadius(position: Vector3, radius: number, excludeList: { Instance }?): { Model }
	local enemies = {}

	-- Build a quick lookup for excluded models
	local excluded = {}
	if excludeList then
		for _, inst in excludeList do
			excluded[inst] = true
		end
	end

	-- Helper function to check and add valid enemies from a tag
	local function checkTagged(tag: string)
		for _, model in CollectionService:GetTagged(tag) do
			if excluded[model] then
				continue
			end

			local hum = model:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then
				continue
			end

			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if not root then
				continue
			end

			local distance = (root.Position - position).Magnitude
			if distance <= radius then
				table.insert(enemies, model)
				excluded[model] = true -- Prevent duplicate entries if model has multiple tags
			end
		end
	end

	checkTagged(CombatConfig.Targeting.TargetTag)
	checkTagged("TrainingDummy")

	return enemies
end

return CombatLib
