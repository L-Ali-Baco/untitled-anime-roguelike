--[[
    VirtualJoystick.luau
    Mobile virtual joystick using Fusion 0.3.
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
local JOYSTICK_SIZE = 150 -- pixels
local THUMB_SIZE = 60 -- pixels
local DEAD_ZONE = 0.1 -- 10% dead zone
local EDGE_PADDING = 30 -- pixels from screen edge

local VirtualJoystick = {}

--[[
    Create the VirtualJoystick component
    Returns: cleanup function
]]
function VirtualJoystick.new(inputController: any): () -> ()
	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- State
	local isActive = scope:Value(false)
	local thumbPosition = scope:Value(Vector2.new(0, 0)) -- Relative to center (-1 to 1)
	local joystickCenter = Vector2.new(EDGE_PADDING + JOYSTICK_SIZE / 2, 0) -- Will be set on touch

	-- Check if mobile
	local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	-- Don't create UI on non-mobile
	if not isMobile then
		return function()
			Fusion.doCleanup(scope)
		end
	end

	-- Track active touch
	local activeTouchId: number? = nil

	-- Calculate thumb offset from center (in pixels)
	local thumbOffset = Computed(scope, function(use)
		local pos = use(thumbPosition)
		local maxOffset = (JOYSTICK_SIZE - THUMB_SIZE) / 2
		return Vector2.new(pos.X * maxOffset, pos.Y * maxOffset)
	end)

	-- Handle touch input
	local function onTouchStarted(input: InputObject)
		-- Only handle touches on left side of screen
		local screenSize = workspace.CurrentCamera.ViewportSize
		if input.Position.X > screenSize.X * 0.5 then
			return -- Right side is for camera
		end

		-- Ignore if already tracking a touch
		if activeTouchId then
			return
		end

		activeTouchId = input.UserInputState == Enum.UserInputState.Begin
				and math.floor(input.Position.X + input.Position.Y * 10000)
			or nil

		-- Set joystick center to touch position
		joystickCenter = Vector2.new(input.Position.X, input.Position.Y)
		isActive:set(true)
		thumbPosition:set(Vector2.new(0, 0))
	end

	local function onTouchMoved(input: InputObject)
		if not peek(isActive) then
			return
		end

		-- Calculate direction from center
		local touchPos = Vector2.new(input.Position.X, input.Position.Y)
		local delta = touchPos - joystickCenter
		local maxRadius = JOYSTICK_SIZE / 2

		-- Normalize and clamp to radius
		local distance = delta.Magnitude
		local direction = delta / math.max(distance, 0.001)
		local clampedDistance = math.min(distance, maxRadius)

		-- Normalize to -1 to 1 range
		local normalizedPos = direction * (clampedDistance / maxRadius)

		-- Apply dead zone
		local magnitude = normalizedPos.Magnitude
		if magnitude < DEAD_ZONE then
			normalizedPos = Vector2.new(0, 0)
			magnitude = 0
		else
			-- Remap to 0-1 range after dead zone
			local remappedMagnitude = (magnitude - DEAD_ZONE) / (1 - DEAD_ZONE)
			normalizedPos = normalizedPos.Unit * remappedMagnitude
		end

		thumbPosition:set(normalizedPos)

		-- Send to input controller (flip Y for world space)
		local moveDir = Vector2.new(normalizedPos.X, -normalizedPos.Y)
		inputController:SetMoveDirection(moveDir)
	end

	local function onTouchEnded(input: InputObject)
		-- Release joystick
		isActive:set(false)
		thumbPosition:set(Vector2.new(0, 0))
		activeTouchId = nil

		-- Clear input
		inputController:SetMoveDirection(Vector2.new(0, 0))
	end

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "VirtualJoystickGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,

		[Children] = {
			-- Joystick base (outer circle)
			scope:New("Frame")({
				Name = "JoystickBase",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, EDGE_PADDING + JOYSTICK_SIZE / 2, 1, -(EDGE_PADDING + JOYSTICK_SIZE / 2)),
				Size = UDim2.new(0, JOYSTICK_SIZE, 0, JOYSTICK_SIZE),
				BackgroundColor3 = Color3.fromRGB(0, 0, 0),
				BackgroundTransparency = 0.5,

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

					-- Thumb (inner circle)
					scope:New("Frame")({
						Name = "Thumb",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = Computed(scope, function(use)
							local offset = use(thumbOffset)
							return UDim2.new(0.5, offset.X, 0.5, offset.Y)
						end),
						Size = UDim2.new(0, THUMB_SIZE, 0, THUMB_SIZE),
						BackgroundColor3 = Color3.fromRGB(255, 255, 255),
						BackgroundTransparency = 0.2,

						[Children] = {
							scope:New("UICorner")({
								CornerRadius = UDim.new(0.5, 0),
							}),
						},
					}),
				},
			}),

			-- Invisible touch capture area (left half of screen)
			scope:New("Frame")({
				Name = "TouchArea",
				Position = UDim2.new(0, 0, 0, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				BackgroundTransparency = 1,

				[OnEvent("InputBegan")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.Touch then
						onTouchStarted(input)
					end
				end,

				[OnEvent("InputChanged")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.Touch then
						onTouchMoved(input)
					end
				end,

				[OnEvent("InputEnded")] = function(input: InputObject)
					if input.UserInputType == Enum.UserInputType.Touch then
						onTouchEnded(input)
					end
				end,
			}),
		},
	})

	-- Return cleanup function
	return function()
		Fusion.doCleanup(scope)
	end
end

return VirtualJoystick
