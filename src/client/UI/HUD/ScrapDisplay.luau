--[[
    ScrapDisplay.luau
    Shows the player's Scrap balance.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed

local ScrapDisplay = {}

function ScrapDisplay.new()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer

	local scrap = scope:Value(0)

	local function updateScrap()
		scrap:set(LocalPlayer:GetAttribute("Scrap") or 0)
	end

	scope:Hydrate(LocalPlayer)({
		[Fusion.OnEvent("AttributeChanged")] = function(attr)
			if attr == "Scrap" then
				updateScrap()
			end
		end,
	})
	updateScrap()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	scope:New("ScreenGui")({
		Name = "ScrapHUD",
		Parent = playerGui,
		ResetOnSpawn = false,
		DisplayOrder = 10,
		[Children] = {
			scope:New("Frame")({
				Name = "ScrapContainer",
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -20, 1, -20),
				Size = UDim2.new(0, 150, 0, 40),
				BackgroundColor3 = Color3.fromRGB(30, 30, 30),
				BackgroundTransparency = 0.5,
				[Children] = {
					scope:New("UICorner")({ CornerRadius = UDim.new(0, 6) }),
					scope:New("UIStroke")({ Color = Color3.new(0, 0, 0), Thickness = 2 }),
					scope:New("TextLabel")({
						Size = UDim2.new(1, -10, 1, 0),
						Position = UDim2.new(0, -5, 0, 0),
						BackgroundTransparency = 1,
						Text = Computed(scope, function(use)
							return "Scrap: " .. use(scrap)
						end),
						TextColor3 = Color3.fromRGB(240, 200, 30), -- Goldish
						Font = Enum.Font.GothamBold,
						TextSize = 20,
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			}),
		},
	})

	return function()
		Fusion.doCleanup(scope)
	end
end

return ScrapDisplay
