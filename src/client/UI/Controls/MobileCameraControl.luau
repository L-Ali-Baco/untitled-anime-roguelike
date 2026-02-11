--[[
    MobileCameraControl.luau
    Touch drag area on right side of screen for camera rotation.
    Only visible/active on mobile devices.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

local MobileCameraControl = {}

--[[
    Create the MobileCameraControl component
    Returns: cleanup function
]]
function MobileCameraControl.new(inputController: any): () -> ()
	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- Check if mobile
	local isMobile = UserInputService.TouchEnabled

	-- Don't create UI on non-touch devices
	if not isMobile then
		return function()
			Fusion.doCleanup(scope)
		end
	end

	-- Track active touch for camera
	local activeTouchId: number? = nil
	local lastTouchPosition: Vector2? = nil

	-- Sensitivity from config
	local sensitivity = CameraConfig.Mobile.Sensitivity

	--[[
        Handle touch start on camera area
    ]]
	local function onTouchStarted(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		-- Only track one touch at a time for camera
		if activeTouchId then
			return
		end

		activeTouchId = input.Position.X + input.Position.Y * 10000 -- Unique ID
		lastTouchPosition = Vector2.new(input.Position.X, input.Position.Y)
	end

	--[[
        Handle touch movement for camera rotation
    ]]
	local function onTouchMoved(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		if not activeTouchId or not lastTouchPosition then
			return
		end

		local currentPosition = Vector2.new(input.Position.X, input.Position.Y)
		local delta = currentPosition - lastTouchPosition

		-- Send look delta to input controller
		-- Multiply by sensitivity factor for touch
		local lookDelta = delta * sensitivity * 2 -- Extra multiplier for touch feel
		inputController:SetLookDelta(lookDelta)

		lastTouchPosition = currentPosition
	end

	--[[
        Handle touch end
    ]]
	local function onTouchEnded(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		activeTouchId = nil
		lastTouchPosition = nil

		-- Clear look delta
		inputController:SetLookDelta(Vector2.zero)
	end

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "MobileCameraControlGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = -1, -- Behind other UI

		[Children] = {
			-- Invisible touch area on right side of screen
			scope:New("Frame")({
				Name = "CameraTouchArea",
				Position = UDim2.new(0.5, 0, 0, 0), -- Right half
				Size = UDim2.new(0.5, 0, 1, 0),
				BackgroundTransparency = 1, -- Invisible

				[OnEvent("InputBegan")] = onTouchStarted,
				[OnEvent("InputChanged")] = onTouchMoved,
				[OnEvent("InputEnded")] = onTouchEnded,
			}),
		},
	})

	-- Return cleanup function
	return function()
		Fusion.doCleanup(scope)
	end
end

return MobileCameraControl
