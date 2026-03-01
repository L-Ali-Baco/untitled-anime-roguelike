--[[
	IronGripVFX.luau
	Vanguard M2 — Iron Grip (pull) ability — CLIENT-SIDE VFX ONLY.

	STYLE GUIDE: "High-Contrast Anime"
	  • Tethers  → jagged electrical lightning Beam (NOT a smooth rope).
	              High TextureSpeed to look like chaotic ripping energy.
	  • Impacts  → sharp crystalline / diamond-shard bursts (NOT soft blurs).
	              Heavy Drag so they explode outward then hang.
	  • Overall  → aggressive, cel-shaded, tiered colours:
	              hot white/yellow core → vivid magenta mid → dark purple edge.

	═══════════════════════════════════════════════════════════
	ACT 1 — CAST  (fires immediately on ability activation, ~0.1 s)
	  • An instantaneous diamond-shard energy burst at the player's
	    right hand — sells the moment of power discharge.
	  • Three concentric neon rings expand from the player's feet
	    (dark → magenta → hot-core), staggered 0.05 s apart, showing
	    the pull zone and giving the hit a telegraphed "shockwave".

	ACT 2 — TETHER & DRAG  (lasts until enemy arrives or PULL_DURATION)
	  • For every enemy in range a jagged Beam is created between the
	    player's hand and the enemy's torso.
	  • Beam.TextureSpeed = 12 → looks like it's violently ripping.
	  • RunService.RenderStepped keeps both Attachment WorldPositions
	    perfect every single frame; zero lag as enemy moves.
	  • A continuous ember ParticleEmitter sheds sparks from the enemy
	    end while the chain is live.
	  • A PointLight rides the enemy attachment for a magenta glow.

	ACT 3 — IMPACT  (fires the frame the enemy hits ARRIVAL_DIST)
	  • The Beam + Attachments are instantly safeDestroyed.
	  • Primary  → 35-count crystalline shard :Emit() — high speed,
	    high drag, small diamond shapes radiating outward.
	  • Secondary → a two-layer mesh ring (hot-core inner, dark outer)
	    tweens from tiny to full width in ≤0.2 s then fades.
	  • Flash    → a PointLight tweens Brightness → 0 over 0.15 s.
	═══════════════════════════════════════════════════════════

	CLEANUP CONTRACT
	  Every Instance created here is cleaned up by one of:
	    1. Debris:AddItem(inst, lifetime)
	    2. safeDestroy(inst) — called from the RenderStepped closure
	  No Instance is ever orphaned.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")

local IronGripVFX = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- PALETTE
-- ─────────────────────────────────────────────────────────────────────────────

local HOT_CORE = Color3.fromRGB(255, 255, 180) -- brightest: yellow-white centre
local MID_MAGENTA = Color3.fromRGB(255, 40, 200) -- vivid magenta mid-ring / beam core
local VIOLET_MID = Color3.fromRGB(120, 0, 180) -- transitional violet
local EDGE_DARK = Color3.fromRGB(35, 4, 55) -- near-black deep purple, coldest edge

-- Reusable ColorSequences (hot → dark over particle lifetime / beam width)
local ENERGY_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, HOT_CORE),
	ColorSequenceKeypoint.new(0.30, MID_MAGENTA),
	ColorSequenceKeypoint.new(0.65, VIOLET_MID),
	ColorSequenceKeypoint.new(1.00, EDGE_DARK),
})

local EMBER_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 255, 220)),
	ColorSequenceKeypoint.new(0.25, HOT_CORE),
	ColorSequenceKeypoint.new(0.60, MID_MAGENTA),
	ColorSequenceKeypoint.new(1.00, EDGE_DARK),
})

-- ─────────────────────────────────────────────────────────────────────────────
-- TEXTURE ASSETS
-- Textures are white-silhouette sprites; the engine multiplies the
-- ColorSequence at render time → correct tint is always produced.
-- ─────────────────────────────────────────────────────────────────────────────

-- Horizontal jagged-lightning stripe for the Beam tether.
-- High contrast zig-zag hard edges — NOT a smooth gradient.
local TEX_LIGHTNING = "rbxassetid://116444971840186"

-- Sharp crystalline / diamond-shaped shard for burst particles.
-- Used in Act 1 cast burst and Act 3 impact shards.
local TEX_CRYSTAL_SHARD = "rbxassetid://133968093303018"

-- Soft puff used for the secondary smoke billow at impact
local TEX_SMOKE = "rbxassetid://15265626147"

-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTANTS
-- ─────────────────────────────────────────────────────────────────────────────

-- Enemy considered "arrived" when its root is within this many studs of player.
local ARRIVAL_DIST = 5

-- Maximum duration for the tether before it gives up (seconds).
-- Keep in sync with the server's pull duration if that changes.
local PULL_DURATION = 0.7

-- ─────────────────────────────────────────────────────────────────────────────
-- PRIVATE HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

--- Returns the best hand BasePart for the tether origin.
local function findHandPart(char: Model): BasePart
	return (char:FindFirstChild("RightHand") :: BasePart?)
		or (char:FindFirstChild("Right Arm") :: BasePart?)
		or char:FindFirstChild("HumanoidRootPart") :: BasePart
end

--- Nil-safe destroy — no error if the instance is already gone.
local function safeDestroy(inst: Instance?)
	if inst and inst.Parent then
		inst:Destroy()
	end
end

--- Client-side liveness check mirroring EnemyLib:IsAlive.
local function isEnemyAlive(model: Model): boolean
	if not model or not model.Parent then
		return false
	end
	if model:GetAttribute("IsEnemy") then
		local hp = model:GetAttribute("Health") or 0
		return hp > 0 and not model:GetAttribute("IsDead")
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ACT 3 — IMPACT
-- Called the frame the enemy crosses ARRIVAL_DIST.
-- Produces the "crunchy, violent, crystalline" hit the style guide demands.
-- ─────────────────────────────────────────────────────────────────────────────

local function playImpact(impactPos: Vector3)
	-- ── PRIMARY: Two-layer expanding mesh ring ────────────────────────────
	-- Layer 1 — dark outer ring (largest, fades in 0.22 s)
	local ringOuter = Instance.new("Part")
	ringOuter.Name = "IronGrip_RingOuter"
	ringOuter.Anchored = true
	ringOuter.CanCollide = false
	ringOuter.CanQuery = false
	ringOuter.CanTouch = false
	ringOuter.CastShadow = false
	ringOuter.Shape = Enum.PartType.Cylinder
	ringOuter.Material = Enum.Material.Neon
	ringOuter.Color = EDGE_DARK
	ringOuter.Transparency = 0
	ringOuter.Size = Vector3.new(0.4, 1.5, 1.5)
	ringOuter.CFrame = CFrame.new(impactPos - Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ringOuter.Parent = workspace.Terrain

	TweenService:Create(
		ringOuter,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, 26, 26), Transparency = 1 }
	):Play()
	Debris:AddItem(ringOuter, 0.28)

	-- Layer 2 — hot magenta inner ring (slightly smaller, pops 0.03 s later)
	task.delay(0.03, function()
		local ringInner = Instance.new("Part")
		ringInner.Name = "IronGrip_RingInner"
		ringInner.Anchored = true
		ringInner.CanCollide = false
		ringInner.CanQuery = false
		ringInner.CanTouch = false
		ringInner.CastShadow = false
		ringInner.Shape = Enum.PartType.Cylinder
		ringInner.Material = Enum.Material.Neon
		ringInner.Color = MID_MAGENTA
		ringInner.Transparency = 0
		ringInner.Size = Vector3.new(0.3, 1.5, 1.5)
		ringInner.CFrame = CFrame.new(impactPos - Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ringInner.Parent = workspace.Terrain

		TweenService:Create(
			ringInner,
			TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.3, 18, 18), Transparency = 1 }
		):Play()
		Debris:AddItem(ringInner, 0.24)
	end)

	-- Layer 3 — blazing white-core ring (thinnest, fastest — the "tip" of the wave)
	task.delay(0.06, function()
		local ringCore = Instance.new("Part")
		ringCore.Name = "IronGrip_RingCore"
		ringCore.Anchored = true
		ringCore.CanCollide = false
		ringCore.CanQuery = false
		ringCore.CanTouch = false
		ringCore.CastShadow = false
		ringCore.Shape = Enum.PartType.Cylinder
		ringCore.Material = Enum.Material.Neon
		ringCore.Color = HOT_CORE
		ringCore.Transparency = 0
		ringCore.Size = Vector3.new(0.2, 1.5, 1.5)
		ringCore.CFrame = CFrame.new(impactPos - Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ringCore.Parent = workspace.Terrain

		TweenService:Create(
			ringCore,
			TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.2, 12, 12), Transparency = 1 }
		):Play()
		Debris:AddItem(ringCore, 0.18)
	end)

	-- ── SECONDARY: Particle burst attachment ─────────────────────────────
	local impactAtt = Instance.new("Attachment")
	impactAtt.WorldPosition = impactPos
	impactAtt.Parent = workspace.Terrain

	-- ── PRIMARY BURST: 35 sharp crystalline shards ────────────────────────
	-- High speed + heavy Drag = they explode outward quickly then hang.
	-- This is the "crunchy" visual the style guide calls for.
	local shards = Instance.new("ParticleEmitter")
	shards.Texture = TEX_CRYSTAL_SHARD
	shards.Color = ENERGY_COLOR_SEQ
	shards.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	shards.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	shards.Speed = NumberRange.new(30, 75)
	shards.Lifetime = NumberRange.new(0.12, 0.38)
	shards.SpreadAngle = Vector2.new(90, 90)
	shards.LightEmission = 1
	shards.LightInfluence = 0
	shards.Drag = 6 -- hard stop after initial explosion
	shards.Rate = 0 -- burst-only, never continuous
	shards.Rotation = NumberRange.new(0, 360)
	shards.RotSpeed = NumberRange.new(-600, 600)
	shards.Parent = impactAtt
	shards:Emit(35) -- primary burst — all at once

	-- ── SECONDARY BURST: slower ember scatter ─────────────────────────────
	-- Float upward and linger, giving the eye somewhere to rest after the pop.
	local embers = Instance.new("ParticleEmitter")
	embers.Texture = TEX_CRYSTAL_SHARD
	embers.Color = EMBER_COLOR_SEQ
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.14),
		NumberSequenceKeypoint.new(0.4, 0.30),
		NumberSequenceKeypoint.new(1, 0),
	})
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.Speed = NumberRange.new(6, 20)
	embers.Lifetime = NumberRange.new(0.35, 0.65)
	embers.SpreadAngle = Vector2.new(120, 120)
	embers.LightEmission = 1
	embers.LightInfluence = 0
	embers.Drag = 3
	embers.Acceleration = Vector3.new(0, 8, 0) -- float upward
	embers.Rate = 0
	embers.Rotation = NumberRange.new(0, 360)
	embers.RotSpeed = NumberRange.new(-300, 300)
	embers.Parent = impactAtt
	embers:Emit(18)

	-- ── IMPACT FLASH ──────────────────────────────────────────────────────
	-- Instantaneous hot PointLight that decays in 0.15s.
	local flash = Instance.new("PointLight")
	flash.Color = HOT_CORE
	flash.Brightness = 7
	flash.Range = 28
	flash.Parent = impactAtt
	TweenService:Create(flash, TweenInfo.new(0.15), { Brightness = 0 }):Play()

	Debris:AddItem(impactAtt, 0.75)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ACT 2 — TETHER (one per enemy in range)
-- Creates a jagged Beam + two world-space Attachments.
-- RenderStepped keeps them perfectly aligned every frame.
-- Owns its own cleanup — nothing is leaked.
-- ─────────────────────────────────────────────────────────────────────────────

local function spawnTether(root: BasePart, handPart: BasePart, enemyRoot: BasePart)
	-- Two world-space Attachments parented to Terrain so they have no inherent transform.
	local attPlayer = Instance.new("Attachment")
	attPlayer.WorldPosition = handPart.Position + Vector3.new(0, 0.5, 0)
	attPlayer.Parent = workspace.Terrain

	local attEnemy = Instance.new("Attachment")
	attEnemy.WorldPosition = enemyRoot.Position + Vector3.new(0, 1, 0)
	attEnemy.Parent = workspace.Terrain

	-- ── BEAM: jagged lightning tether ────────────────────────────────────
	-- TextureSpeed = 12 → the zig-zag stripes rip across the beam chaotically.
	-- Segments = 20 + FaceCamera = true → the jagged texture always reads clearly.
	local beam = Instance.new("Beam")
	beam.Attachment0 = attPlayer
	beam.Attachment1 = attEnemy
	beam.Width0 = 0.55
	beam.Width1 = 0.22
	beam.Segments = 20 -- more segments = better zig-zag curvature fidelity
	beam.CurveSize0 = 0
	beam.CurveSize1 = 0
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Texture = TEX_LIGHTNING
	beam.TextureSpeed = 12 -- fast enough to look like violently ripping energy
	beam.TextureLength = 2 -- shorter repeat → denser zig-zag pattern
	beam.Color = ENERGY_COLOR_SEQ
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05), -- nearly opaque at player hand
		NumberSequenceKeypoint.new(0.5, 0), -- fully opaque mid-beam
		NumberSequenceKeypoint.new(1, 0.4), -- slight fade-out at enemy end
	})
	beam.Parent = workspace.Terrain

	-- PointLight on the enemy attachment: magenta glow illuminates the enemy
	local tLight = Instance.new("PointLight")
	tLight.Color = MID_MAGENTA
	tLight.Brightness = 2.5
	tLight.Range = 14
	tLight.Parent = attEnemy

	-- ── Continuous shard-ember shed while tether is live ─────────────────
	-- Attached to enemy end so sparks shed as the enemy is dragged.
	local tetherSparks = Instance.new("ParticleEmitter")
	tetherSparks.Texture = TEX_CRYSTAL_SHARD
	tetherSparks.Color = EMBER_COLOR_SEQ
	tetherSparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.10),
		NumberSequenceKeypoint.new(0.5, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	tetherSparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	tetherSparks.Speed = NumberRange.new(4, 12)
	tetherSparks.Lifetime = NumberRange.new(0.18, 0.40)
	tetherSparks.SpreadAngle = Vector2.new(55, 55)
	tetherSparks.LightEmission = 1
	tetherSparks.LightInfluence = 0
	tetherSparks.Drag = 2.5
	tetherSparks.Acceleration = Vector3.new(0, 6, 0)
	tetherSparks.Rate = 35 -- continuous emission while alive
	tetherSparks.Rotation = NumberRange.new(0, 360)
	tetherSparks.RotSpeed = NumberRange.new(-400, 400)
	tetherSparks.Parent = attEnemy

	-- ── RenderStepped: perfect per-frame position sync ────────────────────
	local impactFired = false
	local elapsed = 0

	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt: number)
		elapsed += dt

		-- GUARD: clean up if player/enemy disappear or time runs out
		local playerAlive = root and root.Parent
		local enemyExists = enemyRoot and enemyRoot.Parent
		local enemyAlive = enemyExists and isEnemyAlive(enemyRoot:FindFirstAncestorOfClass("Model"))
		local timedOut = elapsed > PULL_DURATION + 0.2

		if timedOut or not playerAlive or not enemyAlive then
			conn:Disconnect()
			safeDestroy(beam)
			safeDestroy(attPlayer)
			safeDestroy(attEnemy)
			return
		end

		-- UPDATE ATTACHMENT POSITIONS — must happen every frame for zero lag
		attPlayer.WorldPosition = handPart.Position + Vector3.new(0, 0.5, 0)
		attEnemy.WorldPosition = enemyRoot.Position + Vector3.new(0, 1, 0)

		-- ARRIVAL CHECK → trigger Act 3 and snap the tether
		local dist = (enemyRoot.Position - root.Position).Magnitude
		if dist < ARRIVAL_DIST and not impactFired then
			impactFired = true
			conn:Disconnect()

			-- Stop shard emission immediately (no lingering particles)
			tetherSparks.Enabled = false

			-- Instantly remove the beam and its attachments
			safeDestroy(beam)
			safeDestroy(attPlayer)
			safeDestroy(attEnemy)

			-- Fire the Act 3 impact at the player's chest level
			playImpact(root.Position + Vector3.new(0, 1, 0))
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Play the full 3-Act Iron Grip VFX sequence.

	Called by SkillVFX.luau when the "SkillUsed" remote event fires with
	skillData.Name == "Iron Grip".

	@param char      Model  — the local player's character model
	@param skillData table  — forwarded from SkillUsed (reads .Range, .HitTime)
]]
function IronGripVFX.Play(char: Model, skillData: any)
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local range = skillData.Range or 35
	local hitTime = skillData.HitTime or 0.45

	-- ══════════════════════════════════════════════════════════════════════════
	-- ACT 1 — CAST (fires immediately on skill activation)
	-- ══════════════════════════════════════════════════════════════════════════

	-- 1a. Instantaneous diamond-shard burst at the right hand ──────────────
	-- This is the "snappy, instantaneous burst of energy to signify activation"
	-- called for in the spec. All via :Emit() — no toggling Enabled.
	local handPart = findHandPart(char)

	local castAtt = Instance.new("Attachment")
	castAtt.WorldPosition = handPart.Position + Vector3.new(0, 0.5, 0)
	castAtt.Parent = workspace.Terrain

	-- Sharp diamond-shard emitter
	local castBurst = Instance.new("ParticleEmitter")
	castBurst.Texture = TEX_CRYSTAL_SHARD
	castBurst.Color = ENERGY_COLOR_SEQ
	castBurst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0), -- large at birth
		NumberSequenceKeypoint.new(0.3, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	castBurst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	castBurst.Speed = NumberRange.new(15, 35)
	castBurst.Lifetime = NumberRange.new(0.12, 0.30)
	castBurst.SpreadAngle = Vector2.new(75, 75)
	castBurst.LightEmission = 1
	castBurst.LightInfluence = 0
	castBurst.Drag = 4
	castBurst.Rate = 0 -- burst-only
	castBurst.Rotation = NumberRange.new(0, 360)
	castBurst.RotSpeed = NumberRange.new(-300, 300)
	castBurst.Parent = castAtt
	castBurst:Emit(20) -- INSTANT burst, no Enabled toggling

	-- Hand glow flash (decays over hitTime)
	local castLight = Instance.new("PointLight")
	castLight.Color = HOT_CORE
	castLight.Brightness = 5
	castLight.Range = 16
	castLight.Parent = castAtt
	TweenService:Create(castLight, TweenInfo.new(hitTime), { Brightness = 0 }):Play()

	Debris:AddItem(castAtt, hitTime + 0.1)

	-- 1b. Three concentric neon rings expand from the player's feet ────────
	-- Each ring represents a band of the energy palette and telegraphs range.
	-- They are staggered 0.05 s apart so you can read the "hot edge" layering.
	local castOrigin = root.Position - Vector3.new(0, 2.5, 0)
	local ringBase = CFrame.new(castOrigin) * CFrame.Angles(0, 0, math.rad(90))

	-- Ring 1: dark outer shell — largest, slowest, fades last
	local ringDark = Instance.new("Part")
	ringDark.Name = "IronGrip_CastRingDark"
	ringDark.Anchored = true
	ringDark.CanCollide = false
	ringDark.CanQuery = false
	ringDark.CanTouch = false
	ringDark.CastShadow = false
	ringDark.Shape = Enum.PartType.Cylinder
	ringDark.Material = Enum.Material.Neon
	ringDark.Color = EDGE_DARK
	ringDark.Transparency = 0
	ringDark.Size = Vector3.new(0.4, 2, 2)
	ringDark.CFrame = ringBase
	ringDark.Parent = workspace.Terrain
	TweenService:Create(
		ringDark,
		TweenInfo.new(hitTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, range * 2, range * 2), Transparency = 1 }
	):Play()
	Debris:AddItem(ringDark, hitTime + 0.15)

	-- Ring 2: vivid magenta — slightly smaller/faster, spawns 0.05s later
	task.delay(0.05, function()
		if not root or not root.Parent then
			return
		end
		local ringMag = Instance.new("Part")
		ringMag.Name = "IronGrip_CastRingMagenta"
		ringMag.Anchored = true
		ringMag.CanCollide = false
		ringMag.CanQuery = false
		ringMag.CanTouch = false
		ringMag.CastShadow = false
		ringMag.Shape = Enum.PartType.Cylinder
		ringMag.Material = Enum.Material.Neon
		ringMag.Color = MID_MAGENTA
		ringMag.Transparency = 0
		ringMag.Size = Vector3.new(0.35, 2, 2)
		ringMag.CFrame = ringBase
		ringMag.Parent = workspace.Terrain
		TweenService:Create(
			ringMag,
			TweenInfo.new(hitTime * 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.35, range * 2.2, range * 2.2), Transparency = 1 }
		):Play()
		Debris:AddItem(ringMag, hitTime + 0.1)
	end)

	-- Ring 3: hot yellow/white core — thinnest, fastest — the blazing "tip"
	task.delay(0.10, function()
		if not root or not root.Parent then
			return
		end
		local ringHot = Instance.new("Part")
		ringHot.Name = "IronGrip_CastRingHot"
		ringHot.Anchored = true
		ringHot.CanCollide = false
		ringHot.CanQuery = false
		ringHot.CanTouch = false
		ringHot.CastShadow = false
		ringHot.Shape = Enum.PartType.Cylinder
		ringHot.Material = Enum.Material.Neon
		ringHot.Color = HOT_CORE
		ringHot.Transparency = 0
		ringHot.Size = Vector3.new(0.25, 2, 2)
		ringHot.CFrame = ringBase
		ringHot.Parent = workspace.Terrain
		TweenService:Create(
			ringHot,
			TweenInfo.new(hitTime * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(0.25, range * 2.4, range * 2.4), Transparency = 1 }
		):Play()
		Debris:AddItem(ringHot, hitTime + 0.1)
	end)

	-- ══════════════════════════════════════════════════════════════════════════
	-- ACT 2 — TETHER & DRAG  [fires at hitTime, same frame as the server pull]
	-- ══════════════════════════════════════════════════════════════════════════

	task.delay(hitTime, function()
		if not root or not root.Parent then
			return
		end

		-- Re-fetch hand part (character might have respawned)
		local currentHand = findHandPart(char)
		local playerOrigin = root.Position

		-- Helper: validate + spawn a tether for a given enemy model
		local function tryTether(model: Model)
			if not isEnemyAlive(model) then
				return
			end

			local pivot = model:GetPivot().Position
			if (pivot - playerOrigin).Magnitude > range then
				return
			end

			-- Find the best root-level part on the enemy to anchor the enemy end
			local enemyRoot = (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
				or (model:FindFirstChild("Torso") :: BasePart?)
				or model.PrimaryPart

			if enemyRoot then
				spawnTether(root, currentHand, enemyRoot :: BasePart)
			end
		end

		-- Mirror CombatLib: scan both CollectionService tags used by enemies
		for _, model in CollectionService:GetTagged("Enemy") do
			tryTether(model)
		end
		for _, model in CollectionService:GetTagged("TrainingDummy") do
			tryTether(model)
		end
	end)
end

--[[
	ASSET REFERENCE
	All textures below are white-silhouette sprites loaded from the CDN.
	The Roblox engine multiplies them by the ColorSequence at render time.
	No manual Studio setup is required — just publish and play.

	TEX_LIGHTNING     rbxassetid://116444971840186
	  Horizontal jagged lightning stripe. Used as the Beam tether.
	  Set TextureSpeed = 12 for violent, chaotic ripping energy look.

	TEX_CRYSTAL_SHARD rbxassetid://133968093303018
	  Sharp crystalline / diamond-shaped shard.
	  Used for Act 1 cast burst and Act 3 impact shard explosion.

	TEX_SMOKE         rbxassetid://15265626147
	  Soft round puff for secondary ambient billow (unused here but
	  kept as a reference for easy addition later).
]]

return IronGripVFX
