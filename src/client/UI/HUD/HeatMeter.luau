--[[
    HeatMeter.luau
    Displays current Kinetic Scrubber heat as a bar below the stamina bar.
    Only visible for the Scrapper class.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- Fusion API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local peek = Fusion.peek

-- Configuration
local BAR_WIDTH = 200
local BAR_HEIGHT = 8
local BAR_PADDING = 10
local CORNER_RADIUS = 4

local HeatMeter = {}

function HeatMeter.new(): () -> ()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer

	-- State
	local currentHeat = scope:Value(0)
	local maxHeat = 100
	local isScrapper = scope:Value(false)

	-- Update State on Attribute changes
	local function updateState()
		local class = LocalPlayer:GetAttribute("Class")
		isScrapper:set(class == "Scrapper")

		local heat = LocalPlayer:GetAttribute("HeatCharge") or 0
		currentHeat:set(heat)
	end

	-- Initial sync
	updateState()

	-- Listen to changes
	local conn1 = LocalPlayer:GetAttributeChangedSignal("Class"):Connect(updateState)
	local conn2 = LocalPlayer:GetAttributeChangedSignal("HeatCharge"):Connect(updateState)
	table.insert(scope, conn1)
	table.insert(scope, conn2)

	-- Computed Visuals
	local heatPercent = Computed(scope, function(use)
		return math.clamp(use(currentHeat) / maxHeat, 0, 1)
	end)

	local barFillWidth = Computed(scope, function(use)
		return UDim2.new(use(heatPercent), 0, 1, 0)
	end)

	local isMaxHeat = Computed(scope, function(use)
		return use(heatPercent) >= 1
	end)

	-- Bar fill color (pulsates red at max heat)
	local barColor = Computed(scope, function(use)
		if use(isMaxHeat) then
			-- Flash rapid red/orange when fully charged
			local time = tick() * 10
			local flash = math.abs(math.sin(time))
			return Color3.fromRGB(255, 50 + (100 * flash), 50)
		end
		-- Transition from yellow to orange based on heat
		local percent = use(heatPercent)
		return Color3.fromRGB(255, 200 - (100 * percent), 50)
	end)

	-- Create UI
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "HeatMeterGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
		Enabled = isScrapper, -- Only show if Scrapper

		[Children] = {
			-- Container (centered at top, below Stamina)
			scope:New("Frame")({
				Name = "HeatContainer",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 75), -- Below Stamina bar area
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
							scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
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
									scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
									-- Shine
									scope:New("Frame")({
										AnchorPoint = Vector2.new(0, 0),
										Position = UDim2.new(0, 0, 0, 0),
										Size = UDim2.new(1, 0, 0.4, 0),
										BackgroundColor3 = Color3.fromRGB(255, 255, 255),
										BackgroundTransparency = 0.8,
										BorderSizePixel = 0,
										[Children] = {
											scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
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
						Text = "HEAT",
						TextColor3 = Color3.fromRGB(255, 150, 100),
						TextSize = 10,
						Font = Enum.Font.GothamBold,
						TextTransparency = 0.3,
					}),

					-- Max Indicator
					scope:New("TextLabel")({
						Name = "MaxIndicator",
						AnchorPoint = Vector2.new(1, 1),
						Position = UDim2.new(1, 0, 0, -2),
						Size = UDim2.new(0, BAR_WIDTH / 2, 0, 12),
						BackgroundTransparency = 1,
						Text = "KINETIC SHRED ACTIVE",
						TextColor3 = Color3.fromRGB(255, 50, 50),
						TextSize = 10,
						Font = Enum.Font.GothamBold,
						TextTransparency = 0,
						Visible = isMaxHeat,
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			}),
		},
	})

	-- Timer for pulsating colors
	local hb = RunService.Heartbeat:Connect(function()
		-- We just need a dummy trigger to recompute barColor if we want it to animate
		if peek(isMaxHeat) then
			currentHeat:set(peek(currentHeat)) -- This is slightly hacky but forces recompute of dependencies
		end
	end)
	table.insert(scope, hb)

	return function()
		Fusion.doCleanup(scope)
	end
end

return HeatMeter
