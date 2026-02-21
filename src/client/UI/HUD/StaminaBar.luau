--[[
    StaminaBar.luau
    Displays current stamina as a bar below the health bar.
    Uses Fusion 0.3 for reactive UI updates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local StaminaConfig = require(ReplicatedStorage.Shared.Config.StaminaConfig)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>

-- Configuration
local BAR_WIDTH = 200
local BAR_HEIGHT = 8
local BAR_PADDING = 10
local CORNER_RADIUS = 4

local StaminaBar = {}

--[[
    Create the StaminaBar component
    Returns: cleanup function
]]
function StaminaBar.new(staminaController: any): () -> ()
	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- State
	local staminaPercent = scope:Value(1)
	local isLowStamina = scope:Value(false)
	local isFlashActive = scope:Value(false)

	-- Listen to stamina changes
	local connection = staminaController.OnStaminaChanged:Connect(function(current, max, percent)
		staminaPercent:set(percent)
		isLowStamina:set(percent <= StaminaConfig.LowStaminaThreshold)
	end)

	-- Listen to stamina failure (feedback)
	local failureConnection = staminaController.OnStaminaFailure:Connect(function()
		-- Play sound
		local sound = Instance.new("Sound")
		sound.Name = "NoStaminaSound"
		sound.SoundId = StaminaConfig.Feedback.NoStaminaSoundId
		sound.Volume = 0.5
		sound.Parent = SoundService
		sound:Play()
		Debris:AddItem(sound, 1)

		-- Trigger flash
		isFlashActive:set(true)
		task.delay(StaminaConfig.Feedback.FlashDuration, function()
			isFlashActive:set(false)
		end)
	end)

	-- Bar fill color (changes when low or failed)
	local barColor = Computed(scope, function(use)
		if use(isFlashActive) then
			return StaminaConfig.Feedback.FailureFlashColor
		end
		if use(isLowStamina) then
			return Color3.fromRGB(255, 150, 50) -- Orange when low
		end
		return Color3.fromRGB(80, 200, 255) -- Cyan normally
	end)

	-- Bar width based on stamina
	local barFillWidth = Computed(scope, function(use)
		return UDim2.new(use(staminaPercent), 0, 1, 0)
	end)

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "StaminaBarGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = false,
		DisplayOrder = 5,

		[Children] = {
			-- Container (centered at top)
			scope:New("Frame")({
				Name = "StaminaContainer",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 50), -- Below health bar area
				Size = UDim2.new(0, BAR_WIDTH, 0, BAR_HEIGHT + BAR_PADDING),
				BackgroundTransparency = 1,

				[Children] = {
					-- Background bar
					scope:New("Frame")({
						Name = "Background",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0.5, 0, 0.5, 0),
						Size = UDim2.new(0, BAR_WIDTH, 0, BAR_HEIGHT),
						BackgroundColor3 = Color3.fromRGB(30, 30, 30),
						BackgroundTransparency = 0.3,

						[Children] = {
							-- Corner radius
							scope:New("UICorner")({
								CornerRadius = UDim.new(0, CORNER_RADIUS),
							}),

							-- Border
							scope:New("UIStroke")({
								Color = Color3.fromRGB(60, 60, 60),
								Thickness = 1,
								Transparency = 0.5,
							}),

							-- Fill bar
							scope:New("Frame")({
								Name = "Fill",
								AnchorPoint = Vector2.new(0, 0.5),
								Position = UDim2.new(0, 0, 0.5, 0),
								Size = barFillWidth,
								BackgroundColor3 = barColor,
								BackgroundTransparency = 0.1,
								ClipsDescendants = true,

								[Children] = {
									scope:New("UICorner")({
										CornerRadius = UDim.new(0, CORNER_RADIUS),
									}),

									-- Shine effect
									scope:New("Frame")({
										Name = "Shine",
										AnchorPoint = Vector2.new(0, 0),
										Position = UDim2.new(0, 0, 0, 0),
										Size = UDim2.new(1, 0, 0.4, 0),
										BackgroundColor3 = Color3.fromRGB(255, 255, 255),
										BackgroundTransparency = 0.8,
										BorderSizePixel = 0,

										[Children] = {
											scope:New("UICorner")({
												CornerRadius = UDim.new(0, CORNER_RADIUS),
											}),
										},
									}),
								},
							}),
						},
					}),

					-- Label
					scope:New("TextLabel")({
						Name = "Label",
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.new(0.5, 0, 0, -2),
						Size = UDim2.new(0, BAR_WIDTH, 0, 12),
						BackgroundTransparency = 1,
						Text = "STAMINA",
						TextColor3 = Color3.fromRGB(200, 200, 200),
						TextSize = 10,
						Font = Enum.Font.GothamBold,
						TextTransparency = 0.3,
					}),
				},
			}),
		},
	})

	-- Return cleanup function
	return function()
		connection:Disconnect()
		failureConnection:Disconnect()
		Fusion.doCleanup(scope)
	end
end

return StaminaBar
