--[[
	Shooter.luau
	Ranged enemy. Inherits from BaseEnemy.

	Custom behavior:
	  - OnChaseOverride: fully manages its own movement every tick
	      · Retreat when player is closer than FleeDistance
	      · Stand and shoot when player is within AttackRange
	      · Advance when player is beyond PreferredDistance
	  - OnAttackEnter: fires a hitscan shot (with optional line-of-sight check)
	    and replicates a Projectile VFX event so the client can render the bolt.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local _Shared = ReplicatedStorage:WaitForChild("Shared") -- only needed for future config imports

local BaseEnemy = require(script.Parent.BaseEnemy)
local AIState = BaseEnemy.AIState

-- ============================================================
-- CLASS
-- ============================================================

local Shooter = setmetatable({}, { __index = BaseEnemy })
Shooter.__index = Shooter

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

function Shooter.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "Shooter", services)
	return setmetatable(self, Shooter)
end

-- ============================================================
-- OVERRIDE: OnChaseOverride
--
-- Shooter completely owns its positional logic every chase tick.
-- Returning true always suppresses base MoveTowardTarget.
--
-- Distance bands (configurable in EnemyConfig.Types.Shooter):
--   < FleeDistance    → retreat directly away, keep facing player
--   < AttackRange     → stand still, face player, fire when cooldown allows
--   < PreferredDist   → stand still, face player (already in good spot)
--   > PreferredDist   → advance toward player
-- ============================================================

function Shooter:OnChaseOverride(targetPos: Vector3, distance: number): boolean
	local config = self.Config
	local fleeDist: number = config.FleeDistance or 8
	local preferredDist: number = config.PreferredDistance or 20
	local attackRange: number = config.AttackRange or 25
	local now = os.clock()

	-- ── Retreat: player invaded our personal space ─────────────────
	if distance < fleeDist then
		local myPos = self.RootPart.Position
		local awayDir = Vector3.new(myPos.X - targetPos.X, 0, myPos.Z - targetPos.Z)
		if awayDir.Magnitude > 0.1 then
			awayDir = awayDir.Unit
			local speed: number = (self.Model:GetAttribute("WalkSpeed") :: number?) or 12
			if self.LinearVelocity then
				self.LinearVelocity.PlaneVelocity = Vector2.new(awayDir.X, awayDir.Z) * speed
			end
			self.IsMoving = true
		end
		self:FaceToward(targetPos) -- Keep facing while running away
		return true
	end

	-- ── In attack range: stop, face, shoot ─────────────────────────
	if distance <= attackRange then
		self:StopMovement()
		self:FaceToward(targetPos)

		if now - self.LastAttackTime >= (config.AttackCooldown or 2.0) then
			self.State = AIState.Attack
			self.LastAttackTime = now
			self.AttackTriggered = false
			self.CurrentAttack = nil
		end

		return true
	end

	-- ── Too far: advance to preferred distance ──────────────────────
	if distance > preferredDist + 2 then
		self:MoveTowardTarget(targetPos)
		self:FaceToward(targetPos)
	else
		-- Already comfortable — stop and face
		self:StopMovement()
		self:FaceToward(targetPos)
	end

	return true -- We always manage our own movement
end

-- ============================================================
-- OVERRIDE: OnAttackEnter
-- Fires a hitscan shot at the target with a windup delay.
-- Replicates "Projectile" VFX type to client for bolt rendering.
-- ============================================================

function Shooter:OnAttackEnter()
	local config = self.Config
	local target = self.Target
	if not target then
		self.State = AIState.Chase
		return
	end

	local attackDuration: number = config.AttackDuration or 0.5
	local attackDamage: number = config.Damage or 8
	local windup: number = config.AttackWindup or 0.4

	-- Play shoot animation if configured
	if config.ShootAnimationId and self.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = config.ShootAnimationId
			local track = (self.Animator :: Animator):LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = false
			track:Play()
		end)
	end

	-- Origin captured now (before windup), so the bolt fires from where we stood
	local origin = self.RootPart.Position

	task.delay(windup, function()
		if not self.RootPart or not self.RootPart.Parent or self.State == AIState.Dead then
			return
		end
		if not target.Character then
			return
		end

		local targetRoot = target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetRoot then
			return
		end

		-- Fire VFX: client renders the bolt from origin → hitPos
		self._services.fireEnemyAttack({
			Enemy = self.Model,
			Target = target,
			HitPosition = targetRoot.Position,
			Damage = attackDamage,
			AttackType = "Projectile",
			Origin = origin,
		})

		-- Optional: line-of-sight check before applying damage
		-- (Uncomment to block shots through walls)
		--[[
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { self.Model, target.Character }
		local los = workspace:Raycast(origin, (targetRoot.Position - origin).Unit * 200, rayParams)
		if los then
			return -- Blocked by environment
		end
		]]

		-- I-frame check
		local iframeExpiry = self._services.getIFrameExpiry(target)
		if iframeExpiry and os.clock() < iframeExpiry then
			self._services.blockDamage(target, self.Model, targetRoot.Position, attackDamage)
			return
		end

		local hum = target.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return
		end

		-- Light knockback (it's a projectile, not a melee slam)
		local knockbackDir = (targetRoot.Position - origin)
		knockbackDir = Vector3.new(knockbackDir.X, 0.1, knockbackDir.Z).Unit
		self._services.dealDamage(target, attackDamage, knockbackDir * 10)
	end)

	-- Return to Chase (i.e. stay in range, re-enter OnChaseOverride) after attack
	task.delay(attackDuration, function()
		if self.State == AIState.Attack then
			self.State = AIState.Chase
			self.CurrentAttack = nil
		end
	end)
end

return Shooter
