--[[
    Component.luau
    Base class for Components (Tag-based behavior).
    Optimized for StreamingEnabled and large worlds.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Promise = require(ReplicatedStorage.Packages.Promise)

local Component = {}
Component.__index = Component

--[=[
    Creates a new Component class.

    config = {
        Tag = "MyTag",
        Ancestor = workspace, -- Optional: Only match descendants of this ancestor
        Extensions = {}, -- Optional: Extensions to mix in
    }
]=]
function Component.new(config)
	local class = {}
	setmetatable(class, Component)
	class.__index = class

	class.Tag = config.Tag
	class.Ancestor = config.Ancestor
	class.Instances = {}

	return class
end

--[=[
    Starts listening for the tag.
    Call this AFTER defining all methods (Init, Start, etc.)
]=]
function Component:Register()
	if not self.Tag then return end

	local function onInstanceAdded(instance)
		self:_InstanceAdded(instance)
	end

	local function onInstanceRemoved(instance)
		self:_InstanceRemoved(instance)
	end

	-- Handle existing instances
	for _, instance in CollectionService:GetTagged(self.Tag) do
		task.spawn(onInstanceAdded, instance)
	end

	-- Handle new instances
	self._addedConnection = CollectionService:GetInstanceAddedSignal(self.Tag):Connect(onInstanceAdded)
	self._removedConnection = CollectionService:GetInstanceRemovedSignal(self.Tag):Connect(onInstanceRemoved)

	print("[Component] Registered component for tag:", self.Tag)
end

--[=[
    Internal: Called when an instance with the tag is added.
]=]
function Component:_InstanceAdded(instance)
	if self.Ancestor and not instance:IsDescendantOf(self.Ancestor) then
		return
	end

	if self.Instances[instance] then
		return -- Already initialized
	end

	-- Create new component instance
	local obj = setmetatable({}, self)
	obj.Instance = instance
	self.Instances[instance] = obj

	-- Call lifecycle methods
	if obj.Init then
		task.spawn(function()
			local success, err = pcall(function()
				obj:Init()
			end)
			if not success then
				warn("[Component] Failed to Init component for", instance.Name, ":", err)
			end
		end)
	end

	if obj.Start then
		task.spawn(function()
			local success, err = pcall(function()
				obj:Start()
			end)
			if not success then
				warn("[Component] Failed to Start component for", instance.Name, ":", err)
			end
		end)
	end
end

--[=[
    Internal: Called when an instance with the tag is removed.
]=]
function Component:_InstanceRemoved(instance)
	local obj = self.Instances[instance]
	if obj then
		if obj.Destroy then
			local success, err = pcall(function()
				obj:Destroy()
			end)
			if not success then
				warn("[Component] Failed to Destroy component for", instance.Name, ":", err)
			end
		end
		self.Instances[instance] = nil
	end
end

--[=[
    Utility: Get component instance from a Roblox Instance
]=]
function Component:Get(instance)
	return self.Instances[instance]
end

--[=[
    Base Init method (override this)
]=]
function Component:Init()
end

--[=[
    Base Start method (override this)
]=]
function Component:Start()
end

--[=[
    Base Destroy method (override this)
]=]
function Component:Destroy()
end

return Component
