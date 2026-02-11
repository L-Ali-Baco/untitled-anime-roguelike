--[[
    ClassSelectScreen.luau
    Full-screen class selection UI shown on spawn/respawn.
    Uses Fusion 0.3 for reactive UI.
    
    Features:
    - Two class buttons (Warrior / Gunner)
    - Class info display (name, description, icon)
    - Mobile-friendly large touch targets
    - Blocks gameplay input until a class is selected
    - Unlocks mouse for UI interaction
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ClassConfig = require(ReplicatedStorage.Shared.Config.ClassConfig)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>

-- Configuration
local CARD_WIDTH = 280
local CARD_HEIGHT = 360
local CARD_SPACING = 40
local BUTTON_HEIGHT = 50

-- Reference to InputController (set in new())
local InputController = nil

local ClassSelectScreen = {}

--[[
    Create a class card component
]]
local function createClassCard(
	scope: Scope,
	className: string,
	classData: any,
	isHovered: Fusion.Value<boolean>,
	onSelect: () -> ()
): Instance
	-- Card background color (brightens on hover)
	local cardColor = Computed(scope, function(use)
		local baseColor = classData.Color
		if use(isHovered) then
			-- Brighten on hover
			return Color3.new(
				math.min(1, baseColor.R + 0.15),
				math.min(1, baseColor.G + 0.15),
				math.min(1, baseColor.B + 0.15)
			)
		end
		return baseColor
	end)

	local cardScale = Computed(scope, function(use)
		return use(isHovered) and 1.05 or 1.0
	end)

	return scope:New("Frame")({
		Name = className .. "Card",
		Size = UDim2.new(0, CARD_WIDTH, 0, CARD_HEIGHT),
		BackgroundColor3 = Color3.fromRGB(30, 30, 35),
		BackgroundTransparency = 0.1,

		[Children] = {
			-- Corner radius
			scope:New("UICorner")({
				CornerRadius = UDim.new(0, 16),
			}),

			-- Border stroke (colored by class)
			scope:New("UIStroke")({
				Color = cardColor,
				Thickness = 3,
				Transparency = 0.2,
			}),

			-- Scale for hover effect
			scope:New("UIScale")({
				Scale = cardScale,
			}),

			-- Content layout
			scope:New("Frame")({
				Name = "Content",
				Size = UDim2.new(1, -32, 1, -32),
				Position = UDim2.new(0, 16, 0, 16),
				BackgroundTransparency = 1,

				[Children] = {
					-- Layout
					scope:New("UIListLayout")({
						SortOrder = Enum.SortOrder.LayoutOrder,
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Top,
						Padding = UDim.new(0, 12),
					}),

					-- Class icon
					scope:New("ImageLabel")({
						Name = "Icon",
						LayoutOrder = 1,
						Size = UDim2.new(0, 80, 0, 80),
						BackgroundColor3 = classData.Color,
						BackgroundTransparency = 0.7,
						Image = classData.Icon or "",
						ImageColor3 = Color3.new(1, 1, 1),
						ScaleType = Enum.ScaleType.Fit,

						[Children] = {
							scope:New("UICorner")({
								CornerRadius = UDim.new(0.5, 0),
							}),
						},
					}),

					-- Class name
					scope:New("TextLabel")({
						Name = "ClassName",
						LayoutOrder = 2,
						Size = UDim2.new(1, 0, 0, 36),
						BackgroundTransparency = 1,
						Text = classData.DisplayName or className,
						TextColor3 = classData.Color,
						TextSize = 32,
						Font = Enum.Font.GothamBlack,
						TextXAlignment = Enum.TextXAlignment.Center,
					}),

					-- Attack type badge
					scope:New("Frame")({
						Name = "TypeBadge",
						LayoutOrder = 3,
						Size = UDim2.new(0, 100, 0, 24),
						BackgroundColor3 = classData.AttackType == "Melee" and Color3.fromRGB(255, 100, 100)
							or Color3.fromRGB(100, 180, 255),
						BackgroundTransparency = 0.3,

						[Children] = {
							scope:New("UICorner")({
								CornerRadius = UDim.new(0, 12),
							}),

							scope:New("TextLabel")({
								Size = UDim2.new(1, 0, 1, 0),
								BackgroundTransparency = 1,
								Text = classData.AttackType:upper(),
								TextColor3 = Color3.new(1, 1, 1),
								TextSize = 14,
								Font = Enum.Font.GothamBold,
							}),
						},
					}),

					-- Description
					scope:New("TextLabel")({
						Name = "Description",
						LayoutOrder = 4,
						Size = UDim2.new(1, 0, 0, 48),
						BackgroundTransparency = 1,
						Text = classData.Description or "",
						TextColor3 = Color3.fromRGB(180, 180, 180),
						TextSize = 14,
						Font = Enum.Font.Gotham,
						TextWrapped = true,
						TextXAlignment = Enum.TextXAlignment.Center,
						TextYAlignment = Enum.TextYAlignment.Top,
					}),

					-- Stats info
					scope:New("Frame")({
						Name = "Stats",
						LayoutOrder = 5,
						Size = UDim2.new(1, 0, 0, 40),
						BackgroundTransparency = 1,

						[Children] = {
							scope:New("UIListLayout")({
								SortOrder = Enum.SortOrder.LayoutOrder,
								FillDirection = Enum.FillDirection.Vertical,
								HorizontalAlignment = Enum.HorizontalAlignment.Center,
								Padding = UDim.new(0, 4),
							}),

							scope:New("TextLabel")({
								Name = "Health",
								LayoutOrder = 1,
								Size = UDim2.new(1, 0, 0, 16),
								BackgroundTransparency = 1,
								Text = "HP: " .. tostring(classData.BaseHealth),
								TextColor3 = Color3.fromRGB(100, 255, 100),
								TextSize = 14,
								Font = Enum.Font.GothamMedium,
							}),

							scope:New("TextLabel")({
								Name = "Speed",
								LayoutOrder = 2,
								Size = UDim2.new(1, 0, 0, 16),
								BackgroundTransparency = 1,
								Text = "Speed: " .. string.format("%.0f%%", (classData.MoveSpeedMultiplier or 1) * 100),
								TextColor3 = Color3.fromRGB(100, 200, 255),
								TextSize = 14,
								Font = Enum.Font.GothamMedium,
							}),
						},
					}),

					-- Select button
					scope:New("TextButton")({
						Name = "SelectButton",
						LayoutOrder = 6,
						Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
						BackgroundColor3 = classData.Color,
						BackgroundTransparency = 0.1,
						Text = "SELECT",
						TextColor3 = Color3.new(1, 1, 1),
						TextSize = 20,
						Font = Enum.Font.GothamBlack,
						AutoButtonColor = true,

						[OnEvent("Activated")] = onSelect,

						[OnEvent("MouseEnter")] = function()
							isHovered:set(true)
						end,

						[OnEvent("MouseLeave")] = function()
							isHovered:set(false)
						end,

						[Children] = {
							scope:New("UICorner")({
								CornerRadius = UDim.new(0, 12),
							}),
						},
					}),
				},
			}),
		},
	})
end

--[[
    Create the ClassSelectScreen
    Returns: { show: () -> (), hide: () -> (), destroy: () -> () }
]]
function ClassSelectScreen.new(
	classController: any,
	inputController: any
): { show: () -> (), hide: () -> (), destroy: () -> () }
	-- Store InputController reference
	InputController = inputController

	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- State
	local isVisible = scope:Value(false)

	-- Hover states for each class
	local hoverStates: { [string]: Fusion.Value<boolean> } = {}
	for _, className in ClassConfig.ClassOrder do
		hoverStates[className] = scope:Value(false)
	end

	-- Internal function to handle visibility changes
	local function setVisible(visible: boolean)
		isVisible:set(visible)

		if InputController then
			if visible then
				-- Unlock mouse for UI interaction (but don't block input - UI overlay handles that)
				InputController:UnlockMouse()
				print("[ClassSelectScreen] Mouse unlocked for UI")
			else
				-- Lock mouse for gameplay
				InputController:LockMouse()
				print("[ClassSelectScreen] Mouse locked for gameplay")
			end
		else
			warn("[ClassSelectScreen] InputController is nil!")
		end
	end

	-- Callbacks
	local function onClassSelected(className: string)
		if classController then
			classController:SelectClass(className)
		end
		setVisible(false)
		print("[ClassSelectScreen] Selected:", className)
	end

	-- Visibility computed
	local screenVisibility = Computed(scope, function(use)
		return use(isVisible) and 1 or 0
	end)

	local contentPosition = Computed(scope, function(use)
		return use(isVisible) and UDim2.new(0.5, 0, 0.5, 0) or UDim2.new(0.5, 0, 1.5, 0) -- Off-screen when hidden
	end)

	-- Create class cards
	local classCards = {}
	for i, className in ClassConfig.ClassOrder do
		local classData = ClassConfig[className]
		if classData then
			local card = createClassCard(scope, className, classData, hoverStates[className], function()
				onClassSelected(className)
			end)
			card.LayoutOrder = i
			table.insert(classCards, card)
		end
	end

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "ClassSelectGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 100, -- Above other UI
		Enabled = true,

		[Children] = {
			-- Darkened background
			scope:New("Frame")({
				Name = "Background",
				Size = UDim2.new(1, 0, 1, 0),
				BackgroundColor3 = Color3.fromRGB(0, 0, 0),
				BackgroundTransparency = Computed(scope, function(use)
					return use(isVisible) and 0.6 or 1
				end),

				[Children] = {
					-- Block input when visible
					scope:New("TextButton")({
						Name = "InputBlocker",
						Size = UDim2.new(1, 0, 1, 0),
						BackgroundTransparency = 1,
						Text = "",
						Active = isVisible,
					}),
				},
			}),

			-- Main container (centered)
			scope:New("Frame")({
				Name = "Container",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = contentPosition,
				Size = UDim2.new(
					0,
					(CARD_WIDTH * #classCards) + (CARD_SPACING * (#classCards - 1)) + 100,
					0,
					CARD_HEIGHT + 150
				),
				BackgroundTransparency = 1,

				[Children] = {
					-- Title
					scope:New("TextLabel")({
						Name = "Title",
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 0),
						Size = UDim2.new(1, 0, 0, 60),
						BackgroundTransparency = 1,
						Text = "CHOOSE YOUR CLASS",
						TextColor3 = Color3.new(1, 1, 1),
						TextSize = 42,
						Font = Enum.Font.GothamBlack,
						TextStrokeTransparency = 0.5,
						TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
					}),

					-- Subtitle
					scope:New("TextLabel")({
						Name = "Subtitle",
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 55),
						Size = UDim2.new(1, 0, 0, 24),
						BackgroundTransparency = 1,
						Text = "Select a class to begin your adventure",
						TextColor3 = Color3.fromRGB(180, 180, 180),
						TextSize = 18,
						Font = Enum.Font.Gotham,
					}),

					-- Cards container
					scope:New("Frame")({
						Name = "CardsContainer",
						AnchorPoint = Vector2.new(0.5, 0),
						Position = UDim2.new(0.5, 0, 0, 100),
						Size = UDim2.new(
							0,
							(CARD_WIDTH * #classCards) + (CARD_SPACING * (#classCards - 1)),
							0,
							CARD_HEIGHT
						),
						BackgroundTransparency = 1,

						[Children] = {
							scope:New("UIListLayout")({
								SortOrder = Enum.SortOrder.LayoutOrder,
								FillDirection = Enum.FillDirection.Horizontal,
								HorizontalAlignment = Enum.HorizontalAlignment.Center,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, CARD_SPACING),
							}),

							-- Add class cards
							table.unpack(classCards),
						},
					}),
				},
			}),
		},
	})

	-- Public API
	local api = {
		show = function()
			setVisible(true)
			print("[ClassSelectScreen] Showing class selection")
		end,

		hide = function()
			setVisible(false)
			print("[ClassSelectScreen] Hiding class selection")
		end,

		isVisible = function()
			return Fusion.peek(isVisible)
		end,

		destroy = function()
			Fusion.doCleanup(scope)
		end,
	}

	return api
end

return ClassSelectScreen
