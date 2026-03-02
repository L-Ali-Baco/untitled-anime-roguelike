--!strict
--[[
	EnemyVFXController.luau
	=======================
	Client-side VFX for enemy attacks.

	Currently handles:
	  • ToxicBlobImpact — plays a pooled splash burst when a ToxicBlob lands.

	─────────────────────────────────────────────────────────────────────────────
	STUDIO SETUP GUIDE — ToxicBlob Visual Template
	─────────────────────────────────────────────────────────────────────────────

	The blob Part itself replicates from the server automatically — you can see
	it in the workspace as a Neon green sphere while it flies. To make it look
	stylised and liquid-like, add child instances to the template Part stored at:

	  ReplicatedStorage → Shared → Assets → Projectiles → ToxicBlob

	(If that path doesn't exist yet, create it — see ToxicBlobService comments.)

	1.  TRAIL (child of ToxicBlob Part)
	    ──────────────────────────────
	    a. Insert two Attachments into ToxicBlob:
	         "FrontAttach"  →  Position: (0, 0, -0.7)   ← tip of the sphere
	         "RearAttach"   →  Position: (0, 0,  0.7)   ← back of the sphere
	    b. Insert a Trail into ToxicBlob:
	         Trail.Attachment0  = FrontAttach
	         Trail.Attachment1  = RearAttach
	         Trail.Lifetime     = 0.2
	         Trail.MinDistance  = 0.04
	         Trail.WidthScale   = NumberSequence:  (0, 1) → (1, 0.3)
	         Trail.Transparency = NumberSequence:  (0, 0) → (1, 1)
	         Trail.Color        = ColorSequence:
	                               Keypoint 0 → Color3.fromRGB(160, 255, 60)
	                               Keypoint 1 → Color3.fromRGB(40,  120,  0)
	    c. Tip: enable Trail.FaceCamera = false for a flat ribbon look.

	2.  PARTICLE EMITTER (child of ToxicBlob Part)
	    ───────────────────────────────────────────
	    Insert a ParticleEmitter into ToxicBlob:
	      Enabled         = true
	      Rate            = 25
	      Lifetime        = NumberRange (0.1, 0.25)
	      Speed           = NumberRange (0,   2)
	      SpreadAngle     = (180, 180)        ← emit in all directions
	      Rotation        = NumberRange (-180, 180)
	      RotSpeed        = NumberRange (-120, 120)
	      LightEmission   = 0.8
	      LightInfluence  = 0.2
	      Color           = ColorSequence:
	                          Keypoint 0 → RGB(120, 255, 30)
	                          Keypoint 1 → RGB(30,  80,   0)
	      Transparency    = NumberSequence: (0, 0.2) → (1, 1)
	      Size            = NumberSequence: (0, 0.35) → (1, 0)
	    Add a Drag modifier (child of the ParticleEmitter):
	      Drag = 4     ← particles decelerate quickly, giving a "splatter" feel

	3.  BLOB MATERIAL NOTES
	    ────────────────────
	    Material = Neon   → glows without any PointLight, cheap.
	    CastShadow = false
	    Consider adding a very dim PointLight (Brightness 0.3, Range 8,
	    Color: lime green) for subtle ground illumination while flying.

	─────────────────────────────────────────────────────────────────────────────
	STUDIO SETUP GUIDE — ImpactSplash Pool Template
	─────────────────────────────────────────────────────────────────────────────

	The splash is made from pooled Neon spheres that scale up and fade out.
	This controller builds its own procedural template (no Studio setup needed),
	but you can override it via:

	  ReplicatedStorage → Shared → Assets → VFX → ToxicSplash   (a Part)

	Recommended custom template properties:
	  Shape       = Ball
	  Size        = (0.5, 0.5, 0.5)   ← TweenService scales it up to 5 studs
	  Material    = Neon
	  Color       = RGB(80, 230, 30)
	  Transparency = 0.2
	  CastShadow  = false

	Add a ParticleEmitter child with:
	  Rate        = 0          ← only emit on :Emit() call, not continuously
	  Lifetime    = NumberRange(0.3, 0.6)
	  Speed       = NumberRange(3, 8)
	  Rotation    = NumberRange(-180, 180)
	  SpreadAngle = (60, 60)
	  Color       = ColorSequence: RGB(100,255,40) → RGB(20,80,0)
	  Size        = NumberSequence: (0, 0.4) → (1, 0)
	  LightEmission = 1.0
	  Drag modifier: 6

	During splash (see _playSplash below), call emitter:Emit(12) once.

	─────────────────────────────────────────────────────────────────────────────
	STUDIO SETUP GUIDE — BogShambler Mud Slam (BogSlamImpact)
	─────────────────────────────────────────────────────────────────────────────

	The Mud Slam uses two pooled visual systems: a brown debris burst and a flat
	shockwave ring. Both have procedural fallbacks so no Studio work is required
	to get the effect running. For a higher-fidelity version:

	1.  MUD SHARD TEMPLATE  (optional override)
	    ──────────────────────────────────────────
	    Path: ReplicatedStorage → Shared → Assets → VFX → MudShard   (a Part)
	    Recommended properties:
	      Shape       = Ball
	      Size        = (0.4, 0.4, 0.4)
	      Material    = SmoothPlastic   ← dirt looks better non-Neon
	      Color       = RGB(90, 55, 15)
	      Transparency = 0.1
	      CastShadow  = false
	    Add a ParticleEmitter child:
	      Rate        = 0          ← burst-only via :Emit()
	      Lifetime    = NumberRange(0.2, 0.5)
	      Speed       = NumberRange(2, 5)
	      SpreadAngle = (90, 90)
	      Rotation    = NumberRange(-180, 180)
	      Color       = ColorSequence: RGB(100,70,20) → RGB(50,30,5)
	      Size        = NumberSequence: (0, 0.5) → (1, 0)
	      Drag modifier: 5

	2.  MUD SHOCKWAVE RING  (optional override)
	    ─────────────────────────────────────────
	    This controller builds the ring procedurally. If you want a custom
	    decal (e.g. a cracked-ground texture), parent a Cylinder Part named
	    "MudRing" under ReplicatedStorage → Shared → Assets → VFX and set:
	      Shape = Cylinder
	      Size  = (0.12, 0.1, 0.1)   ← starts tiny; tween scales it to 12 studs
	      Material = SmoothPlastic
	      Color = RGB(60, 40, 10)
	      Transparency = 0.25
	      CanCollide = false
	    Add a SurfaceAppearance child and apply a cracked-earth texture if
	    desired. The controller expands and fades it identically either way.

	─────────────────────────────────────────────────────────────────────────────
	STUDIO SETUP GUIDE — Puddle Glow Ring (optional enhancement)
	─────────────────────────────────────────────────────────────────────────────

	The puddle Part itself is visible through normal replication (Neon cylinder).
	For an extra visual punch, add a brief glow ring that pulses when the puddle
	first forms — using a separate "ToxicRing" template in the same Assets/VFX
	folder. Properties:
	  Shape = Cylinder (flat, Size = 0.15 × 9 × 9), rotated 90° on Z.
	  Material = Neon, Color = RGB(60, 200, 10), Transparency = 0.6.
	  Tween: Size from (0.15,0,0) to (0.15,9,9) over 0.25 s (Elastic out).
	  Then Transparency tween from 0.6 to 1 over 0.5 s.
	This controller currently plays a simple sphere pulse instead; swap it out
	once you have the ToxicRing asset ready.
]]

-- ── Services ───────────────────────────────────────────────────────────────────

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Module ────────────────────────────────────────────────────────────────────

local EnemyVFXController = {}
EnemyVFXController.Name = "EnemyVFXController"

-- ── Shared ────────────────────────────────────────────────────────────────────

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

-- ── Constants ──────────────────────────────────────────────────────────────────

-- Number of sphere shards spawned per splash.
local SPLASH_SHARDS: number = 8

-- How large each shard grows at the peak of the burst (studs).
local SHARD_PEAK_SIZE: number = 4.5

-- How long each shard takes to expand.
local SHARD_GROW_TIME: number = 0.18

-- How long each shard fades after reaching peak.
local SHARD_FADE_TIME: number = 0.28

-- Colour for splash shards.
local SHARD_COLOR: Color3 = Color3.fromRGB(80, 230, 30)

-- Puddle glow ring pulse duration.
local RING_PULSE_TIME: number = 0.3

-- ── Hex-Beam VFX constants ─────────────────────────────────────────────────────
-- Must match BEAM_LENGTH, BEAM_WIDTH, BEAM_WINDUP in HexCaster.luau.

-- Length of the warning box / beam cylinder (studs).
local BEAM_VFX_LENGTH: number = 60

-- Width of the warning box and final expanded radius of the beam (studs).
local BEAM_VFX_WIDTH: number = 5

-- How long the telegraph box fades in (matches the server-side BEAM_WINDUP).
local BEAM_VFX_WINDUP: number = 0.88

-- How long the beam flash expands and fades after firing.
local BEAM_VFX_FIRE_DURATION: number = 0.4

-- Colour shown during wind-up telegraph (neon lime → danger is clear).
local TELEGRAPH_COLOR: Color3 = Color3.fromRGB(80, 255, 40)

-- Colour of the beam flash at the moment of firing.
local BEAM_FLASH_COLOR: Color3 = Color3.fromRGB(200, 255, 120)

-- Screen-shake magnitude (studs of camera offset per frame at peak).
local SHAKE_MAGNITUDE: number = 0.35

-- ── Mud Slam VFX constants (BogSlamImpact) ────────────────────────────────────

-- Number of dirt/mud shards spawned per slam.
local MUD_SHARDS: number = 14

-- How large each shard grows at peak (studs). Smaller than toxic splash — dirt clods.
local MUD_SHARD_PEAK_SIZE: number = 3.0

-- Grow and fade timing for each shard.
local MUD_SHARD_GROW_TIME: number = 0.14
local MUD_SHARD_FADE_TIME: number = 0.30

-- Colour for mud shards (dark earth brown).
local MUD_SHARD_COLOR: Color3 = Color3.fromRGB(90, 55, 15)

-- Final radius of the expanding shockwave ring (studs).
local MUD_RING_RADIUS: number = 12

-- How long the ring takes to expand to full size.
local MUD_RING_EXPAND_TIME: number = 0.3

-- Total time before the ring is fully faded out.
local MUD_RING_FADE_TIME: number = 0.5

-- Colour of the shockwave ring (slightly lighter than shard colour).
local MUD_RING_COLOR: Color3 = Color3.fromRGB(70, 48, 14)

-- Camera shake magnitude for the mud slam (heavier than the hex beam).
local MUD_SHAKE_MAGNITUDE: number = 0.5

-- How long the mud slam shake lasts.
local MUD_SHAKE_DURATION: number = 0.3

-- ── State ─────────────────────────────────────────────────────────────────────

-- Pool of sphere parts used for impact shards (toxic splash).
-- Built lazily on first impact to avoid allocating memory if no HexCaster spawns.
local _shardPool: { BasePart } = {}
local _shardTemplate: BasePart

-- Pool of sphere parts used for mud slam debris (BogShambler headbutt).
local _mudPool: { BasePart } = {}
local _mudTemplate: BasePart

-- Pool of flat Neon cylinder parts used for the mud shockwave ring.
local _ringPool: { BasePart } = {}
local _ringTemplate: BasePart

-- Pool of Parts with a burst ParticleEmitter (MudSplash).
local _mudSplashPool: { BasePart } = {}
local _mudSplashTemplate: BasePart

-- ── Private: Template ─────────────────────────────────────────────────────────

local function getShardTemplate(): BasePart
	-- Check for custom Studio asset first.
	local assets = Shared:FindFirstChild("Assets")
	if assets then
		local vfx = assets:FindFirstChild("VFX")
		if vfx then
			local custom = vfx:FindFirstChild("ToxicSplash")
			if custom and custom:IsA("BasePart") then
				return custom
			end
		end
	end

	-- Procedural fallback.
	local t = Instance.new("Part")
	t.Name = "ToxicSplash"
	t.Shape = Enum.PartType.Ball
	t.Size = Vector3.one * 0.5
	t.Color = SHARD_COLOR
	t.Material = Enum.Material.Neon
	t.CastShadow = false
	t.Anchored = true
	t.CanCollide = false
	t.CanTouch = false
	t.Transparency = 1
	t.Parent = workspace -- must have a parent; pool will reparent during use
	return t
end

-- ── Private: Shard Pool ────────────────────────────────────────────────────────

local function getShard(): BasePart
	if #_shardPool > 0 then
		return table.remove(_shardPool) :: BasePart
	end
	-- First use: initialise template then clone.
	if not _shardTemplate then
		_shardTemplate = getShardTemplate()
	end
	local s = _shardTemplate:Clone()
	s.Parent = workspace
	return s
end

local function returnShard(shard: BasePart)
	shard.Transparency = 1
	shard.Size = Vector3.one * 0.5
	shard.CFrame = CFrame.new(0, -10000, 0)
	table.insert(_shardPool, shard)
end

-- ── Private: Mud Shard Pool ───────────────────────────────────────────────────

local function getMudShardTemplate(): BasePart
	-- Check for custom Studio asset first.
	local assets = Shared:FindFirstChild("Assets")
	if assets then
		local vfx = assets:FindFirstChild("VFX")
		if vfx then
			local custom = vfx:FindFirstChild("MudShard")
			if custom and custom:IsA("BasePart") then
				return custom
			end
		end
	end

	-- Procedural fallback.
	local t = Instance.new("Part")
	t.Name = "MudShard"
	t.Shape = Enum.PartType.Ball
	t.Size = Vector3.one * 0.4
	t.Color = MUD_SHARD_COLOR
	t.Material = Enum.Material.Neon -- Neon ensures visibility regardless of lighting
	t.CastShadow = false
	t.Anchored = true
	t.CanCollide = false
	t.CanTouch = false
	t.Transparency = 1
	t.Parent = workspace
	return t
end

local function getMudShard(): BasePart
	if #_mudPool > 0 then
		return table.remove(_mudPool) :: BasePart
	end
	if not _mudTemplate then
		_mudTemplate = getMudShardTemplate()
	end
	local s = _mudTemplate:Clone()
	s.Parent = workspace
	return s
end

local function returnMudShard(shard: BasePart)
	shard.Transparency = 1
	shard.Size = Vector3.one * 0.4
	shard.CFrame = CFrame.new(0, -10000, 0)
	table.insert(_mudPool, shard)
end

-- ── Private: Impact Ring Pool ─────────────────────────────────────────────────

local function getMudRingTemplate(): BasePart
	-- Check for custom Studio asset: ReplicatedStorage → Shared → Assets → VFX → MudRing
	local assets = Shared:FindFirstChild("Assets")
	if assets then
		local vfx = assets:FindFirstChild("VFX")
		if vfx then
			local custom = vfx:FindFirstChild("MudRing")
			if custom and custom:IsA("BasePart") then
				return custom
			end
		end
	end
	-- Procedural flat Neon cylinder — rings rotate 90° on Z so height runs along Y.
	local t = Instance.new("Part")
	t.Name = "MudImpactRing"
	t.Shape = Enum.PartType.Cylinder
	t.Size = Vector3.new(0.12, 0.2, 0.2)
	t.Color = MUD_RING_COLOR
	t.Material = Enum.Material.Neon
	t.CastShadow = false
	t.Anchored = true
	t.CanCollide = false
	t.CanTouch = false
	t.Transparency = 1
	t.Parent = workspace
	return t
end

local function getMudRing(): BasePart
	if #_ringPool > 0 then
		return table.remove(_ringPool) :: BasePart
	end
	if not _ringTemplate then
		_ringTemplate = getMudRingTemplate()
	end
	local r = _ringTemplate:Clone()
	r.Parent = workspace
	return r
end

local function returnMudRing(ring: BasePart)
	ring.Transparency = 1
	ring.Size = Vector3.new(0.12, 0.2, 0.2)
	ring.CFrame = CFrame.new(0, -10000, 0)
	table.insert(_ringPool, ring)
end

-- ── Private: MudSplash Pool (ParticleEmitter burst) ───────────────────────────

local function getMudSplashTemplate(): BasePart
	-- Check for custom Studio asset: ReplicatedStorage → Shared → Assets → VFX → MudSplash
	local assets = Shared:FindFirstChild("Assets")
	if assets then
		local vfx = assets:FindFirstChild("VFX")
		if vfx then
			local custom = vfx:FindFirstChild("MudSplash")
			if custom and custom:IsA("BasePart") then
				return custom
			end
		end
	end
	-- Procedural: invisible anchor part + burst-only ParticleEmitter child.
	local t = Instance.new("Part")
	t.Name = "MudSplash"
	t.Size = Vector3.one * 0.5
	t.Color = MUD_SHARD_COLOR
	t.Material = Enum.Material.SmoothPlastic
	t.CastShadow = false
	t.Anchored = true
	t.CanCollide = false
	t.CanTouch = false
	t.Transparency = 1

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "MudEmitter"
	emitter.Rate = 0 -- burst-only via :Emit()
	emitter.Lifetime = NumberRange.new(0.35, 0.75)
	emitter.Speed = NumberRange.new(5, 14)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Rotation = NumberRange.new(-180, 180)
	emitter.LightEmission = 0.5
	emitter.LightInfluence = 0.5
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 75, 20)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(55, 30, 5)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Parent = t
	t.Parent = workspace
	return t
end

local function getMudSplash(): BasePart
	if #_mudSplashPool > 0 then
		return table.remove(_mudSplashPool) :: BasePart
	end
	if not _mudSplashTemplate then
		_mudSplashTemplate = getMudSplashTemplate()
	end
	local s = _mudSplashTemplate:Clone()
	s.Parent = workspace
	return s
end

local function returnMudSplash(splash: BasePart)
	splash.Transparency = 1
	splash.CFrame = CFrame.new(0, -10000, 0)
	table.insert(_mudSplashPool, splash)
end

-- ── Private: Splash Burst ─────────────────────────────────────────────────────

--[[
	Plays a radial burst of SPLASH_SHARDS Neon spheres at `hitPos`.
	Each shard:
	  1. Spawns at hitPos + small random XZ offset.
	  2. Tweens Size from tiny → SHARD_PEAK_SIZE.
	  3. Tweens Transparency from 0 → 1 simultaneously.
	  4. Returns to pool after the fade completes.

	Shards are staggered by 0–30 ms so the burst feels organic, not uniform.
]]
local function playSplash(hitPos: Vector3, isGroundHit: boolean)
	local baseY = hitPos.Y

	for i = 1, SPLASH_SHARDS do
		local shard = getShard()

		-- Random position within a disc around the impact point.
		local angle = math.random() * math.pi * 2
		local radius = math.random() * 1.8
		local offsetX = math.cos(angle) * radius
		local offsetZ = math.sin(angle) * radius
		-- Ground hits spread flat; air hits spread slightly upward.
		local offsetY = if isGroundHit then math.random() * 0.4 else math.random() * 1.2

		shard.CFrame = CFrame.new(hitPos.X + offsetX, baseY + offsetY, hitPos.Z + offsetZ)
		shard.Size = Vector3.one * (0.2 + math.random() * 0.3)
		shard.Transparency = 0.1
		shard.Color = SHARD_COLOR

		-- Stagger each shard by up to 0.03 s for an organic burst rhythm.
		local stagger = (i - 1) * 0.03

		task.delay(stagger, function()
			if not shard.Parent then
				return
			end

			-- Grow phase.
			local peakSize = Vector3.one * (SHARD_PEAK_SIZE * (0.4 + math.random() * 0.6))
			TweenService
				:Create(shard, TweenInfo.new(SHARD_GROW_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = peakSize,
				})
				:Play()

			-- Fade phase starts immediately alongside grow.
			local fadeTween = TweenService:Create(
				shard,
				TweenInfo.new(SHARD_GROW_TIME + SHARD_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			fadeTween:Play()
			fadeTween.Completed:Once(function()
				returnShard(shard)
			end)
		end)
	end

	-- Puddle glow ring pulse (ground hits only): a flat ring that expands and fades.
	if isGroundHit then
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.12, 0.1, 0.1)
		ring.Color = Color3.fromRGB(50, 200, 10)
		ring.Material = Enum.Material.Neon
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Transparency = 0.3
		ring.CFrame = CFrame.new(hitPos.X, hitPos.Y + 0.1, hitPos.Z) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace

		local expandTween = TweenService:Create(
			ring,
			TweenInfo.new(RING_PULSE_TIME, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.12, 9, 9) }
		)
		local fadeTween = TweenService:Create(
			ring,
			TweenInfo.new(RING_PULSE_TIME * 1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		expandTween:Play()
		fadeTween:Play()
		fadeTween.Completed:Once(function()
			ring:Destroy()
		end)
	end
end

-- ── Private: Hex-Beam Telegraph ──────────────────────────────────────────────

--[[
	Displays a flat neon-green warning box on the ground for BEAM_VFX_WINDUP seconds,
	showing the player exactly which corridor the beam will sweep through.

	casterCF — the HexCaster's HRP CFrame captured at the start of the wind-up.
	           We strip its pitch/roll so the box lies perfectly flat.
]]
local function playBeamTelegraph(casterCF: CFrame)
	local halfLen = BEAM_VFX_LENGTH / 2

	-- Build a flat horizontal CFrame at the caster's world position.
	-- Only the horizontal look direction is kept; pitch/roll are discarded so
	-- the box hugs the ground regardless of terrain slope.
	local origin = casterCF.Position
	local lookFlat = Vector3.new(casterCF.LookVector.X, 0, casterCF.LookVector.Z)
	if lookFlat.Magnitude < 0.01 then
		lookFlat = Vector3.new(0, 0, -1) -- fallback if caster is looking straight up
	end
	lookFlat = lookFlat.Unit
	local flatCF = CFrame.lookAt(origin, origin + lookFlat)

	local box = Instance.new("Part")
	box.Name = "HexBeamTelegraph"
	box.Shape = Enum.PartType.Block
	-- Thin flat slab: width × thin-height × length
	box.Size = Vector3.new(BEAM_VFX_WIDTH, 0.15, BEAM_VFX_LENGTH)
	box.Color = TELEGRAPH_COLOR
	box.Material = Enum.Material.Neon
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = false
	box.CastShadow = false
	box.Transparency = 1 -- starts invisible; tweens visible below
	-- Centre the box halfLen studs in front of the caster (-Z = forward in Roblox).
	box.CFrame = flatCF * CFrame.new(0, 0, -halfLen)
	box.Parent = workspace

	-- Fade in over the wind-up window — the build-up tension tells the player to dodge.
	TweenService:Create(
		box,
		TweenInfo.new(BEAM_VFX_WINDUP, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 0.2 }
	):Play()

	-- Auto-destroy at the exact moment the beam fires.
	task.delay(BEAM_VFX_WINDUP, function()
		if box.Parent then
			box:Destroy()
		end
	end)
end

-- ── Private: Hex-Beam Fire Flash ─────────────────────────────────────────────

--[[
	Plays the violent beam-release effect:
	  • A neon cylinder that starts thin and expands radially while fading out.
	  • A short screen shake that decays over the fire duration.

	casterCF — the HexCaster's HRP CFrame at the moment of firing (same locked
	           orientation that was sent with the telegraph).
]]
local function playBeamFire(casterCF: CFrame)
	local halfLen = BEAM_VFX_LENGTH / 2

	-- ── Cylinder flash ────────────────────────────────────────────────────
	-- Default Roblox cylinder height runs along +Y. We want height along the
	-- caster's forward direction (= -Z of casterCF). Rotating -90° around the
	-- local X axis maps the cylinder's +Y to local -Z = casterCF.LookVector.
	-- If the beam appears to point backward in-game, flip the sign to +90°.
	local beamPart = Instance.new("Part")
	beamPart.Name = "HexBeamFlash"
	beamPart.Shape = Enum.PartType.Cylinder
	beamPart.Size = Vector3.new(1, BEAM_VFX_LENGTH, 1) -- start thin; tween expands radius
	beamPart.Color = BEAM_FLASH_COLOR
	beamPart.Material = Enum.Material.Neon
	beamPart.Anchored = true
	beamPart.CanCollide = false
	beamPart.CanTouch = false
	beamPart.CastShadow = false
	beamPart.Transparency = 0
	beamPart.CFrame = casterCF
		* CFrame.new(0, 0, -halfLen) -- shift centre forward
		* CFrame.Angles(-math.rad(90), 0, 0) -- tilt cylinder to lie along forward axis
	beamPart.Parent = workspace

	-- Expand radially while fading — gives a "release burst" silhouette.
	TweenService:Create(
		beamPart,
		TweenInfo.new(BEAM_VFX_FIRE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(BEAM_VFX_WIDTH, BEAM_VFX_LENGTH, BEAM_VFX_WIDTH),
			Transparency = 1,
		}
	):Play()

	task.delay(BEAM_VFX_FIRE_DURATION, function()
		if beamPart.Parent then
			beamPart:Destroy()
		end
	end)

	-- ── Screen shake ──────────────────────────────────────────────────────
	-- Applies small random camera offsets each RenderStepped frame, decaying
	-- to zero over BEAM_VFX_FIRE_DURATION. Works with the default camera controller
	-- because the offsets are small enough that the controller corrects them
	-- between frames, producing a visible tremor without permanently drifting.
	local camera = workspace.CurrentCamera
	if camera then
		local elapsed = 0
		local shakeConn: RBXScriptConnection
		shakeConn = RunService.RenderStepped:Connect(function(dt: number)
			elapsed += dt
			if elapsed >= BEAM_VFX_FIRE_DURATION then
				shakeConn:Disconnect()
				return
			end
			local decay = 1 - (elapsed / BEAM_VFX_FIRE_DURATION)
			local offset = Vector3.new(
				(math.random() - 0.5) * 2 * SHAKE_MAGNITUDE * decay,
				(math.random() - 0.5) * 2 * SHAKE_MAGNITUDE * decay,
				0
			)
			camera.CFrame = camera.CFrame * CFrame.new(offset)
		end)
	end
end

-- ── Private: Mud Slam ────────────────────────────────────────────────────────

--[[
	Plays the BogShambler headbutt impact effect at `impactPos`:
	  1. A burst of MUD_SHARDS dirt clods that fly upward and outward.
	  2. A flat shockwave ring that expands to MUD_RING_RADIUS studs and fades.
	  3. A brief heavy camera shake (MUD_SHAKE_MAGNITUDE, MUD_SHAKE_DURATION).

	Called by EnemyVFXController:Start() when BogSlamImpact fires.
	impactPos — the world position 3 studs in front of the HRP at ground level,
	             sent by BogShambler:_doHeadbuttAttack at the exact hitstop frame.
]]
local function playMudSlam(impactPos: Vector3)
	-- ── 1. MudSplash — pooled ParticleEmitter burst ───────────────────────
	-- One invisible anchor part placed at the impact point; :Emit(20) fires
	-- all particles at once then the part goes back to the pool.
	local splash = getMudSplash()
	splash.CFrame = CFrame.new(impactPos)
	splash.Transparency = 1

	local emitter = splash:FindFirstChildOfClass("ParticleEmitter")
	if emitter then
		emitter:Emit(20)
	end

	-- Return to pool after the longest possible particle lifetime.
	task.delay(0.75 + 0.1, function()
		returnMudSplash(splash)
	end)

	-- ── 2. ImpactRing — pooled flat Neon cylinder ─────────────────────────
	-- Ground-snap raycast so the ring sits flush even on uneven terrain.
	local groundY = impactPos.Y
	local groundRay = workspace:Raycast(
		Vector3.new(impactPos.X, impactPos.Y + 4, impactPos.Z),
		Vector3.new(0, -8, 0)
	)
	if groundRay then
		groundY = groundRay.Position.Y
	end

	local ring = getMudRing()
	ring.Color = MUD_RING_COLOR
	ring.Transparency = 0.15
	ring.Size = Vector3.new(0.12, 0.2, 0.2)
	-- 90° on Z lays the cylinder flat (Roblox cylinder height runs along Y).
	ring.CFrame = CFrame.new(impactPos.X, groundY + 0.07, impactPos.Z)
		* CFrame.Angles(0, 0, math.rad(90))

	local ringDiameter = MUD_RING_RADIUS * 2
	local expandTween = TweenService:Create(
		ring,
		TweenInfo.new(MUD_RING_EXPAND_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.12, ringDiameter, ringDiameter) }
	)
	local fadeTween = TweenService:Create(
		ring,
		TweenInfo.new(MUD_RING_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 }
	)
	expandTween:Play()
	fadeTween:Play()
	fadeTween.Completed:Once(function()
		returnMudRing(ring)
	end)

	-- ── 3. Screen shake ───────────────────────────────────────────────────
	-- Heavy single-strike punch: exponential decay over MUD_SHAKE_DURATION.
	local camera = workspace.CurrentCamera
	if camera then
		local elapsed = 0
		local shakeConn: RBXScriptConnection
		shakeConn = RunService.RenderStepped:Connect(function(dt: number)
			elapsed += dt
			if elapsed >= MUD_SHAKE_DURATION then
				shakeConn:Disconnect()
				return
			end
			local decay = (1 - elapsed / MUD_SHAKE_DURATION) ^ 2
			local offset = Vector3.new(
				(math.random() - 0.5) * 2 * MUD_SHAKE_MAGNITUDE * decay,
				(math.random() - 0.5) * 2 * MUD_SHAKE_MAGNITUDE * decay,
				0
			)
			camera.CFrame = camera.CFrame * CFrame.new(offset)
		end)
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function EnemyVFXController:Init()
	-- Nothing to set up synchronously; shard pool is lazy-initialised.
end

function EnemyVFXController:Start()
	local impactRemote = Remotes:GetEvent("ToxicBlobImpact")
	if impactRemote then
		impactRemote.OnClientEvent:Connect(function(hitPos: Vector3, isGroundHit: boolean)
			playSplash(hitPos, isGroundHit)
		end)
	else
		warn("[EnemyVFXController] ToxicBlobImpact remote not found.")
	end

	local telegraphRemote = Remotes:GetEvent("HexBeamTelegraph")
	if telegraphRemote then
		telegraphRemote.OnClientEvent:Connect(function(casterCF: CFrame)
			playBeamTelegraph(casterCF)
		end)
	else
		warn("[EnemyVFXController] HexBeamTelegraph remote not found.")
	end

	local beamFireRemote = Remotes:GetEvent("HexBeamFire")
	if beamFireRemote then
		beamFireRemote.OnClientEvent:Connect(function(casterCF: CFrame)
			playBeamFire(casterCF)
		end)
	else
		warn("[EnemyVFXController] HexBeamFire remote not found.")
	end

	local slamRemote = Remotes:GetEvent("BogSlamImpact")
	print("[EnemyVFXController] BogSlamImpact remote:", slamRemote ~= nil)
	if slamRemote then
		slamRemote.OnClientEvent:Connect(function(impactPos: Vector3)
			print("[EnemyVFXController] playMudSlam fired at", impactPos)
			playMudSlam(impactPos)
		end)
	else
		warn("[EnemyVFXController] BogSlamImpact remote not found.")
	end
end

-- ── Return ────────────────────────────────────────────────────────────────────

return EnemyVFXController
