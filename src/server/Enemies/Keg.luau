--[[
	Keg.luau
	Suicide bomber enemy. Inherits from BaseEnemy.

	State flow:
	  Idle → Chase → (OnChaseOverride intercepts at ArmRange) → Arming → Dead

	Custom behavior:
	  - OnChaseOverride: suppresses base movement and calls _beginArming() when
	    the target enters ArmRange. The "Arming" string is a custom state constant
	    not present in BaseEnemy.AIState. The base Tick silently ignores unknown
	    states (same pattern as LeapAttack / ChargeAttack coroutines).
	  - _beginArming: stops movement, flashes parts via TweenService, schedules
	    _detonate() after ArmDuration seconds.
	  - _detonate: loops Players:GetPlayers() and distance-checks each
	    HumanoidRootPart against ExplosionRadius (avoids GetPartBoundsInRadius
	    which silently misses parts with CanQuery=false on custom rigs), deals
	    ExplosionDamage with radial knockback, spawns a server-side Explosion +
	    expanding neon sphere, then calls _onDeath() directly (bypasses the
	    normal HP-drain → IsDead path).
	  - OnAttackEnter: safety no-op. AttackRange = 0 means Attack state can't
	    trigger naturally, but the override prevents a generic melee hit if it
	    ever does due to a config mistake.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local BaseEnemy = require(script.Parent.BaseEnemy)
local AIState = BaseEnemy.AIState

-- Custom state: base Tick ignores it; _beginArming drives all transitions from here.
local ARMING_STATE = "Arming"

-- ============================================================
-- CLASS
-- ============================================================

local Keg = setmetatable({}, { __index = BaseEnemy })
Keg.__index = Keg

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

function Keg.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "Keg", services)
	-- Guards re-entry of the arming sequence: OnChaseOverride fires every Tick
	-- (20 Hz) so we must latch the first trigger and never re-arm.
	self._isArming = false

	-- Locate the mesh for procedural rolling.
	-- _kegVisualWeld: the regular Weld whose C0 we animate each tick (C0 is animatable;
	-- WeldConstraints are rigid and cannot be used for this purpose).
	-- _kegRollingRadius: cached rolling radius so Tick doesn't recompute from Size every frame.
	self.KegMesh = model:FindFirstChild("Keg")
		or model:FindFirstChild("keg")
		or model:FindFirstChildWhichIsA("MeshPart")
		or model:FindFirstChild("Mesh")
	self._kegVisualWeld = nil :: any
	self._kegInitialVisualC0 = CFrame.identity
	self._kegInitialVisualC1 = CFrame.identity
	self._kegRollingRadius = 0.75 -- sensible default; overwritten below
	self._rollAngle = 0 -- accumulated spin for the rolling visual
	self._prevKegPos = nil :: Vector3? -- position at END of previous Tick; used to measure real movement
	self._kegOrientationOffset = CFrame.identity -- extra orientation for real-mesh path
	self._kegGroundOffset = 0 -- world-Y drop from HRP centre to keg centre; set in _buildPlaceholderVisual

	if not self.KegMesh then
		-- Placeholder model: build the rolling barrel visual now that BaseEnemy setup is done.
		-- Direct call (metatable not set yet, so avoid self:method() syntax).
		Keg._buildPlaceholderVisual(self)
	else
		-- Real mesh: authored upright in Studio, driven the same way as the placeholder —
		-- Anchored + direct CFrame in Tick. A Weld approach was tried here but the original
		-- Motor6D joint kept winning the constraint battle, preventing any rotation. Anchoring
		-- the mesh and setting its CFrame directly sidesteps all constraint fighting.

		-- Hide the invisible HumanoidRootPart box; only the mesh should be visible.
		self.RootPart.Transparency = 1
		local head = model:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			head.Transparency = 1
		end

		-- Lay flat (Rz 90°), roll around barrel axis (Rx rollAngle) — same as placeholder.
		self._kegOrientationOffset = CFrame.Angles(0, 0, math.rad(90))
		-- Rolling radius = smallest of Y/Z (robust for upright or sideways models).
		self._kegRollingRadius = math.min(self.KegMesh.Size.Y, self.KegMesh.Size.Z) / 2

		-- Destroy ALL joints/welds touching the mesh so nothing fights our CFrame writes.
		for _, w in model:GetDescendants() do
			if w:IsA("Weld") or w:IsA("Motor6D") or w:IsA("WeldConstraint") then
				if w.Part0 == self.KegMesh or w.Part1 == self.KegMesh then
					w:Destroy()
				end
			end
		end

		-- Anchor the mesh so physics can't override our per-Tick CFrame writes.
		self.KegMesh.Anchored = true
		-- _kegVisualWeld stays nil — Tick uses the `KegMesh.Anchored` branch.

		-- Compute ground offset exactly like _buildPlaceholderVisual does.
		local gc = model:FindFirstChild("GroundCollision") :: BasePart?
		if gc then
			local gcBottomY = gc.Position.Y - gc.Size.Y / 2
			local distToGround = self.RootPart.Position.Y - gcBottomY
			self._kegGroundOffset = distToGround - self._kegRollingRadius
		else
			self._kegGroundOffset = 1.0
		end
	end

	Keg._setupAura(self)

	return setmetatable(self, Keg)
end

-- ============================================================
-- PRIVATE: AURA SETUP
-- ============================================================

function Keg:_setupAura()
	if not self.KegMesh then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "AuraAttachment"
	attachment.Parent = self.KegMesh

	local highlight = Instance.new("Highlight")
	highlight.Name = "AuraHighlight"
	highlight.FillColor = Color3.fromRGB(80, 0, 150)
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(150, 50, 255)
	highlight.OutlineTransparency = 0.2
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = self.KegMesh

	local pointLight = Instance.new("PointLight")
	pointLight.Name = "AuraLight"
	pointLight.Color = Color3.fromRGB(150, 50, 255)
	pointLight.Brightness = 1
	pointLight.Range = 8
	pointLight.Parent = self.KegMesh

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "AuraParticles"
	particles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(100, 0, 150)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(50, 0, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 0, 40)),
	})
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.5, 1.5),
		NumberSequenceKeypoint.new(1, 2.5),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.8, 0.8),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(0.5, 1)
	particles.Speed = NumberRange.new(2, 5)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Rate = 10
	particles.Parent = attachment

	self._auraHighlight = highlight
	self._auraLight = pointLight
	self._auraParticles = particles
end

-- ============================================================
-- PRIVATE: PLACEHOLDER ROLLING VISUAL
-- ============================================================

--[[
	Called once from the constructor when no real keg mesh exists.

	Creates a barrel visual (cylinder) that is driven entirely by Tick — its CFrame is
	set from scratch each frame relative to HRP, so there is no Weld or constraint to
	fight with. The part is Anchored so physics don't pull it away from HRP between ticks.

	Orientation maths (applied in Tick):
	  - Roblox PartType.Cylinder has its axis along the PART'S LOCAL X — it is ALREADY
	    horizontal by default. No tilt offset is needed for the placeholder.
	  - Rolling radius = Size.Y / 2 = Size.Z / 2 = 0.75 studs (circular cross-section).
	  - Tick: rollRotation = Rx(rollAngle) — spins around HRP's local X, which equals the
	    cylinder's own axis, producing correct forward-rolling barrel motion.
	  - The keg is also offset downward by _kegGroundOffset so it sits on the ground
	    rather than floating at HRP (torso) height.
]]
function Keg:_buildPlaceholderVisual()
	local root = self.RootPart

	-- Hide the default box torso and floating head — the cylinder IS the visual.
	root.Transparency = 1
	local head = self.Model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		head.Transparency = 1
	end

	-- Roblox PartType.Cylinder: axis is along the part's LOCAL X.
	-- Size.X = barrel length (2 studs). Size.Y = Size.Z = diameter (1.5 studs → radius 0.75).
	-- The part is ALREADY lying flat — no orientation offset needed.
	-- Anchored = true: we set its CFrame directly every tick; no Weld needed.
	local kegVis = Instance.new("Part")
	kegVis.Name = "Keg"
	kegVis.Shape = Enum.PartType.Cylinder
	kegVis.Size = Vector3.new(2, 1.5, 1.5) -- X = barrel length, Y/Z = diameter (equal → true circle)
	kegVis.Color = Color3.fromRGB(255, 120, 0)
	kegVis.Material = Enum.Material.SmoothPlastic
	kegVis.Anchored = true
	kegVis.CanCollide = false
	kegVis.CanQuery = false
	kegVis.CanTouch = false
	kegVis.CastShadow = false
	kegVis.Parent = self.Model

	self.KegMesh = kegVis
	self._kegVisualWeld = nil -- no weld; CFrame driven directly
	-- No tilt needed — cylinder is already horizontal (axis along X).
	self._kegOrientationOffset = CFrame.identity
	-- Rolling radius = circular cross-section radius (Y/2 = 0.75 studs).
	self._kegRollingRadius = kegVis.Size.Y / 2

	-- Compute how far below HRP centre the keg centre should sit so the barrel
	-- rests on the ground rather than floating at torso height.
	-- _setupPhysics creates a GroundCollision box welded to HRP; its bottom edge
	-- is at feet/ground level. We recover distToGround from it at spawn time.
	local gc = self.Model:FindFirstChild("GroundCollision") :: BasePart?
	if gc then
		local gcBottomY = gc.Position.Y - gc.Size.Y / 2
		local distToGround = self.RootPart.Position.Y - gcBottomY
		self._kegGroundOffset = distToGround - self._kegRollingRadius
	else
		self._kegGroundOffset = 1.0 -- fallback: drop 1 stud below HRP centre
	end
end

-- ============================================================
-- PRIVATE: FLASH VISUAL
-- ============================================================

--[[
	Intensify the visual aura (glow, light, particles) during the arming sequence.
	Runs in a separate task.spawn so it doesn't block the arming delay timer.
	Gracefully exits if the model is destroyed mid-flash.
]]
function Keg:_doArmFlash(duration: number)
	if not self._auraHighlight or not self._auraLight or not self._auraParticles then
		return
	end

	-- Increase particle rate for eruption
	self._auraParticles.Rate = 50
	self._auraParticles.Speed = NumberRange.new(5, 10)

	-- Tween highlight and light to be more intense
	local highlightTween = TweenService:Create(
		self._auraHighlight,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{
			FillColor = Color3.fromRGB(255, 50, 255),
			FillTransparency = 0.1,
			OutlineColor = Color3.fromRGB(255, 100, 255),
			OutlineTransparency = 0,
		}
	)
	highlightTween:Play()

	local lightTween = TweenService:Create(
		self._auraLight,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Brightness = 4, Range = 15, Color = Color3.fromRGB(255, 50, 255) }
	)
	lightTween:Play()

	-- Also do a rapid pulsing effect on the light
	task.spawn(function()
		local elapsed = 0
		local isBright = false
		local pulseInterval = 0.1
		while elapsed < duration and not self._destroyed do
			isBright = not isBright
			if self._auraLight.Parent then
				self._auraLight.Brightness = isBright and 6 or 2
			end
			task.wait(pulseInterval)
			elapsed += pulseInterval
			pulseInterval = math.max(0.04, pulseInterval * 0.8) -- Speed up pulse as it approaches detonation
		end
	end)
end

-- ============================================================
-- PRIVATE: EXPLOSION VFX
-- ============================================================

--[[
	Server-side explosion spawned at the detonation position.
	Only deploys the invisible Roblox Explosion instance for light/sound hooks.
	The visually stylized Void Eruption is entirely handled on the client.
]]
function Keg:_spawnExplosionVFX(position: Vector3)
	local blastRadius = self.Config.ExplosionRadius or 12

	-- Roblox built-in explosion (light and sound only, no physics push)
	local explosion = Instance.new("Explosion")
	explosion.BlastRadius = blastRadius
	explosion.BlastPressure = 0 -- Visual only — no ragdolling or part flinging
	explosion.ExplosionType = Enum.ExplosionType.NoCraters
	explosion.Position = position
	explosion.Parent = workspace
end

-- ============================================================
-- PRIVATE: DETONATION
-- ============================================================

--[[
	Core explosion logic. Called by task.delay after ArmDuration expires.

	Hit detection uses workspace:GetPartBoundsInRadius to find all BaseParts
	inside the blast sphere, then walks up to the character Model and resolves
	the owning Player. A deduplication set prevents double-hitting multi-part
	characters. I-frames are honoured (dashing out is the player's intended out).

	Knockback is radial from the explosion centre with a slight upward bias so
	players are thrown visibly even when standing directly above the detonation.
]]
function Keg:_detonate()
	-- Guard: killed by a player hit while arming — don't double-fire death logic.
	if self._destroyed then
		return
	end

	local rootPos = self.RootPart.Position
	local blastRadius = self.Config.ExplosionRadius or 12
	local damage = self.Config.ExplosionDamage or 40

	-- ── Hit detection ──────────────────────────────────────────────────
	-- Direct player loop instead of workspace:GetPartBoundsInRadius.
	-- GetPartBoundsInRadius silently skips parts with CanQuery=false, which is
	-- common on custom class rigs (Vanguard etc.) — causing the explosion to
	-- find no targets and deal zero damage. Distance check against
	-- HumanoidRootPart is always reliable regardless of CanQuery settings.
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then
			continue
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			continue
		end
		local charRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not charRoot then
			continue
		end

		-- Sphere check: is the root within blast radius?
		if (charRoot.Position - rootPos).Magnitude > blastRadius then
			continue
		end

		-- I-frame check: player dashed out of the blast window in time
		local iframeExpiry = self._services.getIFrameExpiry(player)
		if iframeExpiry and tick() < iframeExpiry then
			self._services.blockDamage(player, self.Model, rootPos, damage)
			continue
		end

		-- Radial knockback: away from blast centre with an upward component
		-- so the player is launched visibly rather than just pushed sideways.
		local rawDir = charRoot.Position - rootPos
		-- Ensure minimum upward component regardless of relative position
		local knockDir = Vector3.new(rawDir.X, math.max(rawDir.Y, 0) + 0.5, rawDir.Z).Unit
		self._services.dealDamage(player, damage, knockDir * 40)
	end

	-- ── VFX ────────────────────────────────────────────────────────────
	self:_spawnExplosionVFX(rootPos)

	-- Notify client VFX controller (screen shake, damage numbers, SFX)
	self._services.fireEnemyAttack({
		Enemy = self.Model,
		Target = self.Target,
		HitPosition = rootPos,
		Damage = damage,
		AttackType = self.Config.ExplosionVFXType or "Explosion",
		IsAoE = true,
		AoERadius = blastRadius,
	})

	-- ── Self-destruct ───────────────────────────────────────────────────
	-- Call _onDeath() directly rather than setting IsDead attribute.
	-- Reason: IsDead is normally set by CombatService when HP hits zero via
	-- combat damage. The Keg dies from detonation, not HP drain, so we
	-- bypass that path entirely. _onDeath() is idempotent (_destroyed guard).
	self:_onDeath()
end

-- ============================================================
-- PRIVATE: ARMING SEQUENCE
-- ============================================================

--[[
	Entry point for the arming state. Called exactly once (guarded by _isArming).
	Stops all movement, kicks off the flash loop, then schedules detonation.
]]
function Keg:_beginArming()
	self._isArming = true
	self.State = ARMING_STATE

	self:StopMovement()
	if self.WalkTrack and self.WalkTrack.IsPlaying then
		self.WalkTrack:Stop(0.05)
	end

	-- Broadcast custom state so clients can play an arming SFX/animation if desired.
	self._services.fireEnemyStateChanged(self.Model, ARMING_STATE)

	local armDuration = self.Config.ArmDuration or 1.2
	self:_doArmFlash(armDuration)

	task.delay(armDuration, function()
		self:_detonate()
	end)
end

-- ============================================================
-- OVERRIDE: OnChaseOverride
-- ============================================================

--[[
	Called every Tick while in Chase state (20 Hz).
	Returns true to suppress base MoveTowardTarget + FaceToward.

	Once within ArmRange the Keg arms regardless of whether it can reach
	the player — the latch (_isArming) prevents any re-trigger. If hitstun
	knocks it back beyond ArmRange during arming, the task.delay still fires
	because only _destroyed cancels it: "once armed, stay armed."
]]
function Keg:OnChaseOverride(targetPos: Vector3, distance: number): boolean
	local armRange = self.Config.ArmRange or 5
	if distance <= armRange then
		if not self._isArming then
			self:_beginArming()
		end
		-- Suppress base movement whether we just armed or are already arming
		return true
	end
	-- Still outside arm range — let the base chase and pathfinding run normally
	return false
end

-- ============================================================
-- OVERRIDE: OnAttackEnter
-- ============================================================

--[[
	Safety net only. AttackRange = 0 in EnemyConfig means the base Chase branch
	`if distance <= attackRange` can never be satisfied (distance is always >= 0,
	not strictly <= 0). If it somehow fires due to a config error, reset to Chase
	instead of executing a generic melee hit on a suicide bomber.
]]
function Keg:OnAttackEnter()
	self.State = AIState.Chase
end

-- ============================================================
-- OVERRIDE: Tick
-- ============================================================

function Keg:Tick(dt: number)
	-- Snapshot current position BEFORE base tick.
	-- Heartbeat fires AFTER the physics step, so this position already reflects
	-- the movement applied by LinearVelocity in the PREVIOUS Tick. Comparing it
	-- against _prevKegPos (saved at the end of the last Tick) gives the real
	-- distance the enemy physically travelled since the last frame.
	--
	-- The old pattern of `oldPos = pos; BaseEnemy.Tick(); dist = pos - oldPos`
	-- always produced dist = 0 because BaseEnemy.Tick only sets LinearVelocity
	-- (a request to the physics engine) — it does NOT move the part within the
	-- same Heartbeat callback. Physics runs between callbacks, not inside them.
	local currentPos = self.RootPart and self.RootPart.Position

	-- Run base logic (movement, state transitions)
	BaseEnemy.Tick(self, dt)

	-- If dead, destroyed, or no visual mesh, skip rolling
	if self._destroyed or self.State == "Dead" or not self.RootPart or not self.KegMesh then
		self._prevKegPos = currentPos
		return
	end

	-- ── Accumulate roll angle from actual physics movement ──────────────
	-- Use _prevKegPos (end of last Tick) vs currentPos (start of this Tick).
	-- distMoved is now the real distance travelled during the physics step
	-- that occurred between the two Heartbeat callbacks.
	if self.State == AIState.Chase and self._prevKegPos and currentPos then
		local distMoved = (currentPos - self._prevKegPos).Magnitude
		if distMoved > 0 then
			local radius = if self._kegRollingRadius > 0.1 then self._kegRollingRadius else 1
			self._rollAngle -= distMoved / radius
		end
	end
	self._prevKegPos = currentPos

	-- ── Sync CFrame every tick ─────────────────────────────────────────
	-- rollRotation = Rx(rollAngle) * Rz(90°).
	-- Applied order (right-to-left): first Rz(90°) lays the barrel flat, then Rx(rollAngle)
	-- spins it around the original X axis — which is parallel to the barrel's own axis after
	-- the tilt — producing correct forward-rolling barrel motion.
	local rollRotation = CFrame.Angles(self._rollAngle, 0, 0) * self._kegOrientationOffset

	-- Lower the keg from HRP centre to ground level so it rolls ON the ground.
	-- CFrame.new(0, -offset, 0) shifts in HRP's local Y (= world up, since AlignOrientation
	-- keeps HRP upright), which is equivalent to moving straight down in world space.
	local groundShift = CFrame.new(0, -self._kegGroundOffset, 0)

	if self.KegMesh.Anchored then
		self.KegMesh.CFrame = self.RootPart.CFrame * groundShift * rollRotation
	elseif self._kegVisualWeld then
		-- Apply the ground shift and roll on top of the original authored relative C0
		-- The user found the correct pos/rot separation:
		local authoredPos = self._kegInitialVisualC0.Position
		local authoredBaseRot = self._kegInitialVisualC0 - authoredPos
		self._kegVisualWeld.C0 = groundShift
			* CFrame.new(authoredPos)
			* CFrame.Angles(self._rollAngle, 0, 0)
			* self._kegOrientationOffset
			* authoredBaseRot
	else
		self.KegMesh.CFrame = self.RootPart.CFrame * groundShift * rollRotation
	end
end

-- ============================================================
return Keg
