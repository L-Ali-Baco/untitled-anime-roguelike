--[[
	BaseEnemy.luau
	Universal parent class for all enemy types.

	Subclasses override:
	  OnAttackEnter()      -- required: perform this enemy's attack
	  OnChaseOverride()    -- optional: return true to suppress base MoveTowardTarget

	Subclass pattern:
	  local Brute = setmetatable({}, { __index = BaseEnemy })
	  Brute.__index = Brute
	  function Brute.new(model, config, services)
	      return setmetatable(BaseEnemy.new(model, config, "Brute", services), Brute)
	  end
	  function Brute:OnAttackEnter() ... end
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(Shared:WaitForChild("Config"):WaitForChild("EnemyConfig"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

-- Lazy-loaded to avoid module load ordering issues (JumpController requires BaseEnemy for AIState).
-- Populated on first use by enemies with Config.CanJump = true.
local JumpController: any = nil
local function getJumpController(): any
	if not JumpController then
		JumpController = require(script.Parent.JumpController)
	end
	return JumpController
end

-- Minimum seconds between ledge/gap probes per enemy (throttles raycast frequency).
local JUMP_CHECK_INTERVAL = 0.35

-- ============================================================
-- EXPORTED CONSTANTS
-- ============================================================

local AIState = {
	Idle = "Idle",
	Chase = "Chase",
	Attack = "Attack",
	LeapAttack = "LeapAttack",
	ChargeAttack = "ChargeAttack",
	Hitstun = "Hitstun",
	Dead = "Dead",
	-- Vertical movement states (requires Config.CanJump = true + animation IDs)
	Jumping = "Jumping", -- airborne, rising after a ledge jump
	Falling = "Falling", -- airborne, descending (gap leap or past jump apex)
	Landing = "Landing", -- brief ground-recovery animation after touching down
}

-- Services bag type — injected at construction to avoid circular requires.
-- EnemyService builds this and passes it to every enemy.new().
export type Services = {
	dealDamage: (player: Player, damage: number, knockback: Vector3?) -> (),
	blockDamage: (player: Player, enemy: Model, position: Vector3, amount: number) -> (),
	fireEnemyAttack: (payload: { [string]: any }) -> (),
	fireEnemyStateChanged: (model: Model, state: string) -> (),
	fireEnemyDied: (payload: { [string]: any }) -> (),
	getIFrameExpiry: (player: Player) -> number?,
	canAttack: (player: Player) -> boolean,
	notifyAttackStart: (player: Player) -> (),
	notifyAttackEnd: (player: Player) -> (),
	-- Flow field navigation (optional — falls back to direct targeting if nil)
	getFlowDirection: ((pos: Vector3, player: Player) -> Vector3)?,
	shouldRebuildFlow: ((player: Player, targetPos: Vector3) -> boolean)?,
	rebuildFlow: ((player: Player, targetPos: Vector3) -> ())?,
}

-- ============================================================
-- CLASS
-- ============================================================

local BaseEnemy = {}
BaseEnemy.__index = BaseEnemy
BaseEnemy.AIState = AIState

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

function BaseEnemy.new(
	model: Model,
	config: { [string]: any },
	enemyType: string,
	services: Services
): any
	-- Resolve root part with broad fallback chain
	local rootPart: BasePart? = (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
		or (model:FindFirstChild("Root") :: BasePart?)
		or (model:FindFirstChild("Torso") :: BasePart?)
		or (model:FindFirstChild("UpperTorso") :: BasePart?)
		or (model:FindFirstChild("Body") :: BasePart?)
		or (model:FindFirstChild("Chest") :: BasePart?)
		or model.PrimaryPart
		or (model:FindFirstChildWhichIsA("BasePart") :: BasePart?)

	if not rootPart then
		error(("[BaseEnemy] No root part found on model: %s"):format(model.Name))
	end

	local self = setmetatable({} :: any, BaseEnemy)

	-- Identity
	self.Model = model
	self.RootPart = rootPart
	self.EnemyType = enemyType
	self.Config = config
	self._services = services
	self._destroyed = false

	-- AI state
	self.State = AIState.Idle
	self.Target = nil :: Player?
	self.LastAttackTime = 0
	self.HitstunEndTime = 0
	self.AggroTime = 0
	self.AttackTriggered = false
	self.CurrentAttack = nil :: any?
	self.LastSpecialTimes = {} :: { [string]: number }

	-- Spawn activation delay (set by EnemyService after construction)
	self._activationEndTime = 0
	-- Attack token system
	self._tokenWaitStart = 0 :: number
	-- Circling direction: +1 or -1, randomised per enemy
	self._circleSign = if math.random() > 0.5 then 1 else -1

	-- ── Vertical movement (Jumping / Falling / Landing) ───────────────────────
	-- XZ velocity locked during airborne states so Separation can't deflect mid-arc.
	self._jumpTrajectory = Vector2.zero
	-- os.clock() expiry for the Falling grace period (don't check landing immediately).
	self._fallingGraceEnd = 0
	-- os.clock() expiry for the Landing recovery animation.
	self._landRecoveryEnd = 0
	-- Throttle: only run JumpController probes at JUMP_CHECK_INTERVAL Hz.
	self._lastJumpCheckTime = 0
	-- Animation tracks for airborne states (populated by _setupAnimator if config has IDs).
	self.JumpTrack = nil :: AnimationTrack?
	self.FallTrack = nil :: AnimationTrack?
	self.LandTrack = nil :: AnimationTrack?

	-- Movement state
	self.IsMoving = false
	self.LastMoveTarget = nil :: Vector3?
	self.LastPos = nil :: Vector3?
	self.LastPosTime = nil :: number?

	-- Physics constraints (populated by _setupPhysics)
	self.LinearVelocity = nil :: LinearVelocity?
	self.AlignOrientation = nil :: AlignOrientation?

	-- Animation (populated by _setupAnimator)
	self.Animator = nil :: Animator?
	self.WalkTrack = nil :: AnimationTrack?

	self:_setupPhysics()
	self:_setupAnimator()
	self:_registerAttributes()

	-- Tag the model so ComicShaderController (client) discovers it via CollectionService.
	-- This fires on every enemy spawn regardless of which subclass constructs it.
	CollectionService:AddTag(self.Model, "Enemy")

	return self
end

-- ============================================================
-- PRIVATE: SETUP
-- ============================================================

function BaseEnemy:_setupPhysics()
	local rootPart = self.RootPart
	local model = self.Model

	-- Server owns all enemy physics
	rootPart:SetNetworkOwner(nil)

	-- Disable CanCollide on every part, massless on non-root
	-- Collision is handled by an invisible GroundCollision box below
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Enemies"
			part.CanCollide = false
			if part ~= rootPart then
				part.Massless = true
			end
		end
	end

	-- Invisible collision box: root part → feet, keeps enemy at correct height
	local modelCF, modelSize = model:GetBoundingBox()
	local feetY = modelCF.Position.Y - modelSize.Y / 2
	local distToFeet = rootPart.Position.Y - feetY
	local boxHeight = math.max(0.5, distToFeet + rootPart.Size.Y * 0.5)

	local collisionBox = Instance.new("Part")
	collisionBox.Name = "GroundCollision"
	collisionBox.Transparency = 1
	collisionBox.CanCollide = true
	collisionBox.CanQuery = false
	collisionBox.CanTouch = false
	collisionBox.Massless = true
	collisionBox.Size = Vector3.new(rootPart.Size.X, boxHeight, rootPart.Size.Z)
	collisionBox.CollisionGroup = "Enemies"
	collisionBox.CFrame = rootPart.CFrame * CFrame.new(0, -distToFeet + boxHeight / 2, 0)
	collisionBox.Parent = model

	local collisionWeld = Instance.new("WeldConstraint")
	collisionWeld.Part0 = rootPart
	collisionWeld.Part1 = collisionBox
	collisionWeld.Parent = collisionBox

	-- LinearVelocity in Plane mode: drives XZ, gravity handles Y
	local attachment = rootPart:FindFirstChild("RootAttachment") :: Attachment?
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "RootAttachment"
		attachment.Parent = rootPart
	end

	local lv = Instance.new("LinearVelocity")
	lv.Name = "EnemyMoveVelocity"
	lv.Attachment0 = attachment
	lv.MaxForce = 50000
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	lv.PlaneVelocity = Vector2.zero
	lv.Parent = rootPart
	self.LinearVelocity = lv

	-- AlignOrientation: keeps enemy upright and drives rotation toward target
	local alignAttachment = Instance.new("Attachment")
	alignAttachment.Name = "AlignAttachment"
	alignAttachment.Parent = rootPart

	local ao = Instance.new("AlignOrientation")
	ao.Name = "EnemyAlignOrientation"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = alignAttachment
	ao.CFrame = rootPart.CFrame
	ao.MaxTorque = math.huge
	ao.MaxAngularVelocity = math.huge
	ao.Responsiveness = 200
	ao.RigidityEnabled = true
	ao.Parent = rootPart
	self.AlignOrientation = ao
end

function BaseEnemy:_setupAnimator()
	local model = self.Model

	-- Strip any leftover Humanoid from the asset (we are Humanoid-free)
	local existingHumanoid = model:FindFirstChildOfClass("Humanoid")
	if existingHumanoid then
		existingHumanoid:Destroy()
	end

	local animController = model:FindFirstChildOfClass("AnimationController")
	if not animController then
		animController = Instance.new("AnimationController")
		animController.Parent = model
	end

	local animator = animController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animController
	end
	self.Animator = animator

	-- Preload walk animation if the config defines one
	local walkId: string? = self.Config.WalkAnimationId
	if walkId and animator then
		local ok, result = pcall(function()
			local walkAnim = Instance.new("Animation")
			walkAnim.AnimationId = walkId
			local track = animator:LoadAnimation(walkAnim)
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Movement
			track:AdjustSpeed(self.Config.WalkAnimationSpeed or 1)
			return track
		end)
		if ok then
			self.WalkTrack = result
		else
			warn(("[BaseEnemy] Walk animation failed for %s: %s"):format(self.EnemyType, result))
		end
	end

	-- ── Vertical movement animations (loaded only if config provides IDs) ─────
	-- Priority = Action so they override Walk/Idle which are Movement priority.
	-- JumpAnim: Looped = false (one-shot rising arc).
	-- FallAnim: Looped = true  (held until landing).
	-- LandAnim: Looped = false (one-shot recovery impact).
	local function _loadAnim(animId: string, looped: boolean): AnimationTrack?
		if not animator then
			return nil
		end
		local ok, result = pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			local track = animator:LoadAnimation(anim)
			track.Looped = looped
			track.Priority = Enum.AnimationPriority.Action
			return track
		end)
		if ok then
			return result :: AnimationTrack
		end
		return nil
	end

	if self.Config.JumpAnimationId then
		self.JumpTrack = _loadAnim(self.Config.JumpAnimationId, false)
	end
	if self.Config.FallAnimationId then
		self.FallTrack = _loadAnim(self.Config.FallAnimationId, true)
	end
	if self.Config.LandAnimationId then
		self.LandTrack = _loadAnim(self.Config.LandAnimationId, false)
	end
end

function BaseEnemy:_registerAttributes()
	local model = self.Model

	-- Tag for combat targeting system
	CollectionService:AddTag(model, CombatConfig.Targeting.TargetTag)

	-- Attributes read by client VFX controllers
	model:SetAttribute("EnemyType", self.EnemyType)
	if self.Config.FacingOffset and self.Config.FacingOffset ~= 0 then
		model:SetAttribute("FacingOffset", self.Config.FacingOffset)
	end

	-- Death: IsDead attribute is set by CombatService when health hits 0
	model:GetAttributeChangedSignal("IsDead"):Connect(function()
		if model:GetAttribute("IsDead") then
			self:_onDeath()
		end
	end)

	-- Hitstun: apply on any health decrease
	local lastHealth: number = (model:GetAttribute("Health") :: number?) or self.Config.Health or 1
	model:GetAttributeChangedSignal("Health"):Connect(function()
		local newHealth: number = (model:GetAttribute("Health") :: number?) or 0
		if newHealth < lastHealth then
			self:ApplyHitstun()
		end
		lastHealth = newHealth
	end)

	print(("[BaseEnemy] %s registered as %s"):format(model.Name, self.EnemyType))
end

-- ============================================================
-- PRIVATE: DEATH
-- ============================================================

function BaseEnemy:_onDeath()
	if self._destroyed then
		return
	end
	self._destroyed = true
	-- Release attack token if dying mid-attack
	if self.State == AIState.Attack or self.State == AIState.LeapAttack or self.State == AIState.ChargeAttack then
		if self.Target then
			self._services.notifyAttackEnd(self.Target)
		end
	end
	self.State = AIState.Dead

	self:StopMovement()
	if self.WalkTrack and self.WalkTrack.IsPlaying then
		self.WalkTrack:Stop(0)
	end

	-- Fire death event — EnemyService listens to remove from activeEnemies
	self._services.fireEnemyDied({
		Target = self.Model,
		Killer = self.Target,
		Position = self.RootPart.Position,
	})

	-- Disable physics queries so projectiles pass through the corpse
	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
			part.CanTouch = false
			part.CollisionGroup = "Debris"
		end
	end

	-- Destroy model after death animation finishes
	local model = self.Model
	task.delay(EnemyConfig.Death.RagdollDuration + EnemyConfig.Death.FadeOutDuration, function()
		if model and model.Parent then
			model:Destroy()
		end
	end)
end

-- ============================================================
-- PRIVATE: LANDING
-- ============================================================

--[[
	Called when the enemy touches the ground after Jumping or Falling.
	Plays the LandAnim, locks movement for LandRecoveryTime, then returns to Chase.

	LandRecoveryTime is defined per-enemy in EnemyConfig (e.g. 0.4s for Brute,
	0s for light enemies). Heavy enemies stagger visibly; light ones snap back
	to chase immediately.
]]
function BaseEnemy:_onLand()
	if self._destroyed then
		return
	end

	-- Zero out airborne velocity so the enemy doesn't slide on landing.
	self._jumpTrajectory = Vector2.zero
	if self.LinearVelocity then
		self.LinearVelocity.PlaneVelocity = Vector2.zero
	end

	-- Stop any active airborne track.
	if self.FallTrack and self.FallTrack.IsPlaying then
		self.FallTrack:Stop(0.05)
	end
	if self.JumpTrack and self.JumpTrack.IsPlaying then
		self.JumpTrack:Stop(0.05)
	end

	-- Play the one-shot landing impact animation.
	if self.LandTrack then
		self.LandTrack:Play(0.05)
	end

	local recoveryTime: number = self.Config.LandRecoveryTime or 0
	self._landRecoveryEnd = os.clock() + recoveryTime

	-- If there's no recovery time, go straight back to Chase.
	if recoveryTime <= 0 then
		self.State = AIState.Chase
		if self.WalkTrack and not self.WalkTrack.IsPlaying then
			self.WalkTrack:Play(0.2)
		end
		self._services.fireEnemyStateChanged(self.Model, AIState.Chase)
	else
		-- Enter brief Landing state for the recovery window.
		self.State = AIState.Landing
		self._services.fireEnemyStateChanged(self.Model, AIState.Landing)
	end
end

-- ============================================================
-- PUBLIC: MOVEMENT
-- ============================================================

function BaseEnemy:StopMovement()
	if self.LinearVelocity then
		self.LinearVelocity.PlaneVelocity = Vector2.zero
	end
	self.IsMoving = false
	self.LastMoveTarget = nil
end

function BaseEnemy:MoveTowardTarget(targetPos: Vector3)
	local currentPos = self.RootPart.Position
	local fullDiff = targetPos - currentPos
	local horizDist = Vector3.new(fullDiff.X, 0, fullDiff.Z).Magnitude
	local vertDist = math.abs(fullDiff.Y)

	-- If target is mostly above/below (player on a platform), stop horizontal chase
	if vertDist > horizDist * 1.5 and vertDist > 4 then
		self:StopMovement()
		return
	end

	local stopDist = self.Config.StopDistanceFromTarget or 2.5
	local startChaseDist = stopDist + 1.5 -- Hysteresis buffer to prevent jitter

	if horizDist <= stopDist then
		self:StopMovement()
		return
	end

	-- Hysteresis: don't re-engage movement while still in the buffer zone
	if not self.IsMoving and horizDist < startChaseDist then
		return
	end

	-- Unstuck detection: if moving but not progressing, jump over obstacle
	local needsNewMove = (not self.LastMoveTarget) or (targetPos - self.LastMoveTarget).Magnitude > 2
	if self.IsMoving then
		local now = os.clock()
		if not self.LastPos then
			self.LastPos = currentPos
			self.LastPosTime = now
		elseif now - (self.LastPosTime or 0) > 1.0 then
			local distMoved = (currentPos - self.LastPos).Magnitude
			if distMoved < 1.0 then
				self.RootPart.AssemblyLinearVelocity = Vector3.new(0, 30, 0)
				needsNewMove = true
			end
			self.LastPos = currentPos
			self.LastPosTime = now
		end
	end

	if needsNewMove and self.LinearVelocity then
		-- ── Flow field navigation ─────────────────────────────────────────────
		-- Prefer the flow field direction (obstacle-aware) when available.
		-- Falls back to the direct vector if the flow field is missing or returns zero.
		--
		-- SELF-DEDUPLICATION: The first enemy that calls rebuildFlow() in a
		-- given AI Heartbeat updates FlowFieldService.lastTargetPos. All
		-- subsequent enemies asking ShouldRebuild() in the same batch see
		-- false — one BFS per player-cell-change, regardless of enemy count.
		local direction = Vector3.new(fullDiff.X, 0, fullDiff.Z)

		if self._services.getFlowDirection and self.Target then
			if self._services.shouldRebuildFlow and self._services.shouldRebuildFlow(self.Target, targetPos) then
				if self._services.rebuildFlow then
					self._services.rebuildFlow(self.Target, targetPos)
				end
			end
			local flowDir = self._services.getFlowDirection(self.RootPart.Position, self.Target)
			if flowDir.Magnitude > 0.1 then
				direction = flowDir
			end
		end

		if direction.Magnitude > 0.1 then
			local speed: number = (self.Model:GetAttribute("WalkSpeed") :: number?) or 14
			local dir2D = direction.Unit
			self.LinearVelocity.PlaneVelocity = Vector2.new(dir2D.X, dir2D.Z) * speed
		end
		self.IsMoving = true
		self.LastMoveTarget = targetPos
	end
end

function BaseEnemy:FaceToward(targetPos: Vector3)
	local rootPos = self.RootPart.Position
	local fullDir = targetPos - rootPos
	local horizDir = Vector3.new(fullDir.X, 0, fullDir.Z)
	local horizDist = horizDir.Magnitude
	local vertDist = math.abs(fullDir.Y)

	-- Skip if target is directly above/below or too close horizontally
	if horizDist < 3 or vertDist > horizDist * 1.5 then
		return
	end

	local facingOffset = math.rad(self.Config.FacingOffset or 0)
	local targetCFrame = CFrame.lookAt(rootPos, rootPos + horizDir) * CFrame.Angles(0, facingOffset, 0)

	if self.AlignOrientation then
		self.AlignOrientation.CFrame = targetCFrame
	else
		self.RootPart.CFrame = self.RootPart.CFrame:Lerp(targetCFrame, 0.2)
	end
end

--[[
	Orbit the target at close range while waiting for an attack token.
	Moves perpendicular to the target direction (left or right based on _circleSign).
	Speed is 70% of walk speed to give a stalking feel.
]]
function BaseEnemy:_doCircle(targetPos: Vector3)
	local myPos = self.RootPart.Position
	local toTarget = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
	if toTarget.Magnitude < 0.1 then
		return
	end

	local flatDir = toTarget.Unit
	-- Perpendicular direction (rotate 90° in the XZ plane)
	local perpDir = Vector3.new(-flatDir.Z * self._circleSign, 0, flatDir.X * self._circleSign)

	local speed: number = ((self.Model:GetAttribute("WalkSpeed") :: number?) or 14) * 0.7
	if self.LinearVelocity then
		self.LinearVelocity.PlaneVelocity = Vector2.new(perpDir.X, perpDir.Z) * speed
	end
	self.IsMoving = true
	self:FaceToward(targetPos)
end

-- ============================================================
-- PUBLIC: AI
-- ============================================================

function BaseEnemy:IsAlive(): boolean
	return EnemyLib:IsAlive(self.Model)
end

--[[
	Apply hitstun. Reduces duration by KnockbackResistance.
	Delays velocity zeroing 0.15s so the knockback impulse plays out visually.
]]
function BaseEnemy:ApplyHitstun(duration: number?)
	if self.State == AIState.Dead or self._destroyed then
		return
	end

	local resistance = self.Config.KnockbackResistance or 0
	local hitstunDuration = (duration or self.Config.HitstunDuration or 0.3) * (1 - resistance)
	if hitstunDuration <= 0 then
		return
	end

	local oldState = self.State
	self.State = AIState.Hitstun
	-- Release attack token if hitstunned mid-attack
	if oldState == AIState.Attack or oldState == AIState.LeapAttack or oldState == AIState.ChargeAttack then
		if self.Target then
			self._services.notifyAttackEnd(self.Target)
		end
	end
	self.HitstunEndTime = os.clock() + hitstunDuration

	self.IsMoving = false
	self.LastMoveTarget = nil

	if self.WalkTrack and self.WalkTrack.IsPlaying then
		self.WalkTrack:Stop(0.1)
	end
	if self.LinearVelocity then
		self.LinearVelocity.VectorVelocity = Vector3.zero
	end

	-- Allow knockback impulse to travel before zeroing velocity
	task.delay(0.15, function()
		if not self.RootPart or not self.RootPart.Parent then
			return
		end
		if self.State ~= AIState.Hitstun then
			return
		end
		local vel = self.RootPart.AssemblyLinearVelocity
		self.RootPart.AssemblyLinearVelocity = Vector3.new(0, math.min(vel.Y, 0), 0)
	end)

	if oldState ~= AIState.Hitstun then
		self._services.fireEnemyStateChanged(self.Model, AIState.Hitstun)
	end
end

-- ============================================================
-- VIRTUAL HOOKS (subclasses override these)
-- ============================================================

--[[
	Called exactly once when the enemy enters Attack state.
	MUST be overridden. Base implementation does a generic melee hit.
]]
function BaseEnemy:OnAttackEnter()
	self:_doStandardAttack(nil)
end

--[[
	Called every Tick while in Chase state, after the base target validation.
	Return true to suppress base MoveTowardTarget + FaceToward.
	Use for: Shooter retreat, Brute gap-closer checks, patrol routes.
]]
function BaseEnemy:OnChaseOverride(_targetPos: Vector3, _distance: number): boolean
	return false
end

-- ============================================================
-- INTERNAL: ATTACK UTILITIES
-- ============================================================

--[[
	Generic attack: play animation, wait windup, hit detection, apply damage.
	Used by simple enemies and as a fallback. Subclasses call this directly
	or call it with a specific attackData table from their Attacks config.
]]
function BaseEnemy:_doStandardAttack(attackData: { [string]: any }?)
	local config = self.Config
	local target = self.Target
	if not target then
		return
	end

	local windup: number = if attackData then attackData.Windup else (config.AttackWindup or 0.3)
	local attackDamage: number = if attackData then attackData.Damage else (config.Damage or 5)
	local forwardDist: number = if attackData then attackData.ForwardDist else 4
	local hitRadius: number = if attackData then attackData.HitRadius else 15
	local vfxType: string? = if attackData then attackData.VFXType else nil
	local attackDuration: number = if attackData then attackData.Duration else (config.AttackDuration or 0.6)
	local animId: string? = if attackData then attackData.AnimationId else config.SlamAnimationId

	-- Play animation
	if animId and self.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = animId :: string
			local track = (self.Animator :: Animator):LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = false
			track:Play()
			if attackData and attackData.SpeedCurve then
				self:_applySpeedCurve(track, attackDuration, attackData.SpeedCurve)
			end
		end)
	end

	-- Delayed hit detection after windup
	task.delay(windup, function()
		if not self.RootPart or not self.RootPart.Parent or self.State == AIState.Dead then
			return
		end

		-- Impact position: in front of enemy on the ground
		local facingOffsetRad = math.rad(config.FacingOffset or 0)
		local visualForward = if facingOffsetRad ~= 0
			then (self.RootPart.CFrame * CFrame.Angles(0, -facingOffsetRad, 0)).LookVector
			else self.RootPart.CFrame.LookVector
		local impactPos = self.RootPart.Position + (visualForward * forwardDist)

		-- Raycast to find actual floor
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
		local rayOrigin = Vector3.new(impactPos.X, self.RootPart.Position.Y + 5, impactPos.Z)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), rayParams)
		if rayResult then
			impactPos = rayResult.Position
		else
			impactPos = Vector3.new(impactPos.X, self.RootPart.Position.Y - 3, impactPos.Z)
		end

		-- VFX always fires (even if hit misses)
		self._services.fireEnemyAttack({
			Enemy = self.Model,
			Target = target,
			HitPosition = impactPos,
			Damage = attackDamage,
			AttackType = vfxType,
			IsSlam = (vfxType == "Slam"),
		})

		-- Hit detection
		local character = target.Character
		if not character then
			return
		end
		local targetRoot: BasePart? = (character:FindFirstChild("HumanoidRootPart") :: BasePart?)
			or (character:FindFirstChild("Root") :: BasePart?)
		if not targetRoot then
			return
		end

		-- Miss check: use direct enemy-to-player distance at the moment of impact.
		-- This is more reliable than projecting an impactPos because Boids separation
		-- or hitstun can drift the enemy sideways during the windup, making the
		-- projected impactPos stale. The rule: if the enemy moved further than its
		-- strike reach (forwardDist + AttackRange + a small grace buffer), the swing
		-- missed. The impactPos is still used for VFX positioning above.
		local distToEnemy = (targetRoot.Position - self.RootPart.Position).Magnitude
		local strikeReach = forwardDist + (config.AttackRange or 5) + 3
		if distToEnemy > strikeReach then
			return -- Missed: enemy drifted out of strike range during windup
		end

		local hum = character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return
		end

		-- I-frame check
		local iframeExpiry = self._services.getIFrameExpiry(target)
		if iframeExpiry and os.clock() < iframeExpiry then
			self._services.blockDamage(target, self.Model, targetRoot.Position, attackDamage)
			return
		end

		local knockbackDir = (targetRoot.Position - self.RootPart.Position)
		knockbackDir = Vector3.new(knockbackDir.X, 0.3, knockbackDir.Z).Unit
		self._services.dealDamage(target, attackDamage, knockbackDir * 20)
	end)

	-- Return to Chase after full attack duration.
	-- IMPORTANT: notifyAttackEnd must be called HERE, not relied on in Tick's
	-- state-transition block. The task.delay callback fires between Ticks, so
	-- when Tick next runs oldState == Chase (already changed) and the
	-- "wasAttacking → not attacking" branch is never reached — causing a
	-- permanent token leak that blocks all further attacks after 2 total hits.
	task.delay(attackDuration, function()
		if self.State == AIState.Attack then
			if self.Target then
				self._services.notifyAttackEnd(self.Target)
			end
			self.State = AIState.Chase
			self.CurrentAttack = nil
			if self.WalkTrack and not self.WalkTrack.IsPlaying then
				self.WalkTrack:Play(0.2)
			end
		end
	end)
end

--[[
	Applies a speed curve to an AnimationTrack over its duration.
	curve = { {timeFraction, speed}, ... } — linearly interpolated.
]]
function BaseEnemy:_applySpeedCurve(track: AnimationTrack, duration: number, curve: { { number } })
	task.spawn(function()
		local startTime = os.clock()
		while os.clock() - startTime < duration do
			local t = math.clamp((os.clock() - startTime) / duration, 0, 1)
			local speed = curve[1][2]
			for i = 1, #curve - 1 do
				local k0, k1 = curve[i], curve[i + 1]
				if t >= k0[1] and t <= k1[1] then
					local alpha = (t - k0[1]) / (k1[1] - k0[1])
					speed = k0[2] + (k1[2] - k0[2]) * alpha
					break
				elseif t > k1[1] then
					speed = k1[2]
				end
			end
			track:AdjustSpeed(speed)
			task.wait()
		end
	end)
end

-- ============================================================
-- INTERNAL: TARGET HELPERS
-- ============================================================

function BaseEnemy:_getNearestPlayer(range: number): Player?
	local nearest: Player? = nil
	local nearestDist = range
	local myPos = self.RootPart.Position

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then
			continue
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			continue
		end
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end
		local dist = (root.Position - myPos).Magnitude
		if dist < nearestDist then
			nearestDist = dist
			nearest = player
		end
	end

	return nearest
end

function BaseEnemy:_getTargetPosition(): Vector3?
	if not self.Target then
		return nil
	end
	local char = self.Target.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

function BaseEnemy:_isTargetValid(): boolean
	if not self.Target then
		return false
	end
	local char = self.Target.Character
	if not char then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return false
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	return (root.Position - self.RootPart.Position).Magnitude <= EnemyConfig.Aggro.ChaseRange
end

-- ============================================================
-- MAIN AI TICK — called by EnemyService Heartbeat every UpdateRate seconds
-- ============================================================

function BaseEnemy:Tick(_dt: number)
	if self._destroyed then
		return
	end

	-- Attribute-based alive check (avoids Humanoid dependency)
	if not self:IsAlive() then
		if self.State ~= AIState.Dead then
			self.State = AIState.Dead
			self._services.fireEnemyStateChanged(self.Model, AIState.Dead)
		end
		return
	end

	local now = os.clock()
	local oldState = self.State
	local config = self.Config

	-- ── Spawn Activation Delay ─────────────────────────────────────────
	-- New enemies are frozen for ActivationDelay seconds after spawning.
	-- This gives players a reaction window and prevents instant-aggro pop-in.
	if now < self._activationEndTime then
		return
	end

	-- ── Hitstun ────────────────────────────────────────────────────────
	if self.State == AIState.Hitstun then
		if now >= self.HitstunEndTime then
			self.State = AIState.Idle
		else
			return -- Still stunned
		end
	end

	-- ── Idle ───────────────────────────────────────────────────────────
	if self.State == AIState.Idle then
		local aggroRange = config.AggroRange or EnemyConfig.Aggro.DetectionRange
		local player = self:_getNearestPlayer(aggroRange)
		if player then
			self.Target = player
			self.State = AIState.Chase
			self.AggroTime = now
			if self.WalkTrack and not self.WalkTrack.IsPlaying then
				self.WalkTrack:Play(0.3)
			end
		end

	-- ── Chase ──────────────────────────────────────────────────────────
	elseif self.State == AIState.Chase then
		if not self:_isTargetValid() then
			self.Target = nil
			self.State = AIState.Idle
			self:StopMovement()
			if self.WalkTrack and self.WalkTrack.IsPlaying then
				self.WalkTrack:Stop(0.2)
			end
			return
		end

		local targetPos = self:_getTargetPosition()
		if not targetPos then
			return
		end

		local distance = (targetPos - self.RootPart.Position).Magnitude

		-- Subclass gets first chance to handle movement (retreat, gap-closer, etc.)
		local handled = self:OnChaseOverride(targetPos, distance)
		if not handled then
			local attackRange = config.AttackRange or 4
			if distance <= attackRange then
				if now - self.LastAttackTime >= (config.AttackCooldown or 1.5) then
					-- Attack token check: only enter Attack if a slot is available
					if self._services.canAttack(self.Target) then
						self.State = AIState.Attack
						self.LastAttackTime = now
						self.AttackTriggered = false
						self.CurrentAttack = nil
						self._tokenWaitStart = 0
						self:StopMovement()
						if self.WalkTrack and self.WalkTrack.IsPlaying then
							self.WalkTrack:Stop(0.15)
						end
					else
						-- Token denied: orbit the player while waiting for a slot
						if self._tokenWaitStart == 0 then
							self._tokenWaitStart = now
						end
						self:_doCircle(targetPos)
					end
				end
			else
				self._tokenWaitStart = 0

				-- ── JumpController probe (throttled, opt-in via Config.CanJump) ──
				-- Probes once per JUMP_CHECK_INTERVAL seconds. If a ledge or gap
				-- is detected DoLedgeJump/DoGapLeap mutates State = Jumping/Falling
				-- so MoveTowardTarget below is skipped this tick.
				local jumpHandled = false
				if config.CanJump and (now - self._lastJumpCheckTime) >= JUMP_CHECK_INTERVAL then
					self._lastJumpCheckTime = now
					local fullDiff = targetPos - self.RootPart.Position
					local moveDir = Vector3.new(fullDiff.X, 0, fullDiff.Z)
					if moveDir.Magnitude > 0.1 then
						moveDir = moveDir.Unit
						local jc = getJumpController()
						-- Ledge: geometry at foot level but clear at chest → climbable.
						local ledge = jc.CheckLedge(self, moveDir)
						if ledge then
							jc.DoLedgeJump(self, moveDir, ledge.jumpPower)
							jumpHandled = true
						else
							-- Gap: no floor ahead, but safe ground below the drop.
							local gap = jc.CheckGap(self, moveDir)
							if gap then
								jc.DoGapLeap(self, moveDir, gap.dropDepth)
								jumpHandled = true
							end
						end
					end
				end

				if not jumpHandled then
					self:MoveTowardTarget(targetPos)
					self:FaceToward(targetPos)
				end
			end
		end

	-- ── Attack ─────────────────────────────────────────────────────────
	elseif self.State == AIState.Attack then
		local lookAt = self:_getTargetPosition() or self.RootPart.Position + self.RootPart.CFrame.LookVector
		self:FaceToward(lookAt)

		if not self.AttackTriggered then
			self.AttackTriggered = true
			self:OnAttackEnter() -- Delegate to subclass
		end

	-- ── LeapAttack / ChargeAttack ──────────────────────────────────────
	-- These special states are driven by coroutines spawned in the subclass.
	-- The base Tick does nothing here — the coroutine manages transitions.

	-- ── Jumping ─────────────────────────────────────────────────────────
	-- Enemy is airborne and rising (applied via AssemblyLinearVelocity.Y).
	-- XZ is locked to _jumpTrajectory so Separation can't deflect mid-arc.
	elseif self.State == AIState.Jumping then
		if self.LinearVelocity and self._jumpTrajectory ~= Vector2.zero then
			self.LinearVelocity.PlaneVelocity = self._jumpTrajectory
		end
		-- Transition to Falling once we're past the apex (Y velocity negative).
		if self.RootPart.AssemblyLinearVelocity.Y < -1 then
			self.State = AIState.Falling
			self._fallingGraceEnd = now + 0.1
			if self.JumpTrack and self.JumpTrack.IsPlaying then
				self.JumpTrack:Stop(0.1)
			end
			if self.FallTrack then
				self.FallTrack:Play(0.05)
			end
		end

	-- ── Falling ──────────────────────────────────────────────────────────
	-- Enemy is airborne and descending (gap leap or past jump apex).
	-- XZ locked; check for landing after the grace period.
	elseif self.State == AIState.Falling then
		if self.LinearVelocity and self._jumpTrajectory ~= Vector2.zero then
			self.LinearVelocity.PlaneVelocity = self._jumpTrajectory
		end
		if now >= self._fallingGraceEnd then
			local jc = getJumpController()
			if jc.IsGrounded(self) then
				self:_onLand()
			end
		end

	-- ── Landing ───────────────────────────────────────────────────────────
	-- Brief recovery animation after touching down (LandRecoveryTime config).
	-- Movement is locked. Transitions back to Chase when timer expires.
	elseif self.State == AIState.Landing then
		if self.LinearVelocity then
			self.LinearVelocity.PlaneVelocity = Vector2.zero
		end
		if now >= self._landRecoveryEnd then
			self.State = AIState.Chase
			if self.LandTrack and self.LandTrack.IsPlaying then
				self.LandTrack:Stop(0.2)
			end
			if self.WalkTrack and not self.WalkTrack.IsPlaying then
				self.WalkTrack:Play(0.2)
			end
		end

	end

	-- Broadcast state transition to clients (for VFX/animation)
	-- Also maintain attack token counter when crossing attack/non-attack boundary.
	if self.State ~= oldState then
		local wasAttacking = oldState == AIState.Attack or oldState == AIState.LeapAttack or oldState == AIState.ChargeAttack
		local isAttacking = self.State == AIState.Attack or self.State == AIState.LeapAttack or self.State == AIState.ChargeAttack
		if wasAttacking and not isAttacking then
			if self.Target then
				self._services.notifyAttackEnd(self.Target)
			end
		elseif isAttacking and not wasAttacking then
			if self.Target then
				self._services.notifyAttackStart(self.Target)
			end
		end
		self._services.fireEnemyStateChanged(self.Model, self.State)
	end
end

return BaseEnemy
