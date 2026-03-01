--[[
	ProjectileEffects.luau
	Visual effects for ranged attacks.

	Features:
	- Muzzle flash (bright flash at gun position)
	- Bullet tracer (fast-moving line from gun to hit point)
	- Hit sparks (small particles on impact)
	- All effects are client-side only (cosmetic)

	POOLING CHANGES vs. original:
	  BEFORE: Every shot created 1 MuzzleFlash + 1 Tracer + 4 HitSpark balls + 1 HitFlash ball
	          = 7 Instance.new("Part") calls per shot + 7 Debris:AddItem GC cycles.
	          At Scrapper's 8 shots/s: 56 Part allocs/s + 56 GC frees/s = constant GC churn.

	  AFTER:  All 7 Part types are fetched from VFXPool. Zero allocation on the hot path.
	          GC only touches the PointLight on MuzzleFlash (created fresh, ~0.1 µs; not
	          worth pooling a light since it has no physics/render entry).

	  PointLight strategy: Created fresh per shot and Debris:AddItem'd. PointLights are
	  Lua-side only (no C++ physics solver or broadphase entry), so their GC cost is
	  ~10× lower than a BasePart. Pooling them would save ~0.2 µs at the cost of
	  significant code complexity. Not worth it.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _ = require(ReplicatedStorage.Shared.Config.ClassConfig) -- reserved for future per-class VFX
local VFXPool = require(script.Parent.VFXPool)

local ProjectileEffects = {}
ProjectileEffects.Name = "ProjectileEffects"

-- ── Default Config ────────────────────────────────────────────────────────────

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

-- ── Pre-baked TweenInfos ──────────────────────────────────────────────────────

-- Allocating TweenInfo at module load time rather than per-call saves a small
-- allocation on every shot. TweenInfo is immutable; safe to share.
local FLASH_TWEEN_INFO = TweenInfo.new(DEFAULT_CONFIG.MuzzleFlashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TRACER_TWEEN_INFO_DEFAULT = TweenInfo.new(DEFAULT_CONFIG.TracerLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SPARK_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIT_FLASH_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad)

-- ── VFX Folder ────────────────────────────────────────────────────────────────

local vfxFolder: Folder? = nil

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

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getConfigValue(cfg: any?, key: string): any
	if cfg and cfg[key] ~= nil then
		return cfg[key]
	end
	return DEFAULT_CONFIG[key]
end

-- ── Public: SpawnMuzzleFlash ──────────────────────────────────────────────────

--[[
	SpawnMuzzleFlash(position, direction, config?)

	POOLING: Flash Part fetched from "MuzzleFlash" pool.
	PointLight created fresh (0.1 µs; cheaper than pool overhead for lights).
	Return: ReturnPartDelayed after MuzzleFlashDuration + buffer.
]]
function ProjectileEffects:SpawnMuzzleFlash(position: Vector3, direction: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not getConfigValue(cfg, "MuzzleFlashEnabled") then
		return
	end

	local flashColor = getConfigValue(cfg, "MuzzleFlashColor")
	local flashSize = getConfigValue(cfg, "MuzzleFlashSize")
	local flashDuration = getConfigValue(cfg, "MuzzleFlashDuration")

	-- Fetch from pool (no Instance.new allocation).
	local flash = VFXPool:GetPart("MuzzleFlash")
	flash.Color = flashColor
	flash.Size = Vector3.new(flashSize, flashSize, flashSize)
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.3
	flash.Parent = getVFXFolder()

	-- PointLight: created fresh. No pool — lights are dirt cheap.
	local light = Instance.new("PointLight")
	light.Color = flashColor
	light.Brightness = 3
	light.Range = 8
	light.Parent = flash -- child of the pooled part; destroyed by Debris, NOT by ReturnPart

	local tweenInfo = TweenInfo.new(flashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(flash, tweenInfo, {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1),
	}):Play()

	TweenService:Create(light, tweenInfo, { Brightness = 0 }):Play()

	-- CRITICAL: Destroy the PointLight child BEFORE returning the part.
	-- Otherwise the next caller gets a part with a stale PointLight child.
	-- We schedule destruction slightly before the pool return.
	local returnDelay = flashDuration + 0.08
	Debris:AddItem(light, returnDelay - 0.01) -- light dies just before part returns
	VFXPool:ReturnPartDelayed("MuzzleFlash", flash, returnDelay)
end

-- ── Public: SpawnTracer ───────────────────────────────────────────────────────

--[[
	SpawnTracer(startPos, endPos, config?)

	POOLING: Tracer Part fetched from "Tracer" pool.
	Size.Z is set to the bullet travel distance; CFrame faces the hit point.
	Return: ReturnPartDelayed after TracerLifetime + buffer.
]]
function ProjectileEffects:SpawnTracer(startPos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not getConfigValue(cfg, "TracerEnabled") then
		return
	end

	local diff = endPos - startPos
	local distance = diff.Magnitude
	if distance < 0.01 then
		return
	end

	local midPoint = (startPos + endPos) / 2
	local tracerColor = getConfigValue(cfg, "TracerColor")
	local width = getConfigValue(cfg, "TracerWidth")
	local lifetime = getConfigValue(cfg, "TracerLifetime")

	local tracer = VFXPool:GetPart("Tracer")
	tracer.Color = tracerColor
	tracer.Size = Vector3.new(width, width, distance)
	tracer.CFrame = CFrame.lookAt(midPoint, endPos)
	tracer.Transparency = 0
	tracer.Parent = getVFXFolder()

	local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(tracer, tweenInfo, {
		Transparency = 1,
		Size = Vector3.new(0.02, 0.02, distance),
	}):Play()

	VFXPool:ReturnPartDelayed("Tracer", tracer, lifetime + 0.08)
end

-- ── Public: SpawnHitSparks ────────────────────────────────────────────────────

--[[
	SpawnHitSparks(hitPosition, hitNormal?, config?)

	POOLING:
	  • HitSpark balls → "HitSpark" pool (uses physics; see physics sequence).
	  • HitFlash ball  → "HitFlash" pool.

	PHYSICS SEQUENCE for each spark (required for all pool parts that use physics):
	  1. VFXPool:GetPart("HitSpark") → part is Anchored = true
	  2. part.CFrame = CFrame.new(hitPosition) → teleport while anchored
	  3. part.Anchored = false → release to physics solver
	  4. part.AssemblyLinearVelocity = vel → apply launch velocity

	ReturnPartDelayed handles re-anchoring + zeroing velocity automatically.
]]
function ProjectileEffects:SpawnHitSparks(hitPosition: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG
	if not getConfigValue(cfg, "HitSparkEnabled") then
		return
	end

	local sparkCount = getConfigValue(cfg, "HitSparkCount")
	local sparkColor = getConfigValue(cfg, "HitSparkColor")

	-- ── Physics sparks ────────────────────────────────────────────────
	for _ = 1, sparkCount do
		local spark = VFXPool:GetPart("HitSpark")
		spark.Color = sparkColor
		spark.Size = Vector3.new(0.1, 0.1, 0.1)
		spark.Transparency = 0.3

		-- Step 2: Teleport while anchored.
		spark.CFrame = CFrame.new(hitPosition)

		-- Step 3: Release to physics.
		spark.Anchored = false
		spark.CanCollide = false

		-- Random outward + upward velocity.
		local randomDir = Vector3.new(
			math.random() - 0.5,
			math.random() * 0.5 + 0.2,
			math.random() - 0.5
		).Unit
		if hitNormal then
			randomDir = (randomDir + hitNormal).Unit
		end

		-- Step 4: Apply velocity.
		local speed = math.random(15, 30)
		spark.AssemblyLinearVelocity = randomDir * speed

		spark.Parent = getVFXFolder()

		-- Tween to invisible while physics still runs (no conflict — tweening
		-- Transparency doesn't affect physics state).
		local lifetime = 0.15 + math.random() * 0.1
		TweenService:Create(spark, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
			Size = Vector3.new(0.02, 0.02, 0.02),
		}):Play()

		-- ObjectPool.ReturnPart will set Anchored=true + zero velocity.
		VFXPool:ReturnPartDelayed("HitSpark", spark, lifetime + 0.1)
	end

	-- ── Hit flash ─────────────────────────────────────────────────────
	local flash = VFXPool:GetPart("HitFlash")
	flash.Color = sparkColor
	flash.Size = Vector3.new(0.8, 0.8, 0.8)
	flash.Transparency = 0.4
	flash.CFrame = CFrame.new(hitPosition)
	flash.Parent = getVFXFolder()

	TweenService:Create(flash, HIT_FLASH_TWEEN_INFO, {
		Transparency = 1,
		Size = Vector3.new(0.1, 0.1, 0.1),
	}):Play()

	VFXPool:ReturnPartDelayed("HitFlash", flash, 0.18)
end

-- ── Public: PlayRangedHitEffects ──────────────────────────────────────────────

function ProjectileEffects:PlayRangedHitEffects(muzzlePos: Vector3, hitPos: Vector3, hitNormal: Vector3?, config: any?)
	local cfg = config or DEFAULT_CONFIG
	local diff = hitPos - muzzlePos
	if diff.Magnitude < 0.01 then
		return
	end
	local direction = diff.Unit

	self:SpawnMuzzleFlash(muzzlePos, direction, cfg)
	self:SpawnTracer(muzzlePos, hitPos, cfg)
	self:SpawnHitSparks(hitPos, hitNormal, cfg)
end

-- ── Public: PlayRangedMissEffects ─────────────────────────────────────────────

function ProjectileEffects:PlayRangedMissEffects(muzzlePos: Vector3, endPos: Vector3, config: any?)
	local cfg = config or DEFAULT_CONFIG
	local diff = endPos - muzzlePos
	if diff.Magnitude < 0.01 then
		return
	end
	local direction = diff.Unit

	self:SpawnMuzzleFlash(muzzlePos, direction, cfg)
	self:SpawnTracer(muzzlePos, endPos, cfg)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function ProjectileEffects:Init()
	print("[ProjectileEffects] Initialized")
end

function ProjectileEffects:Start()
	print("[ProjectileEffects] Started")
end

return ProjectileEffects
