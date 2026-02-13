--[[
    ItemService.luau
    Handles player inventories, item granting, and chest logic.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ItemRegistry = require(Shared:WaitForChild("Config"):WaitForChild("ItemRegistry"))

local ItemService = {
	Name = "ItemService",
}

-- Player inventories: { [Player]: { [string]: number } }
local inventories = {}

-- Active Chests: { [Instance]: boolean }
local activeChests = {}

--[[
    Get a random item key from the pool
]]
local function getRandomItemKey(): string
	return ItemRegistry.GetRandomItemKey()
end

--[[
    Get player inventory
]]
function ItemService:GetPlayerInventory(player: Player): { [string]: number }
	return inventories[player] or {}
end

--[[
    Grant an item to a player
]]
function ItemService:GrantItem(player: Player, itemKey: string)
	local item = ItemRegistry.GetItem(itemKey)
	if not item then return end
	
	if not inventories[player] then
		inventories[player] = {}
	end
	
	inventories[player][itemKey] = (inventories[player][itemKey] or 0) + 1
	
	-- Notify client
	local grantRemote = Remotes:GetEvent("GrantItem")
	if grantRemote then
		grantRemote:FireClient(player, itemKey, inventories[player][itemKey])
	end
	
	print("[ItemService] Granted", item.Name, "to", player.Name)
	
	-- Apply immediate stat boosts if needed (Health, etc.)
	-- Movement stats are handled by client reading attributes or state
	self:UpdatePlayerAttributes(player)
end

--[[
    Sync inventory to player attributes for client-side reading
]]
function ItemService:UpdatePlayerAttributes(player: Player)
	local inv = inventories[player]
	if not inv then return end
	
	for itemKey, count in pairs(inv) do
		player:SetAttribute("Item_" .. itemKey, count)
	end
end

--[[
    Spawn a loot chest at a position
]]
function ItemService:SpawnChest(position: Vector3)
	local chest = Instance.new("Part")
	chest.Name = "LootChest"
	chest.Size = Vector3.new(4, 3, 3)
	chest.Position = position + Vector3.new(0, 1.5, 0)
	chest.Color = Color3.fromRGB(150, 100, 50)
	chest.Material = Enum.Material.Wood
	chest.Anchored = true
	chest.CanCollide = true
	chest.Parent = workspace
	
	-- Add ProximityPrompt for interaction
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open Chest"
	prompt.ObjectText = "Loot"
	prompt.HoldDuration = 0.3 -- Snappier opening
	prompt.MaxActivationDistance = 15 -- Increased range
	prompt.RequiresLineOfSight = false -- More reliable on mobile/busy screens
	prompt.Parent = chest
	
	activeChests[chest] = true
	CollectionService:AddTag(chest, "LootChest")
	
	prompt.Triggered:Connect(function(player)
		self:OpenChest(chest, player)
	end)
	
	-- Notify clients for VFX
	local spawnRemote = Remotes:GetEvent("ChestSpawned")
	if spawnRemote then
		spawnRemote:FireAllClients(position)
	end
end

--[[
    Handle opening a chest
]]
function ItemService:OpenChest(chest: Instance, player: Player)
	if not activeChests[chest] then return end
	activeChests[chest] = nil
	
	-- Grant random item
	local itemKey = getRandomItemKey()
	self:GrantItem(player, itemKey)
	
	-- Cleanup chest
	chest:Destroy()
end

function ItemService:Init()
	print("[ItemService] Initializing...")
end

--[[
    Setup debug commands
]]
local function setupDebugCommands()
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(msg)
			local args = string.split(msg, " ")
			local cmd = string.lower(args[1])
			
			if cmd == "/give" then
				local itemKey = args[2]
				-- Partial match search
				for key, _ in pairs(ItemRegistry.Pool) do
					if string.find(string.lower(key), string.lower(itemKey or "")) then
						ItemService:GrantItem(player, key)
						return
					end
				end
				print("Item not found")
			end
		end)
	end)
end

function ItemService:Start()
	-- Cleanup on leave
	Players.PlayerRemoving:Connect(function(player)
		inventories[player] = nil
	end)
	
	setupDebugCommands()
	
	print("[ItemService] Started")
end

return ItemService
