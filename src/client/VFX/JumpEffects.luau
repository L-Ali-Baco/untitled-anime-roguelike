--[[
    JumpEffects.luau
    Visual effects for jump mechanics:
    - Ground dust puff on ground jump
    - Anime-style air burst ring on double/air jump
]]

local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)

local JumpEffects = {}

-- Config
local JumpConfig = MovementConfig.Jump

-- Effect settings
local GROUND_DUST = {
	ParticleCount = 8,
	Color = Color3.fromRGB(180, 160, 140), -- Brownish dust
	Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	}),
	Lifetime = NumberRange.new(0.2, 0.4),
	Speed = NumberRange.new(4, 8),
	SpreadAngle = Vector2.new(60, 60),
}

local AIR_BURST = {
	RingSize = 4, -- studs diameter
	RingThickness = 0.15, -- studs
	ExpandTime = 0.25, -- seconds to expand
	FadeTime = 0.15, -- seconds to fade out
	Color = JumpConfig.AirBurstColor or Color3.fromRGB(100, 200, 255),
	ParticleCount = 12, -- particles shooting downward
}

--[[
    Create a simple particle emitter for dust
]]
local function createDustEmitter(position: Vector3): ParticleEmitter
	-- Create attachment at position
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	-- Create particle emitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(GROUND_DUST.Color)
	emitter.Size = GROUND_DUST.Size
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = GROUND_DUST.Lifetime
	emitter.Speed = GROUND_DUST.Speed
	emitter.SpreadAngle = GROUND_DUST.SpreadAngle
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-100, 100)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rate = 0 -- We'll emit manually
	emitter.Parent = attachment

	return emitter, attachment
end

--[[
    Spawn ground dust effect at position
]]
function JumpEffects:SpawnGroundDust(position: Vector3)
	if not JumpConfig.GroundDustEnabled then
		return
	end

	-- Offset position slightly down to be at feet level
	local dustPosition = position - Vector3.new(0, 2, 0)

	local emitter, attachment = createDustEmitter(dustPosition)

	-- Emit burst of particles
	emitter:Emit(GROUND_DUST.ParticleCount)

	-- Cleanup after particles fade
	Debris:AddItem(attachment, 0.5)
end

--[[
    Create the expanding ring mesh for air burst
]]
local function createAirBurstRing(position: Vector3, color: Color3): (Part, CylinderHandleAdornment?)
	-- Create a ring using a Part with CylinderMesh
	-- Alternative: Use beam or trail for better visuals

	local ring = Instance.new("Part")
	ring.Name = "AirBurstRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.1, AIR_BURST.RingThickness, 0.1) -- Start small
	ring.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, 0)

	-- Use a mesh to create ring shape (torus-like effect via cylinder)
	local mesh = Instance.new("CylinderMesh")
	mesh.Parent = ring

	ring.Parent = workspace

	return ring
end

--[[
    Create downward particles for air burst
]]
local function createAirBurstParticles(position: Vector3, color: Color3)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.5
	emitter.LightInfluence = 0.5
	emitter.Lifetime = NumberRange.new(0.15, 0.25)
	emitter.Speed = NumberRange.new(15, 25)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Rate = 0
	emitter.Parent = attachment

	-- Emit particles
	emitter:Emit(AIR_BURST.ParticleCount)

	-- Cleanup
	Debris:AddItem(attachment, 0.5)
end

--[[
    Spawn anime-style air burst effect
    @param position - World position to spawn effect
    @param jumpNumber - Which air jump (1 = first double jump, 2 = triple, etc.)
]]
function JumpEffects:SpawnAirBurst(position: Vector3, jumpNumber: number?)
	if not JumpConfig.AirBurstEnabled then
		return
	end

	jumpNumber = jumpNumber or 1

	-- Offset position down slightly (at character's feet level)
	local burstPosition = position - Vector3.new(0, 2.5, 0)

	-- Get color (can vary by jump number for visual feedback)
	local color = AIR_BURST.Color
	if jumpNumber > 1 then
		-- Slightly different hue for subsequent jumps
		local h, s, v = color:ToHSV()
		h = (h + 0.1 * (jumpNumber - 1)) % 1 -- Shift hue
		color = Color3.fromHSV(h, s, v)
	end

	-- Create expanding ring
	local ring = createAirBurstRing(burstPosition, color)

	-- Animate ring expansion
	local expandTween = TweenService:Create(
		ring,
		TweenInfo.new(AIR_BURST.ExpandTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(AIR_BURST.RingSize, AIR_BURST.RingThickness, AIR_BURST.RingSize),
		}
	)

	-- Animate fade out
	local fadeTween = TweenService:Create(ring, TweenInfo.new(AIR_BURST.FadeTime, Enum.EasingStyle.Linear), {
		Transparency = 1,
	})

	expandTween:Play()

	-- Start fade after expansion
	task.delay(AIR_BURST.ExpandTime * 0.6, function()
		fadeTween:Play()
	end)

	-- Create downward particles
	createAirBurstParticles(burstPosition, color)

	-- Cleanup ring
	Debris:AddItem(ring, AIR_BURST.ExpandTime + AIR_BURST.FadeTime + 0.1)
end

--[[
    Spawn landing effect (optional, can be called from JumpController on land)
]]
function JumpEffects:SpawnLandingDust(position: Vector3, fallSpeed: number?)
	fallSpeed = fallSpeed or 0

	-- Only show dust for significant falls
	if fallSpeed < 20 then
		return
	end

	-- Scale particle count based on fall speed
	local intensity = math.clamp(fallSpeed / 50, 0.5, 2)
	local particleCount = math.floor(GROUND_DUST.ParticleCount * intensity)

	local dustPosition = position - Vector3.new(0, 2, 0)
	local emitter, attachment = createDustEmitter(dustPosition)

	-- Emit scaled burst
	emitter:Emit(particleCount)

	-- Cleanup
	Debris:AddItem(attachment, 0.6)
end

return JumpEffects
