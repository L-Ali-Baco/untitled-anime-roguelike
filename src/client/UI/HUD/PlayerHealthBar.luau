--[[
    PlayerHealthBar.luau
    Custom health bar with Shield support (Blue overlay).
    Uses Fusion 0.3.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

-- Fusion API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local Value = Fusion.Value

local peek = Fusion.peek
	or function(state)
		if typeof(state) == "table" and state.get then
			return state:get(false)
		end
		return state
	end

-- Lerp speed for the health and shield bar fill animation.
-- At 60 fps the remaining gap shrinks by (1 - LERP_SPEED/60)^n each frame.
-- LERP_SPEED = 10 → ~90% of the transition completes in ~0.23 s. Feels smooth and
-- readable without being so slow it looks laggy.
local LERP_SPEED = 10

-- Config
local BAR_WIDTH = 300
local BAR_HEIGHT = 20
local CORNER_RADIUS = 6

local PlayerHealthBar = {}

function PlayerHealthBar.new(): () -> ()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer

	-- Source-of-truth state (set from Humanoid events)
	local health = scope:Value(100)
	local maxHealth = scope:Value(100)
	local shield = scope:Value(0)

	-- Smoothed display state (lerped toward source each Heartbeat)
	-- Initialised to 1 so the bar doesn't animate from 0 on first load.
	local healthSmoothed = scope:Value(1)
	local shieldSmoothed = scope:Value(0)

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
				end,
			})
			updateState()
		end

		scope:Hydrate(char)({
			[Fusion.OnEvent("AttributeChanged")] = function(attr)
				if attr == "Shield" then
					shield:set(char:GetAttribute("Shield") or 0)
				end
			end,
		})
	end

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end
	table.insert(scope, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

	-- Instant snap when character (re)spawns so the bar isn't stuck at 0 on load.
	local function snapSmoothedValues()
		local max = peek(maxHealth)
		if max <= 0 then
			return
		end
		healthSmoothed:set(math.clamp(peek(health) / max, 0, 1))
		shieldSmoothed:set(math.clamp(peek(shield) / max, 0, 1))
	end
	snapSmoothedValues()
	table.insert(
		scope,
		LocalPlayer.CharacterAdded:Connect(function()
			task.wait() -- yield one frame so Humanoid attributes are set
			snapSmoothedValues()
		end)
	)

	-- Heartbeat lerp: smoothed values chase the source values every frame.
	-- This drives the TweenService-equivalent animation without mixing Fusion
	-- reactive bindings with TweenService on the same property (which would conflict).
	table.insert(
		scope,
		RunService.Heartbeat:Connect(function(dt: number)
			local max = peek(maxHealth)
			if max <= 0 then
				return
			end

			-- Target percentages from source state
			local hTarget = math.clamp(peek(health) / max, 0, 1)
			local sTarget = math.clamp(peek(shield) / max, 0, 1)

			-- Exponential lerp: gap shrinks by LERP_SPEED × dt each frame.
			-- Clamp to [0,1] after lerp to prevent floating-point overshoot on tiny diffs.
			local hCurrent = peek(healthSmoothed)
			local sCurrent = peek(shieldSmoothed)
			local alpha = math.min(LERP_SPEED * dt, 1)

			local hNew = hCurrent + (hTarget - hCurrent) * alpha
			local sNew = sCurrent + (sTarget - sCurrent) * alpha

			-- Only write if the change is large enough to be visible (> 0.1% bar width)
			-- to avoid thousands of redundant reactive updates when the bar is at rest.
			if math.abs(hNew - hCurrent) > 0.001 then
				healthSmoothed:set(math.clamp(hNew, 0, 1))
			end
			if math.abs(sNew - sCurrent) > 0.001 then
				shieldSmoothed:set(math.clamp(sNew, 0, 1))
			end
		end)
	)

	-- Raw computed percentages (used by the text label only — not the bar fill)
	local healthPercent = Computed(scope, function(use)
		local max = use(maxHealth)
		if max <= 0 then
			return 0
		end
		return math.clamp(use(health) / max, 0, 1)
	end)

	local _shieldPercent = Computed(scope, function(use)
		local max = use(maxHealth)
		if max <= 0 then
			return 0
		end
		return math.clamp(use(shield) / max, 0, 1)
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
					scope:New("UIStroke")({ Color = Color3.new(0, 0, 0), Thickness = 2 }),

					-- Health Fill (Green/Red)
					scope:New("Frame")({
						Name = "HealthFill",
						-- healthSmoothed provides the Heartbeat-lerped value so damage
						-- animates smoothly rather than snapping to the new width instantly.
						Size = Computed(scope, function(use)
							return UDim2.new(use(healthSmoothed), 0, 1, 0)
						end),
						BackgroundColor3 = Computed(scope, function(use)
							local pct = use(healthSmoothed)
							if pct < 0.25 then
								return Color3.fromRGB(220, 50, 50) -- Danger red
							elseif pct < 0.5 then
								return Color3.fromRGB(230, 160, 30) -- Warning orange
							end
							return Color3.fromRGB(46, 204, 113) -- Healthy emerald
						end),
						BorderSizePixel = 0,

						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
						},
					}),

					-- Shield Fill (Blue Overlay)
					scope:New("Frame")({
						Name = "ShieldFill",
						ZIndex = 2, -- Draw on top of health
						-- shieldSmoothed mirrors the same lerp pipeline as healthSmoothed.
						Size = Computed(scope, function(use)
							return UDim2.new(use(shieldSmoothed), 0, 1, 0)
						end),
						BackgroundColor3 = Color3.fromRGB(52, 152, 219), -- Blue
						BackgroundTransparency = 0.3, -- See-through to show it's a layer
						BorderSizePixel = 0,

						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, CORNER_RADIUS) }),
							scope:New("UIStroke")({
								Color = Color3.fromRGB(41, 128, 185),
								Thickness = 1,
							}),
						},
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
					}),
				},
			}),
		},
	})

	-- Return cleanup
	return function()
		Fusion.doCleanup(scope)
	end
end

return PlayerHealthBar
