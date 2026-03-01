--[[
	ExplosionVFX.luau
	Handles stylized particle explosions for suicide bombers (Keg) and the
	VolatileCasing item proc.

	POOLING CHANGES vs. original:
	  - 8 debris Part instances → fetched from VFXPool "ExplosionDebris" pool
	  - Core expanding sphere → fetched from VFXPool "ExplosionSphere" pool
	  - Both returned via ReturnPartDelayed; zero Debris:AddItem calls for Parts
	  - ParticleEmitter + Attachment are NOT pooled (cheap; pool overhead > gain)
	  - Roblox Explosion instance is NOT pooled (sound/light only, rare, ~0.5 µs)
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VFXPool = require(script.Parent.VFXPool)

local ExplosionVFX = {}
ExplosionVFX.Name = "ExplosionVFX"

-- Reference to ScreenShakeController (injected via Init)
local ScreenShakeController = nil

-- Pre-baked TweenInfos so they are not allocated on the hot path.
local SPHERE_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEBRIS_SHRINK_INFO = TweenInfo.new(1.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Explosion colour palette (purple-void aesthetic matching Keg aura).
local SPHERE_INNER_COLOR = Color3.fromRGB(200, 80, 255) -- hot violet core
local SPHERE_OUTER_COLOR = Color3.fromRGB(80, 0, 150) -- deep void rim

function ExplosionVFX:Init(shakeController)
	ScreenShakeController = shakeController
end

function ExplosionVFX:Play(position: Vector3, radius: number)
	radius = radius or 12

	-- === Screen Shake ===
	if ScreenShakeController then
		ScreenShakeController:Shake(0.8, 0.4)
	end

	-- === Attachment (anchor for particle emitters — NOT pooled; cheap) ===
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	-- === 1. Pooled Expanding Sphere (core bloom) ===
	-- Replaces the old "Instance.new Part" approach with a pool fetch.
	-- The sphere expands from radius*0.5 → radius*2.5 studs while fading.
	local sphere = VFXPool:GetPart("ExplosionSphere")
	local startSize = Vector3.new(radius * 0.5, radius * 0.5, radius * 0.5)
	local endSize = Vector3.new(radius * 2.5, radius * 2.5, radius * 2.5)

	sphere.Color = SPHERE_INNER_COLOR
	sphere.Size = startSize
	sphere.Transparency = 0.15
	sphere.CFrame = CFrame.new(position)
	sphere.Anchored = true -- stays anchored for this effect; no physics needed
	sphere.CastShadow = false
	sphere.CanCollide = false
	sphere.Parent = workspace

	TweenService:Create(sphere, SPHERE_TWEEN_INFO, {
		Size = endSize,
		Transparency = 1,
		Color = SPHERE_OUTER_COLOR,
	}):Play()

	-- Return sphere to pool after tween finishes + a small buffer.
	-- At this point Transparency = 1 so the part is invisible; safe to teleport underground.
	VFXPool:ReturnPartDelayed("ExplosionSphere", sphere, 0.5)

	-- === 2. Core Burst Particles (dark purple smoke) ===
	-- Attachment-based; kept as-is since Attachments + ParticleEmitters have
	-- negligible allocation cost compared to Parts.
	local coreBurst = Instance.new("ParticleEmitter")
	coreBurst.Name = "CoreBurst"
	coreBurst.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(50, 0, 80)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(20, 0, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 0, 20)),
	})
	coreBurst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, radius * 1.5),
		NumberSequenceKeypoint.new(1, radius * 2),
	})
	coreBurst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	coreBurst.Lifetime = NumberRange.new(0.6, 0.8)
	coreBurst.Speed = NumberRange.new(50, 80)
	coreBurst.Drag = 4
	coreBurst.SpreadAngle = Vector2.new(180, 180)
	coreBurst.Rate = 0
	coreBurst.Parent = attachment

	-- === 3. Energy Spikes (magenta sparks) ===
	local spikes = Instance.new("ParticleEmitter")
	spikes.Name = "Spikes"
	spikes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	spikes.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 100, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 0, 255)),
	})
	spikes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, radius * 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	spikes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	spikes.Lifetime = NumberRange.new(0.3, 0.5)
	spikes.Speed = NumberRange.new(100, 150)
	spikes.Drag = 2
	spikes.SpreadAngle = Vector2.new(180, 180)
	spikes.Squash = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 5),
		NumberSequenceKeypoint.new(1, 5),
	})
	spikes.Rate = 0
	spikes.Parent = attachment

	-- Emit both particle sets simultaneously.
	coreBurst:Emit(30)
	spikes:Emit(15)

	-- Attachment cleanup: Debris:AddItem is fine here because Attachments +
	-- ParticleEmitters are Lua-side lightweight; no C++ physics/render entry.
	Debris:AddItem(attachment, 2)

	-- === 4. Pooled Wood Debris Shards ===
	-- OLD: 8 × Instance.new("Part") + Debris:AddItem each → 8 GC allocs + 8 GC frees
	-- NEW: 8 × VFXPool:GetPart("ExplosionDebris") → 0 allocations, 0 GC frees
	local numDebris = 8
	-- Total lifetime: 0.2 s delay + 1.3 s shrink = 1.5 s. Return at 1.55 s.
	local DEBRIS_RETURN_DELAY = 1.55

	for i = 1, numDebris do
		local shard = VFXPool:GetPart("ExplosionDebris")

		-- Randomise size. ObjectPool preserves the template size by default;
		-- we override it here. ReturnPart() does NOT reset Size — this is
		-- intentional: size is always set on GetPart() before use.
		local s = math.random(5, 20) / 10 -- 0.5 – 2.0 studs
		shard.Size = Vector3.new(s, s * 1.5, s * 0.4)
		shard.Color = Color3.fromRGB(
			math.random(100, 160), -- warm wood browns
			math.random(60, 100),
			math.random(30, 60)
		)
		shard.Material = Enum.Material.Wood

		-- Teleport into position while still anchored (safe).
		local angle = math.pi * 2 * (i / numDebris) + math.random(-314, 314) / 1000
		shard.CFrame = CFrame.new(position) * CFrame.Angles(
			math.random() * math.pi,
			math.random() * math.pi,
			math.random() * math.pi
		)

		-- Release to physics and apply launch impulse.
		-- NOTE: AssemblyLinearVelocity replaces the deprecated .Velocity property.
		shard.Anchored = false
		shard.CanCollide = false

		local speed = math.random(40, 80)
		local vx = math.cos(angle) * speed
		local vz = math.sin(angle) * speed
		local vy = math.random(30, 60)
		shard.AssemblyLinearVelocity = Vector3.new(vx, vy, vz)
		shard.AssemblyAngularVelocity = Vector3.new(
			math.random(-20, 20),
			math.random(-20, 20),
			math.random(-20, 20)
		)

		shard.Parent = workspace

		-- After the flight arc, tween to invisible then return to pool.
		task.delay(0.2, function()
			if shard.Parent then
				TweenService:Create(shard, DEBRIS_SHRINK_INFO, {
					Size = Vector3.new(0.02, 0.02, 0.02),
					Transparency = 1,
				}):Play()
			end
		end)

		-- Return to pool after full lifetime. ObjectPool.ReturnPart will:
		--   • Set Anchored = true (stops physics)
		--   • Zero AssemblyLinearVelocity + AssemblyAngularVelocity
		--   • Set Transparency = 1 (already 1 from tween)
		--   • Teleport to parking zone
		VFXPool:ReturnPartDelayed("ExplosionDebris", shard, DEBRIS_RETURN_DELAY)
	end
end

return ExplosionVFX
