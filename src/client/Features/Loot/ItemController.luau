--[[
    ItemController.luau
    Client-side item management and visual feedback.
    Listens for item gains and triggers notifications/VFX.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ItemRegistry = require(Shared:WaitForChild("Config"):WaitForChild("ItemRegistry"))

local ItemController = {
	Name = "ItemController",
}

-- References (set in Init)
local DamageNumbers = nil
local discoveryUI = nil

--[[
    Trigger visual notification for gaining an item
]]
local function notifyItemGain(itemKey: string, count: number)
	local item = ItemRegistry.GetItem(itemKey)
	if not item then return end
	
	print("[ItemController] GAINED ITEM:", item.Name, "(Total: " .. count .. ")")
	
	-- Show proper pop-up
	if discoveryUI then
		discoveryUI.show(itemKey)
	end
	
	-- Display a nice notification in the middle of the screen
	-- For now, we'll use DamageNumbers system to float text over the player
	if DamageNumbers then
		local char = Players.LocalPlayer.Character
		if char then
			DamageNumbers:SpawnText(char:GetPivot().Position + Vector3.new(0, 5, 0), item.Name:upper(), "Normal")
		end
	end
end

--[[
    Play chest spawn VFX
]]
local function onChestSpawned(position: Vector3)
	-- Raycast down to find ground
	local rayResult = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	local groundPos = rayResult and rayResult.Position or position
	
	-- Create impact particles
	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1)
	part.Position = groundPos
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Parent = workspace
	
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	
	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Color3.fromRGB(255, 200, 50))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Lifetime = NumberRange.new(0.5, 1)
	particles.Speed = NumberRange.new(10, 20)
	particles.Rate = 0
	particles.Parent = attachment
	
	particles:Emit(30)
	
	game:GetService("Debris"):AddItem(part, 2)
end

function ItemController:Init()
	-- Get VFX modules
	local function tryRequire(path)
		local success, result = pcall(function()
			return require(path)
		end)
		return success and result or nil
	end

	DamageNumbers = tryRequire(script.Parent.Parent.Parent.VFX.DamageNumbers)
	
	-- Initialize UI
	local DiscoveryScreen = tryRequire(script.Parent.Parent.Parent.UI.Screens.ItemDiscoveryScreen)
	if DiscoveryScreen then
		discoveryUI = DiscoveryScreen.new()
	end
	
	print("[ItemController] Initialized")
end

function ItemController:Start()
	-- Listen for item grants
	local grantRemote = Remotes:GetEvent("GrantItem")
	if grantRemote then
		grantRemote.OnClientEvent:Connect(notifyItemGain)
	end
	
	-- Listen for chest spawns
	local chestRemote = Remotes:GetEvent("ChestSpawned")
	if chestRemote then
		chestRemote.OnClientEvent:Connect(onChestSpawned)
	end
	
	print("[ItemController] Started")
end

return ItemController
