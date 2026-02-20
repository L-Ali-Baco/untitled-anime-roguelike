--[[
    VFXSystem.luau
    Centralized interpolation engine for Visual Effects.

    Purpose:
    - Replaces hundreds of individual TweenService/Tween objects with a single Heartbeat loop.
    - Optimized for high-frequency, fire-and-forget effects (projectiles, damage numbers).
    - Automatically handles object pooling returns.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService") -- Used for GetValue (easing math)
local VFXPool = require(script.Parent.VFXPool)

local VFXSystem = {}
VFXSystem.Name = "VFXSystem"

-- Types
type EffectData = {
	StartTime: number,
	Duration: number,
	StartProps: { [string]: any }?,
	TargetProps: { [string]: any }?,
	Callback: ((Instance, number) -> ())?,
	EasingStyle: Enum.EasingStyle,
	EasingDirection: Enum.EasingDirection,
	PoolName: string?,
	OnComplete: ((Instance) -> ())?
}

-- Storage
local activeEffects: { [Instance]: EffectData } = {}
local pendingAdds: { [Instance]: EffectData } = {}
local isUpdating = false

-- Helper for simple linear interpolation
local function lerp(a: any, b: any, t: number)
	if typeof(a) == "number" then
		return a + (b - a) * t
	elseif typeof(a) == "Vector3" or typeof(a) == "Color3" or typeof(a) == "UDim2" or typeof(a) == "CFrame" then
		return a:Lerp(b, t)
	end
	return a -- Fallback
end

--[[
    Add an effect to be animated (Tween-like behavior).
    @param instance: The object to animate.
    @param duration: Time in seconds.
    @param targetProps: Table of properties to animate to (e.g. { Transparency = 1, Size = Vector3.new(0,0,0) }).
    @param options: Optional settings { EasingStyle, EasingDirection, PoolName, OnComplete }.
]]
function VFXSystem:Add(instance: Instance, duration: number, targetProps: { [string]: any }, options: any?)
	options = options or {}

	local startProps = {}
	for prop, _ in targetProps do
		startProps[prop] = instance[prop]
	end

	local data = {
		StartTime = os.clock(),
		Duration = duration,
		StartProps = startProps,
		TargetProps = targetProps,
		EasingStyle = options.EasingStyle or Enum.EasingStyle.Linear,
		EasingDirection = options.EasingDirection or Enum.EasingDirection.Out,
		PoolName = options.PoolName,
		OnComplete = options.OnComplete
	}

	if isUpdating then
		pendingAdds[instance] = data
	else
		activeEffects[instance] = data
	end
end

--[[
    Play a custom effect with a callback (manual interpolation).
    @param instance: The object context.
    @param duration: Time in seconds.
    @param callback: Function(instance, alpha) called every frame.
    @param options: Optional settings { EasingStyle, EasingDirection, PoolName, OnComplete }.
]]
function VFXSystem:Play(instance: Instance, duration: number, callback: (Instance, number) -> (), options: any?)
	options = options or {}

	local data = {
		StartTime = os.clock(),
		Duration = duration,
		Callback = callback,
		EasingStyle = options.EasingStyle or Enum.EasingStyle.Linear,
		EasingDirection = options.EasingDirection or Enum.EasingDirection.Out,
		PoolName = options.PoolName,
		OnComplete = options.OnComplete
	}

	if isUpdating then
		pendingAdds[instance] = data
	else
		activeEffects[instance] = data
	end
end

--[[
    Cancel an active effect on an instance.
]]
function VFXSystem:Cancel(instance: Instance)
	if activeEffects[instance] then
		activeEffects[instance] = nil
	end
	if pendingAdds[instance] then
		pendingAdds[instance] = nil
	end
end

-- Main Update Loop
local function update(dt: number)
	isUpdating = true
	local now = os.clock()

	for instance, data in activeEffects do
		-- Verify instance still exists
		if not instance or not instance.Parent then
			activeEffects[instance] = nil
			continue
		end

		local elapsed = now - data.StartTime
		local rawAlpha = math.clamp(elapsed / data.Duration, 0, 1)

		-- Apply Easing
		local alpha = TweenService:GetValue(rawAlpha, data.EasingStyle, data.EasingDirection)

		-- Update Properties or Callback
		if data.Callback then
			data.Callback(instance, alpha)
		elseif data.StartProps and data.TargetProps then
			for prop, targetVal in data.TargetProps do
				local startVal = data.StartProps[prop]
				instance[prop] = lerp(startVal, targetVal, alpha)
			end
		end

		-- Check Completion
		if rawAlpha >= 1 then
			if data.OnComplete then
				task.spawn(data.OnComplete, instance)
			end

			if data.PoolName then
				VFXPool:Return(instance, data.PoolName)
			end

			activeEffects[instance] = nil
		end
	end

	isUpdating = false

	-- Process pending adds
	for inst, data in pendingAdds do
		activeEffects[inst] = data
		pendingAdds[inst] = nil
	end
end

RunService.Heartbeat:Connect(update)

VFXSystem._update = update
return VFXSystem
