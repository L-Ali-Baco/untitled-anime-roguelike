--[[
    TrainingDummy.luau
    Handles behavior for Training Dummies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Framework = require(ReplicatedStorage.Shared.Framework)
local Component = require(ReplicatedStorage.Shared.Framework.Component)

local TrainingDummy = Component.new({
	Tag = "TrainingDummy",
	Ancestor = workspace,
})

function TrainingDummy:Init()
	-- Ensure it's also tagged as Enemy for targeting systems
	if not CollectionService:HasTag(self.Instance, "Enemy") then
		CollectionService:AddTag(self.Instance, "Enemy")
	end

	-- Apply collision group
	for _, part in self.Instance:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Enemies"
		end
	end

	self.Humanoid = self.Instance:FindFirstChildOfClass("Humanoid")
	if self.Humanoid then
		-- Setup health regeneration logic
		self._healthChangedConn = self.Humanoid.HealthChanged:Connect(function(newHealth)
			self:OnHealthChanged(newHealth)
		end)

		self._diedConn = self.Humanoid.Died:Connect(function()
			self:OnDied()
		end)
	end
end

function TrainingDummy:OnHealthChanged(newHealth)
	if newHealth < self.Humanoid.MaxHealth and newHealth > 0 then
		local lastDamageTime = os.clock()
		self.LastDamageTime = lastDamageTime

		-- Reset health after 2 seconds of no damage
		task.delay(2, function()
			if self.LastDamageTime == lastDamageTime and self.Humanoid and self.Humanoid.Health > 0 then
				self.Humanoid.Health = self.Humanoid.MaxHealth
			end
		end)
	end
end

function TrainingDummy:OnDied()
	task.wait(0.5) -- Brief delay so death registers
	if self.Humanoid then
		self.Humanoid.Health = self.Humanoid.MaxHealth
	end
end

function TrainingDummy:Destroy()
	if self._healthChangedConn then
		self._healthChangedConn:Disconnect()
	end
	if self._diedConn then
		self._diedConn:Disconnect()
	end
end

return TrainingDummy
