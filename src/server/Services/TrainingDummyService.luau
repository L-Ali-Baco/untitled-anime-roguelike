--[[
    TrainingDummyService.luau
    Manages Training Dummy components and tagging logic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Framework = require(ReplicatedStorage.Shared.Framework)
local Component = require(ReplicatedStorage.Shared.Framework.Component)

local TrainingDummyService = Framework.CreateService({
	Name = "TrainingDummyService",
})

function TrainingDummyService:Start()
	-- Register component
	local TrainingDummy = require(script.Parent.Parent.Components.TrainingDummy)
	TrainingDummy:Register()

	-- Tag existing dummies (for backward compatibility)
	for _, obj in workspace:GetChildren() do
		if obj.Name == "TrainingDummy" and obj:FindFirstChildOfClass("Humanoid") then
			if not CollectionService:HasTag(obj, "TrainingDummy") then
				CollectionService:AddTag(obj, "TrainingDummy")
			end
		end
	end

	-- Ideally, listen for newly added dummies
	-- But scanning all ChildAdded is expensive if there are many objects.
	-- It's better if the user tags them directly or uses a Spawner system.
	-- For now, we support workspace level additions.
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "TrainingDummy" and child:FindFirstChildOfClass("Humanoid") then
			if not CollectionService:HasTag(child, "TrainingDummy") then
				CollectionService:AddTag(child, "TrainingDummy")
			end
		end
	end)
end

return TrainingDummyService
