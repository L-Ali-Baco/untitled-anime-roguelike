--!strict
--[[
	HexCaster.luau
	==============
	Airborne ranged caster. Replaces the Shooter archetype.

	NON-HUMANOID RIG
	  This enemy has NO Humanoid. It uses an AnimationController → Animator.
	  BaseEnemy._setupAnimator() already handles creating those instances, so
	  there is nothing extra to do in this class for basic animation plumbing.
	  The only difference from a ground enemy is:
	    1. We load our own animation tracks (idle, cast) here in _loadCasterAnims.
	    2. We switch LinearVelocity to Vector mode so we can drive the Y axis too.
	    3. We apply a per-tick proportional Y controller to hover at HOVER_HEIGHT.

	HOVER PHYSICS
	  BaseEnemy creates a LinearVelocity in Plane mode (XZ only, gravity acts on Y).
	  In the constructor we switch it to Vector mode. In Vector mode the constraint
	  applies whatever forces are needed to match VectorVelocity on all three axes,
	  so setting VectorVelocity.Y = 0 counteracts gravity and keeps the enemy aloft.
	  We use a proportional P-controller on the Y error (targetY − currentY) to
	  smoothly correct drift without oscillation.

	STATE MACHINE (inherits AIState from BaseEnemy)
	  Idle       → detects player within AggroRange → Chase
	  Chase      → OnChaseOverride drives all movement:
	                 · distance < FleeDistance    → retreat
	                 · distance ≈ PreferredDistance → strafe/orbit
	                 · distance > PreferredDistance → approach
	               Enters Attack when distance ≤ AttackRange and cooldown ready
	  Attack     → OnAttackEnter: wind-up, fire HexBolt, return to Chase
	  Hitstun    → handled entirely by BaseEnemy
	  Dead       → handled entirely by BaseEnemy

	SETUP REQUIRED (per enemy spawn/model)
	  See the rigging guide at the bottom of this file.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseEnemy = require(script.Parent.BaseEnemy)
local AIState = BaseEnemy.AIState

-- Lazy-loaded on first attack so the module is available by Start() time
-- without creating a circular require at module load.
local ToxicBlobService: typeof(require(script.Parent.Parent.Services.ToxicBlobService))

-- Lazy-loaded heavy-attack remotes. Uses FindFirstChild (non-yielding) so it is safe
-- to call from any thread after the server bootstrap has completed.
local _heavyTelegraphRemote: RemoteEvent?
local _heavyFireRemote: RemoteEvent?
local function getHeavyRemotes(): (RemoteEvent?, RemoteEvent?)
	if not _heavyTelegraphRemote then
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		if shared then
			local remotesModule = shared:FindFirstChild("Remotes")
			if remotesModule then
				local Remotes = require(remotesModule :: ModuleScript)
				_heavyTelegraphRemote = Remotes:GetEvent("HexBeamTelegraph") :: RemoteEvent?
				_heavyFireRemote = Remotes:GetEvent("HexBeamFire") :: RemoteEvent?
			end
		end
	end
	return _heavyTelegraphRemote, _heavyFireRemote
end
local function getBlobService()
	if not ToxicBlobService then
		ToxicBlobService = require(script.Parent.Parent.Services.ToxicBlobService)
	end
	return ToxicBlobService
end

-- ── Hover constants ────────────────────────────────────────────────────────────

-- Studs above the detected floor the HexCaster's root part targets.
-- At 4 studs the feet clear the ground by ~1–2 studs — a subtle
-- levitation rather than flying above the player's head.
-- Raise to 8–12 if you want a proper aerial enemy in a future pass.
local HOVER_HEIGHT: number = -1.5

-- Proportional gain for the Y position controller.
-- VectorVelocity.Y = clamp(yError × HOVER_P, ±HOVER_MAX_SPEED)
-- Higher = snappier correction; too high causes oscillation.
local HOVER_P: number = 6

-- Maximum vertical correction speed (studs / sec).
local HOVER_MAX_SPEED: number = 18

-- Downward ray length for ground detection (studs from 50 above current pos).
local HOVER_RAY_DOWN: number = 120

-- ── Animation ID ──────────────────────────────────────────────────────────────

-- Idle / hover loop. Plays as soon as the enemy spawns and loops indefinitely.
local IDLE_ANIM_ID: string = "rbxassetid://105855271459399"

-- ── Heavy attack constants ─────────────────────────────────────────────────────

-- Channel animation. Loaded at Action4 priority so it overrides idle and the
-- standard cast simultaneously. The fire point is at 0.88 s into the clip.
local HEAVY_ANIM_ID: string = "rbxassetid://76748423824936"

-- Seconds from cast start to beam fire — must match the wind-up frame in the clip.
local BEAM_WINDUP: number = 0.88

-- Seconds of recovery after the beam fires before returning to Chase.
local BEAM_RECOVERY: number = 0.35

-- Length of the linear hitbox (studs forward from HRP centre).
local BEAM_LENGTH: number = 60

-- Full width and height of the hitbox (studs). Matches the VFX beam diameter.
local BEAM_WIDTH: number = 5

-- ── Class ─────────────────────────────────────────────────────────────────────

local HexCaster = setmetatable({}, { __index = BaseEnemy })
HexCaster.__index = HexCaster

-- ── Constructor ───────────────────────────────────────────────────────────────

function HexCaster.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	-- Run the standard BaseEnemy constructor.
	-- This will:
	--   • Find HumanoidRootPart, set up the LinearVelocity + AlignOrientation
	--   • Destroy any leftover Humanoid on the model
	--   • Create AnimationController → Animator if absent
	--   • Register the "Health" / "IsDead" attributes
	local self = setmetatable(BaseEnemy.new(model, config, "HexCaster", services), HexCaster) :: any

	-- ── Hover state ─────────────────────────────────────────────────
	-- Cached floor Y + HOVER_HEIGHT. Set lazily on first Tick via raycast.
	self._hoverTargetY = nil :: number?

	-- Current desired XZ velocity (updated by OnChaseOverride and StopMovement).
	-- _applyHoverCorrection() reads this to compose the full VectorVelocity.
	self._currentXZVel = Vector2.zero

	-- Per-instance RaycastParams: excludes this model so the floor ray
	-- does not hit the enemy's own parts (which have CanQuery = true by default).
	local hoverParams = RaycastParams.new()
	hoverParams.FilterType = Enum.RaycastFilterType.Exclude
	hoverParams.FilterDescendantsInstances = { model }
	self._hoverRayParams = hoverParams

	-- ── Cache feet offset ────────────────────────────────────────────
	-- BaseEnemy sets all mesh parts CanCollide=false; the GroundCollision box
	-- is the only collision geometry and MUST be kept (removing it causes the
	-- enemy to phase through everything). When hovering at the correct height
	-- the box floats above the terrain and causes no floor contact.
	--
	-- HOVER_HEIGHT is the desired gap between the MODEL'S FEET and the terrain.
	-- Without accounting for _distToFeet, the raw "+HOVER_HEIGHT" positions the
	-- RootPart centre at terrain+HOVER_HEIGHT — leaving the feet embedded in the
	-- terrain if the model is taller than HOVER_HEIGHT*2.
	-- Cache the vertical distance from RootPart centre to the model's lowest
	-- point so _computeHoverTargetY can offset correctly.
	local modelCF, modelSize = model:GetBoundingBox()
	local feetWorldY = modelCF.Position.Y - modelSize.Y / 2
	self._distToFeet = math.max(0, self.RootPart.Position.Y - feetWorldY)

	-- ── Switch LinearVelocity to full 3D (Vector) mode ──────────────
	-- Base created it in Plane mode (XZ only). We need Y control for hovering.
	-- In Vector mode the constraint fights gravity to hold VectorVelocity.Y.
	local lv = self.LinearVelocity
	if lv then
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.VectorVelocity = Vector3.zero
	end

	-- ── Snap to correct hover height immediately ────────────────────
	-- SpawnEnemy calls PivotTo() BEFORE HexCaster.new, so we can raycast
	-- now to find actual terrain Y at this X,Z and snap before physics runs.
	self:_computeHoverTargetY()
	if self._hoverTargetY then
		local pos = self.RootPart.Position
		self.RootPart.CFrame = CFrame.new(pos.X, self._hoverTargetY, pos.Z)
		self.RootPart.AssemblyLinearVelocity = Vector3.zero
	end

	-- ── Heavy attack state ───────────────────────────────────────────────
	-- Separate cooldown timer keeps the heavy on its own cadence, independent
	-- of the normal attack LastAttackTime. Starts large-negative so the heavy
	-- is ready ~immediately after first aggro (10 s window is in config).
	self._lastHeavyAttackTime = -math.huge :: number
	-- Gate flag: prevents OnChaseOverride from re-entering while _doHeavyAttack
	-- is still running. Cleared inside the coroutine whether it completes or aborts.
	self._heavyInProgress = false :: boolean

	-- ── Load and immediately play the idle hover animation ──────────
	self:_loadCasterAnims()

	return self
end

-- ── Private: Animation setup ──────────────────────────────────────────────────

--[[
	Loads the caster-specific animation tracks.
	Called once from the constructor, after BaseEnemy._setupAnimator() has
	already created/located the Animator.
	Tracks loaded here are ADDITIVE on top of BaseEnemy's walk track setup
	(though HexCaster has no WalkAnimationId in config, so WalkTrack = nil).
]]
function HexCaster:_loadCasterAnims()
	local animator = self.Animator
	if not animator then
		warn("[HexCaster] Animator not found after BaseEnemy setup — animations skipped.")
		return
	end

	-- ── Idle / hover loop ────────────────────────────────────────────
	-- Plays at Idle priority so any Action-priority cast animation overrides it.
	-- We play it immediately here (not on aggro) so the enemy looks alive from spawn.
	local idleOk, idleResult = pcall(function()
		local idleAnim = Instance.new("Animation")
		idleAnim.AnimationId = IDLE_ANIM_ID
		local track = (animator :: Animator):LoadAnimation(idleAnim)
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Idle
		track:Play(0.3)
		return track
	end)
	if idleOk then
		self._idleTrack = idleResult :: AnimationTrack
	else
		warn(("[HexCaster] Idle animation load failed: %s"):format(tostring(idleResult)))
	end

	-- ── Cast animation (optional) ────────────────────────────────────
	-- Driven from config.CastAnimationId so it can be swapped in EnemyConfig
	-- without touching this file.
	local castAnimId: string? = self.Config.CastAnimationId
	if castAnimId then
		local castOk, castResult = pcall(function()
			local castAnim = Instance.new("Animation")
			castAnim.AnimationId = castAnimId :: string
			local track = (animator :: Animator):LoadAnimation(castAnim)
			track.Looped = false
			track.Priority = Enum.AnimationPriority.Action -- overrides Idle
			return track
		end)
		if castOk then
			self._castTrack = castResult :: AnimationTrack
		else
			warn(("[HexCaster] Cast animation load failed: %s"):format(tostring(castResult)))
		end
	end

	-- ── Beam / channel animation ──────────────────────────────────────────
	-- Action4 is the highest animator priority — overrides Idle, Action, Action2,
	-- and Action3. This guarantees the 0.88 s channel anim is never interrupted.
	local beamAnimId: string? = self.Config.HeavyBeamAnimId
	if not beamAnimId then
		beamAnimId = HEAVY_ANIM_ID
	end
	local beamOk, beamResult = pcall(function()
		local beamAnim = Instance.new("Animation")
		beamAnim.AnimationId = beamAnimId :: string
		local track = (animator :: Animator):LoadAnimation(beamAnim)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action4
		return track
	end)
	if beamOk then
		self._beamTrack = beamResult :: AnimationTrack
	else
		warn(("[HexCaster] Beam animation load failed: %s"):format(tostring(beamResult)))
	end
end

-- ── Private: Hover Y computation ─────────────────────────────────────────────

--[[
	Fires a downward ray from 50 studs above the enemy and caches
	(floor.Y + HOVER_HEIGHT) in self._hoverTargetY.

	Called lazily on first Tick. The floor is treated as static for most maps;
	re-call if your map has moving platforms or significant elevation changes.
]]
function HexCaster:_computeHoverTargetY()
	local origin = self.RootPart.Position + Vector3.new(0, 50, 0)
	local ray = workspace:Raycast(origin, Vector3.new(0, -HOVER_RAY_DOWN, 0), self._hoverRayParams)
	if ray then
		-- Place RootPart so that the model's FEET are HOVER_HEIGHT studs above
		-- the terrain. Without _distToFeet the formula would position the RootPart
		-- centre at terrain+HOVER_HEIGHT, leaving feet embedded in the floor.
		self._hoverTargetY = ray.Position.Y + self._distToFeet + HOVER_HEIGHT
	else
		-- No floor found (void / extremely high spawn): hold current height.
		self._hoverTargetY = self.RootPart.Position.Y
	end
end

-- ── Private: Velocity application ────────────────────────────────────────────

--[[
	Composes the full VectorVelocity from:
	  • self._currentXZVel — desired XZ movement set by OnChaseOverride / StopMovement
	  • a P-controller on Y error    — drives the enemy toward _hoverTargetY

	Called once per Tick, after all state-machine logic has set _currentXZVel.
	This is the ONLY place we write LinearVelocity.VectorVelocity.
]]
function HexCaster:_applyHoverCorrection()
	if not self._hoverTargetY then
		self:_computeHoverTargetY()
	end

	local lv = self.LinearVelocity
	if not lv then
		return
	end

	local yError = (self._hoverTargetY :: number) - self.RootPart.Position.Y
	local yVel = math.clamp(yError * HOVER_P, -HOVER_MAX_SPEED, HOVER_MAX_SPEED)
	lv.VectorVelocity = Vector3.new(self._currentXZVel.X, yVel, self._currentXZVel.Y)
end

-- ── Public: StopMovement override ─────────────────────────────────────────────

--[[
	Overrides BaseEnemy:StopMovement() which writes PlaneVelocity (unused in
	Vector mode). We zero the XZ intent and let _applyHoverCorrection maintain Y.
]]
function HexCaster:StopMovement()
	self._currentXZVel = Vector2.zero
	self.IsMoving = false
	self.LastMoveTarget = nil
	-- Apply immediately so there is no 1-tick XZ slip between calling
	-- StopMovement (e.g. on Attack entry) and the next Tick's correction.
	self:_applyHoverCorrection()
end

-- ── Override: OnChaseOverride ─────────────────────────────────────────────────

--[[
	Manages all HexCaster positional logic every Chase tick.
	Always returns true (suppresses BaseEnemy:MoveTowardTarget).

	ROOT CAUSE NOTE:
	  Because we return true, BaseEnemy.Tick skips its attack-range block entirely
	  (the block lives inside `if not handled then`). We must therefore own the
	  Attack transition ourselves here — otherwise the enemy never fires.

	Distance bands (all measured flat / XZ to ignore hover Y offset):
	  < FleeDistance            → sprint directly away
	  in [FleeDistance, AttackRange]  → orbit at WalkSpeed×0.6, fire when ready
	  > AttackRange + approach buffer → close toward player at full speed

	Attack gate (mirrors BaseEnemy logic exactly):
	  distance ≤ AttackRange  AND  cooldown elapsed  AND  token available
	  → set State = Attack, StopMovement, return.
	  Token denied → orbit and wait (same as base behaviour).
]]
function HexCaster:OnChaseOverride(targetPos: Vector3, _distance: number): boolean
	local config = self.Config
	local myPos = self.RootPart.Position
	local flatToTarget = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
	local flatDist = flatToTarget.Magnitude

	local now = os.clock()
	local speed: number = (self.Model:GetAttribute("WalkSpeed") :: number?) or 11
	local attackRange: number = config.AttackRange or 32
	local attackCooldown: number = config.AttackCooldown or 2.8
	local preferredDist: number = config.PreferredDistance or 26
	local fleeDist: number = config.FleeDistance or 12

	-- ── Heavy attack gate (priority over normal) ────────────────────────
	-- Fires every HeavyAttackCooldown seconds. Acquires the attack token, locks
	-- orientation, and spawns the coroutine that owns the 0.88 s channel.
	-- "HeavyAttacking" is a custom state string — BaseEnemy.Tick's elseif chain
	-- does not match it, so the enemy is fully frozen until the coroutine returns.
	local heavyCooldown: number = config.HeavyAttackCooldown or 10
	if not self._heavyInProgress and flatDist <= attackRange and now - self._lastHeavyAttackTime >= heavyCooldown then
		if self._services.canAttack(self.Target) then
			self._lastHeavyAttackTime = now
			-- Reset the normal attack timer so the quick-cast doesn't immediately
			-- follow the heavy when the enemy returns to Chase.
			self.LastAttackTime = now
			self._heavyInProgress = true
			self.State = "HeavyAttacking"
			self._tokenWaitStart = 0
			self:StopMovement()
			-- Lock orientation toward the player before the channel starts.
			-- We call FaceToward once here; during HeavyAttacking, Tick does NOT
			-- call FaceToward, so AlignOrientation holds this angle for the full 0.88 s.
			self:FaceToward(targetPos)
			task.spawn(function()
				self:_doHeavyAttack()
			end)
			return true
		end
	end

	-- ── Normal attack transition ──────────────────────────────────────────
	-- Check this BEFORE movement so we stop immediately when the gate opens.
	if flatDist <= attackRange then
		if now - self.LastAttackTime >= attackCooldown then
			if self._services.canAttack(self.Target) then
				-- Enter Attack state — mirrors the BaseEnemy.Tick transition exactly.
				self.State = AIState.Attack
				self.LastAttackTime = now
				self.AttackTriggered = false
				self.CurrentAttack = nil
				self._tokenWaitStart = 0
				self:StopMovement()
				return true
			else
				-- Token denied: mark wait start so base diagnostics are happy.
				if self._tokenWaitStart == 0 then
					self._tokenWaitStart = now
				end
				-- Fall through to orbit below while waiting for a slot.
			end
		end
		-- In range but on cooldown: fall through to orbit.
	else
		self._tokenWaitStart = 0
	end

	-- ── Movement bands ───────────────────────────────────────────────────
	local xzVel: Vector2

	if flatDist < 0.1 then
		xzVel = Vector2.zero
	elseif flatDist < fleeDist then
		-- Player too close: sprint directly away.
		local awayDir = -flatToTarget.Unit
		xzVel = Vector2.new(awayDir.X, awayDir.Z) * speed
	elseif flatDist > attackRange + 6 then
		-- Outside attack range: close the gap at full walk speed.
		local towardDir = flatToTarget.Unit
		xzVel = Vector2.new(towardDir.X, towardDir.Z) * speed
	elseif flatDist > preferredDist + 3 then
		-- Between preferred distance and attack range: slow approach.
		local towardDir = flatToTarget.Unit
		xzVel = Vector2.new(towardDir.X, towardDir.Z) * (speed * 0.5)
	else
		-- Within preferred distance: orbit perpendicular.
		-- _circleSign (±1) is randomised per instance in BaseEnemy constructor.
		local flatDir = flatToTarget.Unit
		local perp = Vector3.new(-flatDir.Z * self._circleSign, 0, flatDir.X * self._circleSign)
		xzVel = Vector2.new(perp.X, perp.Z) * (speed * 0.6)
	end

	self._currentXZVel = xzVel
	self.IsMoving = xzVel.Magnitude > 0.1
	self:FaceToward(targetPos)
	return true
end

-- ── Private: Hex-Beam coroutine ───────────────────────────────────────────────

--[[
	Runs on a task.spawn thread spawned by OnChaseOverride.
	The AI heartbeat loop is never blocked.

	Timeline:
	  0.00 s  → play channel anim, fire HexBeamTelegraph → clients show warning box
	  0.88 s  → GetPartBoundsInBox hitbox, deal damage, fire HexBeamFire → beam flash
	  ~1.23 s → release attack token, return to Chase

	Interruption handling:
	  If Hitstun or Death fires during the wind-up, self.State changes away from
	  "HeavyAttacking". The post-wait guard detects this and releases the token.
	  "HeavyAttacking" is NOT in BaseEnemy's wasAttacking whitelist, so TakeDamage
	  does NOT auto-call notifyAttackEnd — we must do it here in all exit paths.
]]
function HexCaster:_doHeavyAttack()
	local config = self.Config
	local target = self.Target

	-- Capture the beam orientation now. From this point on, AlignOrientation holds
	-- this CFrame (FaceToward is not called again while State == "HeavyAttacking").
	local beamCF: CFrame = self.RootPart.CFrame

	-- ── Channel animation ────────────────────────────────────────────────
	if self._beamTrack then
		self._beamTrack:Play(0.05)
	end

	-- ── Telegraph VFX → all clients ─────────────────────────────────────
	-- Clients render the flat warning box for BEAM_WINDUP seconds.
	local telegraphRemote, fireRemote = getHeavyRemotes()
	if telegraphRemote then
		telegraphRemote:FireAllClients(beamCF)
	end

	-- ── Wind-up yield ────────────────────────────────────────────────────
	task.wait(BEAM_WINDUP)

	-- Abort if interrupted by hitstun, death, or destruction.
	if self._destroyed or self.State ~= "HeavyAttacking" then
		self._heavyInProgress = false
		if target then
			self._services.notifyAttackEnd(target)
		end
		return
	end

	-- ── Linear hitbox via GetPartBoundsInBox ─────────────────────────────
	-- Box is centred (beamLength/2) studs in front of the caster.
	-- In Roblox, CFrame.new(0, 0, -d) moves d studs along the look direction.
	local beamLength: number = config.HeavyBeamLength or BEAM_LENGTH
	local beamWidth: number = config.HeavyBeamWidth or BEAM_WIDTH
	local hitboxCF = beamCF * CFrame.new(0, 0, -(beamLength / 2))
	local hitboxSize = Vector3.new(beamWidth, beamWidth, beamLength)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { self.Model }

	local beamDamage: number = config.HeavyAttackDamage or 30
	local alreadyHit: { [Player]: boolean } = {}

	local parts = workspace:GetPartBoundsInBox(hitboxCF, hitboxSize, overlapParams)
	for _, part in parts do
		local player = Players:GetPlayerFromCharacter(part.Parent)
		if player and not alreadyHit[player] then
			alreadyHit[player] = true
			local hum = (part.Parent :: Model):FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				-- Use dealDamage so iframes and combat logging are respected.
				self._services.dealDamage(player, beamDamage, Vector3.zero)
			end
		end
	end

	-- ── Beam flash VFX → all clients ─────────────────────────────────────
	-- Send the same beamCF captured at wind-up start (rotation was locked).
	if fireRemote then
		fireRemote:FireAllClients(beamCF)
	end

	-- ── Recovery pause ───────────────────────────────────────────────────
	task.wait(BEAM_RECOVERY)

	-- Always release the token — this covers hitstun-during-recovery too.
	self._heavyInProgress = false
	if target then
		self._services.notifyAttackEnd(target)
	end

	-- Only transition back to Chase if we're still in the heavy state.
	-- If hitstun fired during recovery, BaseEnemy will handle the Idle→Chase
	-- transition naturally once hitstun expires.
	if not self._destroyed and self.State == "HeavyAttacking" then
		self.State = AIState.Chase
		self.CurrentAttack = nil
		if self._idleTrack and not self._idleTrack.IsPlaying then
			self._idleTrack:Play(0.3)
		end
	end
end

-- ── Override: OnAttackEnter ───────────────────────────────────────────────────

--[[
	Wind-up, lob a ToxicBlob, then return to Chase.

	FIRE SEQUENCE:
	  1. Stop lateral drift — cast from a stationary hover position.
	  2. Play the cast animation (Action priority overrides idle).
	  3. After AttackWindup seconds:
	       • Read the target's current HRP position (leading-edge snapshot).
	       • Call ToxicBlobService:FireBlob(origin, targetPos, damage, ...).
	         The blob is a real physics Part; ToxicBlobService owns its flight,
	         hit detection, damage, and puddle lifecycle.
	  4. After AttackDuration seconds: release attack token, return to Chase.

	Why a snapshot at windup rather than at fire time?
	  We capture targetPos at the moment the wand "releases" (windup expiry).
	  This gives players a brief window to dodge by moving sideways during
	  the wind-up, without being able to dodge trivially just by running.
]]
function HexCaster:OnAttackEnter()
	local config = self.Config
	local target = self.Target
	if not target then
		self.State = AIState.Chase
		return
	end

	local windup: number = config.AttackWindup or 0.3
	local attackDuration: number = config.AttackDuration or 0.55
	local attackDamage: number = config.Damage or 12
	-- Puddle tick deals 30% of direct hit damage per 0.5 s pulse.
	local puddleTick: number = math.max(1, math.round(attackDamage * 0.3))

	-- ── Freeze lateral drift for a stable cast stance ─────────────
	self:StopMovement()

	-- ── Play cast animation ───────────────────────────────────────
	if self._castTrack then
		self._castTrack:Play(0.1)
	end

	-- Capture the launch origin now (before any hover drift during wind-up).
	local origin: Vector3 = self.RootPart.Position

	-- ── Wind-up delay → launch blob ───────────────────────────────
	task.delay(windup, function()
		if self._destroyed or self.State == AIState.Dead then
			return
		end
		if not target.Character then
			return
		end

		local targetRoot = target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetRoot then
			return
		end

		-- Snapshot target position at windup expiry.
		-- Players who dodge DURING the wind-up will not be where we aimed.
		local targetPos: Vector3 = targetRoot.Position

		-- Delegate all projectile physics, hit detection, damage, and puddle
		-- spawning to ToxicBlobService. HexCaster only triggers the launch.
		getBlobService():FireBlob(origin, targetPos, attackDamage, puddleTick, self.Model)
	end)

	-- ── Attack duration → return to Chase ─────────────────────────
	-- Slightly longer than AnimationDuration (0.55 s > 0.48 s clip) so the
	-- animation fully completes before we evaluate the next attack cycle.
	task.delay(attackDuration, function()
		if self.State == AIState.Attack then
			self._services.notifyAttackEnd(self.Target)
			self.State = AIState.Chase
			self.CurrentAttack = nil
			if self._idleTrack and not self._idleTrack.IsPlaying then
				self._idleTrack:Play(0.3)
			end
		end
	end)
end

-- ── Override: Tick ────────────────────────────────────────────────────────────

--[[
	Extends BaseEnemy:Tick with the per-frame hover correction.

	Order:
	  1. BaseEnemy.Tick(self, dt) — runs the full state machine.
	     • Chase: calls OnChaseOverride → sets self._currentXZVel, returns true.
	     • Attack entry: calls StopMovement → zeroes self._currentXZVel.
	     • Hitstun: calls StopMovement.
	     • Dead: returns early (we skip correction below).
	  2. _applyHoverCorrection() — composes VectorVelocity from _currentXZVel
	     (XZ) + P-controller on Y error. Writes once per tick.
]]
function HexCaster:Tick(dt: number)
	BaseEnemy.Tick(self, dt)

	-- Skip if the base killed us this tick or we were already dead
	if self._destroyed or self.State == AIState.Dead then
		return
	end

	-- Emergency retreat during Attack: if the player walks into our face while
	-- we're mid-cast (Attack state locks XZ to zero via StopMovement), drift
	-- directly away so the caster never just stands frozen in close-quarters.
	if self.State == AIState.Attack and self.Target then
		local targetChar = self.Target.Character
		if targetChar then
			local hrp = targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				local myPos = self.RootPart.Position
				local flatToTarget = Vector3.new(hrp.Position.X - myPos.X, 0, hrp.Position.Z - myPos.Z)
				local flatDist = flatToTarget.Magnitude
				local fleeDist: number = self.Config.FleeDistance or 20
				if flatDist < fleeDist then
					local speed: number = (self.Model:GetAttribute("WalkSpeed") :: number?) or 11
					local awayDir = if flatDist > 0.01 then -flatToTarget.Unit else Vector3.new(1, 0, 0)
					self._currentXZVel = Vector2.new(awayDir.X, awayDir.Z) * speed
				end
			end
		end
	end

	-- Always apply hover — this is the single write point for VectorVelocity
	self:_applyHoverCorrection()
end

-- ── Return ─────────────────────────────────────────────────────────────────────

return HexCaster

--[[
	═══════════════════════════════════════════════════════════════════════════════
	TASK 2 — NON-HUMANOID RIGGING GUIDE (Roblox Studio)
	═══════════════════════════════════════════════════════════════════════════════

	Because HexCaster has no Humanoid, you must set up the rig manually in Studio.
	The key rule: animations are driven by Motor6D joints. WeldConstraints are
	physics-only and are INVISIBLE to the Animator — do NOT use them for any joint
	that an animation will move.

	REQUIRED HIERARCHY IN THE MODEL:
	  HexCaster (Model)
	  ├─ HumanoidRootPart      ← must be the model's PrimaryPart; server owns physics
	  │   └─ RootJoint (Motor6D)
	  │       Part0 = HumanoidRootPart
	  │       Part1 = Torso (or whatever your main body part is named)
	  ├─ Torso                 ← main body mesh
	  │   ├─ UpperArmJoint (Motor6D)   Part0=Torso, Part1=UpperArm
	  │   └─ … (any joints your animations drive)
	  ├─ AnimationController   ← REQUIRED: replaces the Humanoid's animation role
	  │   └─ Animator          ← REQUIRED: child of AnimationController (not Humanoid)
	  └─ … (other parts)

	STEP-BY-STEP IN STUDIO:
	  1. Open the HexCaster model in the Explorer.
	  2. Set HumanoidRootPart as the model's PrimaryPart
	     (Model properties panel → PrimaryPart).
	  3. For each joint between two parts:
	       a. Insert a Motor6D into the PARENT part (e.g. Torso for an arm joint).
	       b. Set Motor6D.Part0 = the parent part (Torso).
	       c. Set Motor6D.Part1 = the child part (UpperArm).
	       d. Set Motor6D.C0 / C1 to the offset CFrames that place the child
	          at the correct rest position relative to the parent.
	       e. DO NOT use WeldConstraint for joints that animations will move.
	          WeldConstraint is physics-only; Animator writes Motor6D.Transform,
	          not Weld offsets.
	  4. Insert AnimationController directly under the Model root.
	  5. Insert Animator as a child of AnimationController.
	     (BaseEnemy._setupAnimator() creates both if they are missing, but having
	     them pre-placed in the asset guarantees the right parent chain.)
	  6. Do NOT add a Humanoid. BaseEnemy._setupAnimator() will destroy any
	     Humanoid it finds on the model before setting up the AnimationController.

	WHY Motor6D AND NOT WeldConstraint:
	  Roblox's Animator works by setting Motor6D.Transform on every frame (the
	  relative CFrame that the clip specifies for that joint). The engine reads
	  the Motor6D hierarchy starting from the root joint and accumulates
	  transforms down the chain — this is how the whole rig deforms.
	  WeldConstraint physically locks two parts together via the physics engine.
	  The Animator has no API to write to a WeldConstraint; it only knows about
	  Motor6D and the equivalent Motor joints. If you weld everything with
	  WeldConstraints, LoadAnimation() will succeed but the playing track will
	  appear to do nothing because there are no Motor6D transforms to update.

	SUMMARY CHECKLIST:
	  [x] HumanoidRootPart exists and is PrimaryPart
	  [x] Every joint between parts uses Motor6D (NOT WeldConstraint)
	  [x] AnimationController is a direct child of the Model
	  [x] Animator is a child of AnimationController
	  [x] NO Humanoid in the model (BaseEnemy destroys it anyway, but clean is better)
	═══════════════════════════════════════════════════════════════════════════════
]]
