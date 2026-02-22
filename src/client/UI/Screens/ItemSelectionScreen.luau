--[[
    ItemSelectionScreen.luau
    Displays 3 choices from a W1_Chest.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed

local ItemSelectionScreen = {}

function ItemSelectionScreen.new(InputController)
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local keys = { scope:Value(""), scope:Value(""), scope:Value("") }

	-- Forward ref: assigned after scope:New("ScreenGui") call below
	local screenGui = nil

	local function onOpen()
		if InputController then
			InputController:UnlockMouse()
			InputController:BlockInput()
		end
		-- Force cursor visible regardless of any other state
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true

		if screenGui then
			screenGui.Enabled = true
		end

		print(
			"[ItemSelectionScreen] Opened | MouseBehavior:",
			UserInputService.MouseBehavior,
			"| MouseIconEnabled:",
			UserInputService.MouseIconEnabled,
			"| ScreenGui.Enabled:",
			screenGui and screenGui.Enabled
		)
	end

	local function onClose()
		if screenGui then
			screenGui.Enabled = false
		end
		if InputController then
			InputController:UnblockInput()
			InputController:LockMouse()
		end
		print("[ItemSelectionScreen] Closed")
	end

	local function fireSelection(index)
		local key = Fusion.peek(keys[index])
		print("[ItemSelectionScreen] Card", index, "selected, key:", tostring(key))
		if key and key ~= "" then
			local remote = Remotes:GetEvent("SelectChestItem")
			if remote then
				remote:FireServer(key)
				print("[ItemSelectionScreen] Fired SelectChestItem:", key)
			else
				warn("[ItemSelectionScreen] SelectChestItem remote not found")
			end
		end
		onClose()
	end

	local function makeCard(index)
		local itemKey = keys[index]
		local itemData = Computed(scope, function(use)
			return ItemRegistry.GetItem(use(itemKey))
		end)
		local rarityColor = Computed(scope, function(use)
			local d = use(itemData)
			if not d then
				return Color3.new(1, 1, 1)
			end
			return ItemRegistry.Rarities[d.Rarity] or Color3.new(1, 1, 1)
		end)

		local button = scope:New("TextButton")({
			Size = UDim2.new(0, 250, 0, 350),
			BackgroundColor3 = Color3.fromRGB(20, 20, 20),
			BackgroundTransparency = 0.1,
			Text = "",
			ZIndex = 10,
			[Children] = {
				scope:New("UICorner")({ CornerRadius = UDim.new(0, 12) }),
				scope:New("UIStroke")({ Color = rarityColor, Thickness = 4 }),

				scope:New("Frame")({
					Size = UDim2.new(1, 0, 0, 60),
					BackgroundColor3 = rarityColor,
					BackgroundTransparency = 0.5,
					ZIndex = 10,
					[Children] = {
						scope:New("UICorner")({ CornerRadius = UDim.new(0, 12) }),
						scope:New("TextLabel")({
							Size = UDim2.new(1, 0, 1, 0),
							BackgroundTransparency = 1,
							ZIndex = 10,
							Text = Computed(scope, function(use)
								local d = use(itemData)
								return d and d.Name or ""
							end),
							TextColor3 = Color3.new(1, 1, 1),
							Font = Enum.Font.GothamBlack,
							TextSize = 24,
						}),
					},
				}),

				scope:New("TextLabel")({
					Size = UDim2.new(1, -40, 1, -100),
					Position = UDim2.new(0, 20, 0, 80),
					BackgroundTransparency = 1,
					ZIndex = 10,
					Text = Computed(scope, function(use)
						local d = use(itemData)
						return d and d.Description or ""
					end),
					TextColor3 = Color3.fromRGB(220, 220, 220),
					Font = Enum.Font.GothamMedium,
					TextSize = 16,
					TextWrapped = true,
					TextYAlignment = Enum.TextYAlignment.Top,
				}),
			},
		})

		-- Use both Activated and MouseButton1Click as fallbacks
		button.Activated:Connect(function()
			print("[ItemSelectionScreen] Activated fired on card", index)
			fireSelection(index)
		end)
		button.MouseButton1Click:Connect(function()
			print("[ItemSelectionScreen] MouseButton1Click fired on card", index)
			fireSelection(index)
		end)

		return button
	end

	-- ScreenGui: Enabled is toggled imperatively in onOpen/onClose
	screenGui = scope:New("ScreenGui")({
		Name = "ItemSelectionGui",
		Parent = playerGui,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		Enabled = false,
		[Children] = {
			-- Darkened background — non-interactive (Frame, Active=false by default)
			scope:New("Frame")({
				Size = UDim2.new(1, 0, 1, 0),
				BackgroundColor3 = Color3.new(0, 0, 0),
				BackgroundTransparency = 0.4,
				ZIndex = 1,
				Active = false,
			}),
			-- Cards container
			scope:New("Frame")({
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(0, 900, 0, 400),
				BackgroundTransparency = 1,
				ZIndex = 5,
				[Children] = {
					scope:New("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, 40),
					}),
					makeCard(1),
					makeCard(2),
					makeCard(3),
				},
			}),
		},
	})

	print("[ItemSelectionScreen] ScreenGui created:", screenGui and screenGui.ClassName or "nil")

	task.spawn(function()
		local folder = Remotes:GetFolder()
		local promptRemote = folder:WaitForChild("PromptItemSelection")

		promptRemote.OnClientEvent:Connect(function(_, key1, key2, key3)
			print("[ItemSelectionScreen] Received PromptItemSelection:", key1, key2, key3)
			keys[1]:set(key1)
			keys[2]:set(key2)
			keys[3]:set(key3)
			onOpen()
		end)
	end)

	return function()
		Fusion.doCleanup(scope)
	end
end

return ItemSelectionScreen
