--[[
    InteractionPrompt.luau
    Clean, modern interaction prompt that appears near interactables.
    Matches the game's aesthetic and supports mobile/PC.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>

local InteractionPrompt = {}

--[[
    Create the Interaction Prompt HUD
]]
function InteractionPrompt.new(): () -> ()
	local scope = scoped(Fusion)

	-- State
	local currentPrompt = scope:Value(nil :: ProximityPrompt?)
	local isVisible = scope:Value(false)
	local actionText = scope:Value("")
	local objectText = scope:Value("")

	-- Connections
	ProximityPromptService.PromptShown:Connect(function(prompt)
		currentPrompt:set(prompt)
		actionText:set(prompt.ActionText)
		objectText:set(prompt.ObjectText)
		isVisible:set(true)
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if currentPrompt:get() == prompt then
			isVisible:set(false)
			currentPrompt:set(nil)
		end
	end)

	-- UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "InteractionGui",
		Parent = playerGui,
		Enabled = isVisible,

		[Children] = {
			-- Centered Prompt
			scope:New("Frame")({
				Name = "PromptFrame",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, 0, 0.65, 0), -- Slightly below center
				Size = UDim2.new(0, 250, 0, 60),
				BackgroundColor3 = Color3.fromRGB(30, 30, 35),
				BackgroundTransparency = 0.2,

				[Children] = {
					scope:New("UICorner")({ CornerRadius = UDim.new(0, 12) }),
					scope:New("UIStroke")({ Color = Color3.new(1, 1, 1), Thickness = 2, Transparency = 0.8 }),

					-- Key Icon (PC)
					scope:New("Frame")({
						Name = "KeyIcon",
						Position = UDim2.new(0, 15, 0.5, 0),
						AnchorPoint = Vector2.new(0, 0.5),
						Size = UDim2.new(0, 35, 0, 35),
						BackgroundColor3 = Color3.new(1, 1, 1),

						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, 6) }),
							scope:New("TextLabel")({
								Size = UDim2.fromScale(1, 1),
								BackgroundTransparency = 1,
								Text = "E",
								TextColor3 = Color3.new(0, 0, 0),
								Font = Enum.Font.GothamBlack,
								TextSize = 20,
							}),
						},
					}),

					-- Action Text
					scope:New("TextLabel")({
						Position = UDim2.new(0, 65, 0, 10),
						Size = UDim2.new(1, -75, 0, 20),
						BackgroundTransparency = 1,
						Text = actionText,
						TextColor3 = Color3.new(1, 1, 1),
						Font = Enum.Font.GothamBold,
						TextSize = 18,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),

					-- Object Text
					scope:New("TextLabel")({
						Position = UDim2.new(0, 65, 0, 30),
						Size = UDim2.new(1, -75, 0, 20),
						BackgroundTransparency = 1,
						Text = objectText,
						TextColor3 = Color3.fromRGB(180, 180, 180),
						Font = Enum.Font.Gotham,
						TextSize = 14,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),

					-- Mobile Click Area (makes the whole prompt clickable)
					scope:New("TextButton")({
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Text = "",
						[OnEvent("Activated")] = function()
							local prompt = currentPrompt:get()
							if prompt then
								prompt:InputHoldBegin()
								task.wait(prompt.HoldDuration + 0.1)
								prompt:InputHoldEnd()
							end
						end,
					}),
				},
			}),
		},
	})

	-- Hide Roblox's default UI
	ProximityPromptService.Enabled = true

	-- Custom Prompt Override
	local function onPromptAdded(prompt: ProximityPrompt)
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end

	for _, prompt in pairs(game:GetService("CollectionService"):GetTagged("LootChest")) do
		-- Handle already existing if needed
	end

	-- Connect to future prompts
	local conn = game:GetService("RunService").Heartbeat:Connect(function()
		for _, prompt in pairs(game:GetDescendants()) do
			if prompt:IsA("ProximityPrompt") and prompt.Style ~= Enum.ProximityPromptStyle.Custom then
				prompt.Style = Enum.ProximityPromptStyle.Custom
			end
		end
	end)

	return function()
		conn:Disconnect()
		Fusion.doCleanup(scope)
	end
end

return InteractionPrompt
