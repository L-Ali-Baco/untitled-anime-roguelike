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

-- Player scrap balances: { [Player]: number }
local scrapBalances = {}

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
    Economy Functions
]]
function ItemService:GetScrap(player: Player): number
	return scrapBalances[player] or 0
end

function ItemService:AddScrap(player: Player, amount: number)
	scrapBalances[player] = self:GetScrap(player) + amount
	player:SetAttribute("Scrap", scrapBalances[player])
end

function ItemService:SpendScrap(player: Player, amount: number): boolean
	local current = self:GetScrap(player)
	if current >= amount then
		scrapBalances[player] = current - amount
		player:SetAttribute("Scrap", scrapBalances[player])
		return true
	end
	return false
end

--[[
    Grant an item to a player
]]
function ItemService:GrantItem(player: Player, itemKey: string)
	local item = ItemRegistry.GetItem(itemKey)
	if not item then
		return
	end

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
	if not inv then
		return
	end

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
	if not activeChests[chest] then
		return
	end
	activeChests[chest] = nil

	-- Grant random item
	local itemKey = getRandomItemKey()
	self:GrantItem(player, itemKey)

	-- Cleanup chest
	chest:Destroy()
end

--[[
    Spawn a W1_Chest at a position
]]
function ItemService:SpawnW1Chest(position: Vector3)
	local chestPrefab = ReplicatedStorage:FindFirstChild("W1_Chest", true)
	local chest

	if chestPrefab and chestPrefab:IsA("Model") then
		chest = chestPrefab:Clone()
		if chest.PrimaryPart then
			chest:PivotTo(CFrame.new(position))
		else
			chest:MoveTo(position)
		end
		chest.Parent = workspace
	elseif chestPrefab and chestPrefab:IsA("BasePart") then
		chest = chestPrefab:Clone()
		chest.Position = position + Vector3.new(0, chest.Size.Y / 2, 0)
		chest.Parent = workspace
	else
		-- Fallback to basic part if model not found
		chest = Instance.new("Part")
		chest.Name = "W1_Chest"
		chest.Size = Vector3.new(4, 3, 3)
		chest.Position = position + Vector3.new(0, 1.5, 0)
		chest.Color = Color3.fromRGB(180, 150, 50) -- Goldish color to distinguish
		chest.Material = Enum.Material.Metal
		chest.Anchored = true
		chest.CanCollide = true
		chest.Parent = workspace
	end

	-- Add or update ProximityPrompt
	local prompt = chest:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = chest:IsA("Model") and (chest.PrimaryPart or chest:FindFirstChildWhichIsA("BasePart")) or chest
	end

	prompt.ActionText = "Open W1_Chest (25 Scrap)"
	prompt.ObjectText = "Special Loot"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 15
	prompt.RequiresLineOfSight = false

	activeChests[chest] = true
	CollectionService:AddTag(chest, "W1_Chest")

	prompt.Triggered:Connect(function(player)
		self:OpenW1Chest(chest, player)
	end)

	local spawnRemote = Remotes:GetEvent("ChestSpawned")
	if spawnRemote then
		spawnRemote:FireAllClients(position)
	end
end

--[[
    Handle opening a W1_Chest
]]
function ItemService:OpenW1Chest(chest: Instance, player: Player)
	if not activeChests[chest] then
		return
	end

	-- Attempt to purchase
	if self:SpendScrap(player, 25) then
		activeChests[chest] = nil

		-- Get 3 distinct random items
		local items = {}
		while #items < 3 do
			local key = getRandomItemKey()
			if not table.find(items, key) then
				table.insert(items, key)
			end
		end

		-- Disable prompt immediately
		local prompt = chest:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = false
		end

		-- Wait briefly to avoid popping out instantly
		task.delay(0.5, function()
			if chest then
				chest:Destroy()
			end
		end)

		local promptRemote = Remotes:GetEvent("PromptItemSelection")
		if promptRemote then
			promptRemote:FireClient(player, chest, items[1], items[2], items[3])
		end
	else
		-- Feedback for not enough scrap
		local debugRemote = Remotes:GetEvent("DebugMessage")
		if debugRemote then
			debugRemote:FireClient(player, "Not enough Scrap! Need 25.", Color3.new(1, 0, 0))
		end
	end
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
			elseif cmd == "/chest" then
				if player.Character and player.Character.PrimaryPart then
					local spawnPos = player.Character.PrimaryPart.Position
						+ (player.Character.PrimaryPart.CFrame.LookVector * 10)
					ItemService:SpawnW1Chest(spawnPos)
					print("Spawned W1_Chest")
				end
			end
		end)
	end)
end

function ItemService:Start()
	-- Cleanup on leave
	Players.PlayerRemoving:Connect(function(player)
		inventories[player] = nil
		scrapBalances[player] = nil
	end)

	setupDebugCommands()

	-- Handle item selection from W1_Chest
	local selectRemote = Remotes:GetEvent("SelectChestItem")
	if selectRemote then
		selectRemote.OnServerEvent:Connect(function(player, chestInstance, chosenItemKey)
			if chosenItemKey then
				self:GrantItem(player, chosenItemKey)
			end
		end)
	end

	print("[ItemService] Started")
end

return ItemService
