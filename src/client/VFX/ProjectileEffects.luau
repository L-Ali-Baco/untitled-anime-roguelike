--[[
    ProjectileEffects.luau
    Visual effects for ranged attacks.
    
    Features:
    - Muzzle flash (bright flash at gun position)
    - Bullet tracer (fast-moving line from gun to hit point)
    - Hit sparks (small particles on impact)
    - All effects are client-side only (cosmetic)
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Note: ClassConfig reserved for future VFX customization per class
local _ = require(ReplicatedStorage.Shared.Config.ClassConfig)

local ProjectileEffects = {}
ProjectileEffects.Name = "ProjectileEffects"

-- Default config (can be overridden per-call)
local DEFAULT_CONFIG = {
	-- Muzzle flash
	MuzzleFlashEnabled = true,
	MuzzleFlashColor = Color3.fromRGB(255, 200, 100),
	MuzzleFlashSize = 1.5,
	MuzzleFlashDuration = 0.05,

	-- Tracer
	TracerEnabled = true,
	TracerColor = Color3.fromRGB(255, 220, 100),
	TracerWidth = 0.15,
	TracerLifetime = 0.08,

	-- Hit spark
	HitSparkEnabled = true,
	HitSparkColor = Color3.fromRGB(255, 150, 50),
	HitSparkCount = 4,
}

-- VFX folder
local vfxFolder: Folder? = nil

--[[
    Get or create the VFX folder in workspace
]]
local function getVFXFolder(): Folder
	if not vfxFolder or not vfxFolder.Parent then
		vfxFolder = workspace:FindFirstChild("VFX") :: Folder?
		if not vfxFolder then
			vfxFolder = Instance.new("Folder")
			vfxFolder.Name = "VFX"
			vfxFolder.Parent = workspace
		end
	end
	return vfxFolder :: Folder
end

--[[
    Get config value with fallback to default
]]
local function getConfigValue(cfg: any?, key: string): any
	if cfg and cfg[key] ~= nil then
		return cfg[key]
	end
	return DEFAULT_CONFIG[key]
end

--[[
    Create muzzle flash effect
    @param position: Position to spawn flash
    @param direction: Direction the gun is pointing
    @param config: Optional config overrides
]]
function ProjectileEffects:SpawnMuzzleFlash(position: Vector3, direction: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not cfg.MuzzleFlashEnabled then
		return
	end

	local folder = getVFXFolder()

	-- Create the flash part
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = cfg.MuzzleFlashColor or DEFAULT_CONFIG.MuzzleFlashColor
	flash.Size = Vector3.new(cfg.MuzzleFlashSize or 1.5, cfg.MuzzleFlashSize or 1.5, cfg.MuzzleFlashSize or 1.5)
	flash.Shape = Enum.PartType.Ball
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.3
	flash.Parent = folder

	-- Add point light
	local light = Instance.new("PointLight")
	light.Color = cfg.MuzzleFlashColor or DEFAULT_CONFIG.MuzzleFlashColor
	light.Brightness = 3
	light.Range = 8
	light.Parent = flash

	-- Quick fade out
	local tweenInfo = TweenInfo.new(cfg.MuzzleFlashDuration or 0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local tween = TweenService:Create(flash, tweenInfo, {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1),
	})

	local lightTween = TweenService:Create(light, tweenInfo, {
		Brightness = 0,
	})

	tween:Play()
	lightTween:Play()

	Debris:AddItem(flash, (cfg.MuzzleFlashDuration or DEFAULT_CONFIG.MuzzleFlashDuration) + 0.1)
end

--[[
    Create bullet tracer effect
    @param startPos: Where the bullet starts (muzzle)
    @param endPos: Where the bullet ends (hit point or max range)
    @param config: Optional config overrides
]]
function ProjectileEffects:SpawnTracer(startPos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not getConfigValue(cfg, "TracerEnabled") then
		return
	end

	local folder = getVFXFolder()

	-- Calculate tracer properties with safety check
	local diff = endPos - startPos
	local distance = diff.Magnitude
	if distance < 0.01 then
		return
	end

	local midPoint = (startPos + endPos) / 2
	local direction = diff.Unit

	-- Create the tracer beam
	local tracer = Instance.new("Part")
	tracer.Name = "BulletTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = cfg.TracerColor or DEFAULT_CONFIG.TracerColor

	local width = cfg.TracerWidth or 0.15
	tracer.Size = Vector3.new(width, width, distance)
	tracer.CFrame = CFrame.lookAt(midPoint, endPos)
	tracer.Transparency = 0
	tracer.Parent = folder

	-- Fade out quickly
	local lifetime = cfg.TracerLifetime or 0.08
	local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local tween = TweenService:Create(tracer, tweenInfo, {
		Transparency = 1,
		Size = Vector3.new(0.02, 0.02, distance),
	})

	tween:Play()

	Debris:AddItem(tracer, lifetime + 0.1)
end

--[[
    Create hit spark particles
    @param hitPosition: Where the bullet hit
    @param hitNormal: Surface normal at hit point (optional)
    @param config: Optional config overrides
]]
function ProjectileEffects:SpawnHitSparks(hitPosition: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not cfg.HitSparkEnabled then
		return
	end

	local folder = getVFXFolder()
	local sparkCount = cfg.HitSparkCount or 4
	local sparkColor = cfg.HitSparkColor or DEFAULT_CONFIG.HitSparkColor

	-- Create small spark particles
	for i = 1, sparkCount do
		local spark = Instance.new("Part")
		spark.Name = "HitSpark"
		spark.Anchored = false
		spark.CanCollide = false
		spark.CanQuery = false
		spark.CanTouch = false
		spark.CastShadow = false
		spark.Material = Enum.Material.Neon
		spark.Color = sparkColor
		spark.Size = Vector3.new(0.1, 0.1, 0.1)
		spark.Shape = Enum.PartType.Ball
		spark.CFrame = CFrame.new(hitPosition)
		spark.Transparency = 0.3
		spark.Parent = folder

		-- Random velocity away from hit point
		local randomDir = Vector3.new(
			math.random() - 0.5,
			math.random() * 0.5 + 0.2, -- Bias upward
			math.random() - 0.5
		).Unit

		-- If we have a normal, bias sparks away from surface
		if hitNormal then
			randomDir = (randomDir + hitNormal).Unit
		end

		local speed = math.random(15, 30)
		spark.AssemblyLinearVelocity = randomDir * speed

		-- Fade out
		local lifetime = 0.15 + math.random() * 0.1
		local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local tween = TweenService:Create(spark, tweenInfo, {
			Transparency = 1,
			Size = Vector3.new(0.02, 0.02, 0.02),
		})

		tween:Play()

		Debris:AddItem(spark, lifetime + 0.1)
	end

	-- Add a brief flash at hit point
	local flash = Instance.new("Part")
	flash.Name = "HitFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = sparkColor
	flash.Size = Vector3.new(0.8, 0.8, 0.8)
	flash.Shape = Enum.PartType.Ball
	flash.CFrame = CFrame.new(hitPosition)
	flash.Transparency = 0.4
	flash.Parent = folder

	local flashTween = TweenService:Create(flash, TweenInfo.new(0.08, Enum.EasingStyle.Quad), {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1),
	})
	flashTween:Play()

	Debris:AddItem(flash, 0.15)
end

--[[
    Full ranged attack VFX sequence
    Spawns muzzle flash, tracer, and hit sparks
    @param muzzlePos: Gun muzzle position
    @param hitPos: Where the bullet hit
    @param hitNormal: Surface normal (optional)
    @param config: Attack config (from ClassConfig.RangedAttack)
]]
function ProjectileEffects:PlayRangedHitEffects(muzzlePos: Vector3, hitPos: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG

	-- Calculate direction with safety check
	local diff = hitPos - muzzlePos
	if diff.Magnitude < 0.01 then
		return
	end
	local direction = diff.Unit

	-- Muzzle flash
	self:SpawnMuzzleFlash(muzzlePos, direction, cfg)

	-- Tracer
	self:SpawnTracer(muzzlePos, hitPos, cfg)

	-- Hit sparks
	self:SpawnHitSparks(hitPos, hitNormal, cfg)
end

--[[
    Play miss effects (no hit sparks)
    @param muzzlePos: Gun muzzle position
    @param endPos: Where the bullet ends (max range point)
    @param config: Attack config
]]
function ProjectileEffects:PlayRangedMissEffects(muzzlePos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG

	-- Calculate direction with safety check
	local diff = endPos - muzzlePos
	if diff.Magnitude < 0.01 then
		return
	end
	local direction = diff.Unit

	-- Muzzle flash
	self:SpawnMuzzleFlash(muzzlePos, direction, cfg)

	-- Tracer (fades before reaching max range for visual effect)
	self:SpawnTracer(muzzlePos, endPos, cfg)
end

--[[
    Initialize the module
]]
function ProjectileEffects:Init()
	print("[ProjectileEffects] Initialized")
end

--[[
    Start the module
]]
function ProjectileEffects:Start()
	print("[ProjectileEffects] Started")
end

return ProjectileEffects
