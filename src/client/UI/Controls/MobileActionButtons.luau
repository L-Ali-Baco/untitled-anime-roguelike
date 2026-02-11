--[[
    MobileActionButtons.luau
    Mobile action buttons (Attack, Dash, Jump) using Fusion 0.3.
    Positioned on the right side of the screen for thumb access.
    Only visible on mobile devices.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed
local peek = Fusion.peek

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>

-- Configuration
local BUTTON_SIZE = 70 -- pixels
local BUTTON_PADDING = 15 -- between buttons
local EDGE_PADDING = 25 -- from screen edge
local ATTACK_SIZE = 90 -- Attack button is larger

-- Button configs
local BUTTONS = {
	{
		name = "Attack",
		icon = "rbxassetid://6031097903", -- Sword icon
		color = Color3.fromRGB(255, 80, 80), -- Red
		size = ATTACK_SIZE,
		position = "bottom", -- Main attack button
	},
	{
		name = "Dash",
		icon = "rbxassetid://6034287594", -- Running icon
		color = Color3.fromRGB(80, 180, 255), -- Cyan
		size = BUTTON_SIZE,
		position = "left", -- Left of attack
	},
	{
		name = "Jump",
		icon = "rbxassetid://6034509993", -- Arrow up icon
		color = Color3.fromRGB(80, 255, 120), -- Green
		size = BUTTON_SIZE,
		position = "top", -- Above attack
	},
}

local MobileActionButtons = {}

--[[
    Create a single action button
]]
local function createButton(
	scope: Scope,
	config: { name: string, icon: string, color: Color3, size: number },
	position: UDim2,
	onPressed: () -> (),
	onReleased: (() -> ())?
)
	local isPressed = scope:Value(false)

	-- Darken color when pressed
	local backgroundColor = Computed(scope, function(use)
		if use(isPressed) then
			local c = config.color
			return Color3.fromRGB(c.R * 255 * 0.6, c.G * 255 * 0.6, c.B * 255 * 0.6)
		end
		return config.color
	end)

	-- Scale when pressed
	local buttonScale = Computed(scope, function(use)
		return use(isPressed) and 0.9 or 1
	end)

	return scope:New("Frame")({
		Name = config.name .. "Button",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.new(0, config.size, 0, config.size),
		BackgroundTransparency = 1,

		[Children] = {
			-- Scale container
			scope:New("Frame")({
				Name = "ScaleContainer",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = Computed(scope, function(use)
					local scale = use(buttonScale)
					return UDim2.new(scale, 0, scale, 0)
				end),
				BackgroundTransparency = 1,

				[Children] = {
					-- Button background
					scope:New("Frame")({
						Name = "Background",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0.5, 0, 0.5, 0),
						Size = UDim2.new(0, config.size, 0, config.size),
						BackgroundColor3 = backgroundColor,
						BackgroundTransparency = 0.3,

						[Children] = {
							-- Corner radius
							scope:New("UICorner")({
								CornerRadius = UDim.new(0.5, 0),
							}),

							-- Stroke
							scope:New("UIStroke")({
								Color = Color3.fromRGB(255, 255, 255),
								Thickness = 2,
								Transparency = 0.5,
							}),

							-- Icon
							scope:New("ImageLabel")({
								Name = "Icon",
								AnchorPoint = Vector2.new(0.5, 0.5),
								Position = UDim2.new(0.5, 0, 0.5, 0),
								Size = UDim2.new(0.5, 0, 0.5, 0),
								BackgroundTransparency = 1,
								Image = config.icon,
								ImageColor3 = Color3.fromRGB(255, 255, 255),
								ImageTransparency = 0.1,
							}),
						},
					}),
				},
			}),

			-- Touch capture (invisible, full size)
			scope:New("TextButton")({
				Name = "TouchCapture",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				Size = UDim2.new(1.2, 0, 1.2, 0), -- Slightly larger hit area
				BackgroundTransparency = 1,
				Text = "",

				[OnEvent("InputBegan")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.Touch then
						isPressed:set(true)
						onPressed()
					end
				end,

				[OnEvent("InputEnded")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.Touch then
						isPressed:set(false)
						if onReleased then
							onReleased()
						end
					end
				end,
			}),
		},
	})
end

--[[
    Create the MobileActionButtons component
    Returns: cleanup function
]]
function MobileActionButtons.new(inputController: any): () -> ()
	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- Check if mobile
	local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- Don't create UI on non-mobile
	if not isMobile then
		return function()
			Fusion.doCleanup(scope)
		end
	end

	-- Calculate button positions
	-- Layout: Diamond pattern on bottom right
	--         [Jump]
	--   [Dash]      [Attack]
	local attackX = -EDGE_PADDING - ATTACK_SIZE / 2
	local attackY = -EDGE_PADDING - ATTACK_SIZE / 2

	local jumpX = attackX
	local jumpY = attackY - ATTACK_SIZE / 2 - BUTTON_PADDING - BUTTON_SIZE / 2

	local dashX = attackX - ATTACK_SIZE / 2 - BUTTON_PADDING - BUTTON_SIZE / 2
	local dashY = attackY

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "MobileActionButtonsGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 10,

		[Children] = {
			-- Attack button (main, bottom right)
			createButton(
				scope,
				BUTTONS[1], -- Attack config
				UDim2.new(1, attackX, 1, attackY),
				function()
					inputController:FireAttackPressed()
				end,
				function()
					inputController:ReleaseAttack()
				end
			),

			-- Dash button (left of attack)
			createButton(
				scope,
				BUTTONS[2], -- Dash config
				UDim2.new(1, dashX, 1, dashY),
				function()
					inputController:FireDashPressed()
				end
			),

			-- Jump button (above attack)
			createButton(
				scope,
				BUTTONS[3], -- Jump config
				UDim2.new(1, jumpX, 1, jumpY),
				function()
					inputController:FireJumpPressed()
				end
			),
		},
	})

	-- Return cleanup function
	return function()
		Fusion.doCleanup(scope)
	end
end

return MobileActionButtons
