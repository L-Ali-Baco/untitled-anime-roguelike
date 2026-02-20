--[[
    ProjectileEffects.luau
    Visual effects for ranged attacks.
    Refactored to use VFXPool and VFXSystem.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFXPool = require(script.Parent.VFXPool)
local VFXSystem = require(script.Parent.VFXSystem)

-- Note: ClassConfig reserved for future VFX customization per class
local _ = require(ReplicatedStorage.Shared.Config.ClassConfig)

local ProjectileEffects = {}
ProjectileEffects.Name = "ProjectileEffects"

-- Default config (can be overridden per-call)
local DEFAULT_CONFIG = {
	MuzzleFlashEnabled = true,
	MuzzleFlashColor = Color3.fromRGB(255, 200, 100),
	MuzzleFlashSize = 1.5,
	MuzzleFlashDuration = 0.05,

	TracerEnabled = true,
	TracerColor = Color3.fromRGB(255, 220, 100),
	TracerWidth = 0.15,
	TracerLifetime = 0.08,

	HitSparkEnabled = true,
	HitSparkColor = Color3.fromRGB(255, 150, 50),
	HitSparkCount = 4,
}

-- Templates
local function getMuzzleFlashTemplate()
	local part = Instance.new("Part")
	part.Name = "MuzzleFlash"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Ball

	local light = Instance.new("PointLight")
	light.Parent = part
	return part
end

local function getTracerTemplate()
	local part = Instance.new("Part")
	part.Name = "BulletTracer"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	return part
end

local function getSparkTemplate()
	local part = Instance.new("Part")
	part.Name = "HitSpark"
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Ball
	return part
end

local function getHitFlashTemplate()
	local part = Instance.new("Part")
	part.Name = "HitFlash"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Ball
	return part
end

-- Helper
local function getConfigValue(cfg: any?, key: string): any
	if cfg and cfg[key] ~= nil then
		return cfg[key]
	end
	return DEFAULT_CONFIG[key]
end

--[[
    Create muzzle flash effect
]]
function ProjectileEffects:SpawnMuzzleFlash(position: Vector3, direction: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not cfg.MuzzleFlashEnabled then return end

	local flash = VFXPool:Get("MuzzleFlash", getMuzzleFlashTemplate())
	flash.Color = cfg.MuzzleFlashColor or DEFAULT_CONFIG.MuzzleFlashColor
	flash.Size = Vector3.new(cfg.MuzzleFlashSize or 1.5, cfg.MuzzleFlashSize or 1.5, cfg.MuzzleFlashSize or 1.5)
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.3
	flash.Parent = workspace

	local light = flash:FindFirstChildOfClass("PointLight")
	if light then
		light.Color = flash.Color
		light.Brightness = 3
        light.Enabled = true
	end

	local duration = cfg.MuzzleFlashDuration or 0.05

	VFXSystem:Add(flash, duration, {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1)
	}, {
		EasingStyle = Enum.EasingStyle.Quad,
		PoolName = "MuzzleFlash"
	})

	if light then
		VFXSystem:Add(light, duration, {
			Brightness = 0
		}, {
			EasingStyle = Enum.EasingStyle.Quad
		})
	end
end

--[[
    Create bullet tracer effect
]]
function ProjectileEffects:SpawnTracer(startPos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not getConfigValue(cfg, "TracerEnabled") then return end

	local diff = endPos - startPos
	local distance = diff.Magnitude
	if distance < 0.01 then return end

	local midPoint = (startPos + endPos) / 2

	local tracer = VFXPool:Get("BulletTracer", getTracerTemplate())
	tracer.Color = cfg.TracerColor or DEFAULT_CONFIG.TracerColor
	local width = cfg.TracerWidth or 0.15
	tracer.Size = Vector3.new(width, width, distance)
	tracer.CFrame = CFrame.lookAt(midPoint, endPos)
	tracer.Transparency = 0
	tracer.Parent = workspace

	local lifetime = cfg.TracerLifetime or 0.08

	VFXSystem:Add(tracer, lifetime, {
		Transparency = 1,
		Size = Vector3.new(0.02, 0.02, distance)
	}, {
		EasingStyle = Enum.EasingStyle.Quad,
		PoolName = "BulletTracer"
	})
end

--[[
    Create hit spark particles
]]
function ProjectileEffects:SpawnHitSparks(hitPosition: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not cfg.HitSparkEnabled then return end

	local sparkCount = cfg.HitSparkCount or 4
	local sparkColor = cfg.HitSparkColor or DEFAULT_CONFIG.HitSparkColor

	for i = 1, sparkCount do
		local spark = VFXPool:Get("HitSpark", getSparkTemplate())
		spark.Color = sparkColor
		spark.Size = Vector3.new(0.1, 0.1, 0.1)
		spark.CFrame = CFrame.new(hitPosition)
		spark.Transparency = 0.3
		spark.Anchored = false -- Physics needs unanchored
		spark.Parent = workspace

		local randomDir = Vector3.new(
			math.random() - 0.5,
			math.random() * 0.5 + 0.2,
			math.random() - 0.5
		).Unit

		if hitNormal then
			randomDir = (randomDir + hitNormal).Unit
		end

		local speed = math.random(15, 30)
		spark.AssemblyLinearVelocity = randomDir * speed

		local lifetime = 0.15 + math.random() * 0.1

		VFXSystem:Add(spark, lifetime, {
			Transparency = 1,
			Size = Vector3.new(0.02, 0.02, 0.02)
		}, {
			EasingStyle = Enum.EasingStyle.Quad,
			PoolName = "HitSpark"
		})
	end

	-- Flash
	local flash = VFXPool:Get("HitFlash", getHitFlashTemplate())
	flash.Color = sparkColor
	flash.Size = Vector3.new(0.8, 0.8, 0.8)
	flash.CFrame = CFrame.new(hitPosition)
	flash.Transparency = 0.4
	flash.Parent = workspace

	VFXSystem:Add(flash, 0.08, {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1)
	}, {
		EasingStyle = Enum.EasingStyle.Quad,
		PoolName = "HitFlash"
	})
end

--[[
    Full ranged attack VFX sequence
]]
function ProjectileEffects:PlayRangedHitEffects(muzzlePos: Vector3, hitPos: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if (hitPos - muzzlePos).Magnitude < 0.01 then return end

	self:SpawnMuzzleFlash(muzzlePos, (hitPos - muzzlePos).Unit, cfg)
	self:SpawnTracer(muzzlePos, hitPos, cfg)
	self:SpawnHitSparks(hitPos, hitNormal, cfg)
end

--[[
    Play miss effects
]]
function ProjectileEffects:PlayRangedMissEffects(muzzlePos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if (endPos - muzzlePos).Magnitude < 0.01 then return end

	self:SpawnMuzzleFlash(muzzlePos, (endPos - muzzlePos).Unit, cfg)
	self:SpawnTracer(muzzlePos, endPos, cfg)
end

--[[
    Lifecycle
]]
function ProjectileEffects:Init()
	print("[ProjectileEffects] Initialized")
end

function ProjectileEffects:Start()
	print("[ProjectileEffects] Started")
end

return ProjectileEffects
