--[[
    PlayerHealthBar.luau
    Custom health bar with Shield support (Blue overlay).
    Uses Fusion 0.3.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- Fusion API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local Value = Fusion.Value

-- Config
local BAR_WIDTH = 300
local BAR_HEIGHT = 20
local CORNER_RADIUS = 6

local PlayerHealthBar = {}

function PlayerHealthBar.new(): () -> ()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer
	
	-- State
	local health = scope:Value(100)
	local maxHealth = scope:Value(100)
	local shield = scope:Value(0)
	
	-- Update function
	local function updateState()
		local char = LocalPlayer.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				health:set(hum.Health)
				maxHealth:set(hum.MaxHealth)
			end
			shield:set(char:GetAttribute("Shield") or 0)
		end
	end
	
	-- Connect to character changes
	local function onCharacterAdded(char)
		local hum = char:WaitForChild("Humanoid", 10)
		if hum then
			scope:Hydrate(hum)({
				[Fusion.OnEvent("HealthChanged")] = function()
					health:set(hum.Health)
				end,
				[Fusion.OnEvent("Changed")] = function(prop)
					if prop == "MaxHealth" then
						maxHealth:set(hum.MaxHealth)
					end
				end
			})
			updateState()
		end
		
		scope:Hydrate(char)({
			[Fusion.OnEvent("AttributeChanged")] = function(attr)
				if attr == "Shield" then
					shield:set(char:GetAttribute("Shield") or 0)
				end
			end
		})
	end
	
	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end
	table.insert(scope, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))
	
	-- Computed sizes
	local healthPercent = Computed(scope, function(use)
		local max = use(maxHealth)
		if max <= 0 then return 0 end
		return math.clamp(use(health) / max, 0, 1)
	end)
	
	local shieldPercent = Computed(scope, function(use)
		local max = use(maxHealth) -- Shield scales relative to max HP visually
		if max <= 0 then return 0 end
		return math.clamp(use(shield) / max, 0, 1) -- Cap at 100% width for visual sanity
	end)
	
	-- Create UI
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	
	local screenGui = scope:New("ScreenGui")({
		Name = "PlayerHealthHUD",
		Parent = playerGui,
		ResetOnSpawn = false,
		DisplayOrder = 10,
		
		[Children] = {
			-- Main Bar Container (Bottom Center, above Stamina)
			scope:New("Frame")({
				Name = "HealthContainer",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -80), -- Positioned above stamina bar area
				Size = UDim2.new(0, BAR_WIDTH, 0, BAR_HEIGHT),
				BackgroundColor3 = Color3.fromRGB(20, 20, 20),
				BackgroundTransparency = 0.5,
				
				[Children] = {
					scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
					scope:New("UIStroke")({ Color = Color3.new(0,0,0), Thickness = 2 }),
					
					-- Health Fill (Green/Red)
					scope:New("Frame")({
						Name = "HealthFill",
						Size = Computed(scope, function(use)
							return UDim2.new(use(healthPercent), 0, 1, 0)
						end),
						BackgroundColor3 = Color3.fromRGB(46, 204, 113), -- Emerald Green
						BorderSizePixel = 0,
						
						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) })
						}
					}),
					
					-- Shield Fill (Blue Overlay)
					scope:New("Frame")({
						Name = "ShieldFill",
						ZIndex = 2, -- Draw on top of health
						Size = Computed(scope, function(use)
							return UDim2.new(use(shieldPercent), 0, 1, 0)
						end),
						BackgroundColor3 = Color3.fromRGB(52, 152, 219), -- Blue
						BackgroundTransparency = 0.3, -- See-through to show it's a layer
						BorderSizePixel = 0,
						
						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
							scope:New("UIStroke")({
								Color = Color3.fromRGB(41, 128, 185),
								Thickness = 1,
							})
						}
					}),
					
					-- Text Label
					scope:New("TextLabel")({
						Name = "HealthText",
						Size = UDim2.new(1, 0, 1, 0),
						BackgroundTransparency = 1,
						ZIndex = 5,
						Text = Computed(scope, function(use)
							local h = math.floor(use(health))
							local m = math.floor(use(maxHealth))
							local s = math.floor(use(shield))
							if s > 0 then
								return string.format("%d / %d (+%d)", h, m, s)
							end
							return string.format("%d / %d", h, m)
						end),
						TextColor3 = Color3.new(1, 1, 1),
						Font = Enum.Font.GothamBold,
						TextSize = 14,
						TextStrokeTransparency = 0.5,
					})
				}
			})
		}
	})
	
	-- Return cleanup
	return function()
		Fusion.doCleanup(scope)
	end
end

return PlayerHealthBar
