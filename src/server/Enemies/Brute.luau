--[[
	Brute.luau
	Heavy melee enemy. Inherits from BaseEnemy.

	Custom behavior:
	  - Multi-attack system: Slam, Swing, LeapSlam (weighted random)
	  - OnChaseOverride: checks for LeapSlam gap-closer when player is at mid-range
	  - _doLeapAttack: 4-phase coroutine (windup → rise → flight → land AoE)
	  - _doChargeAttack: inherited helper also used by MossFrog
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))

local BaseEnemy = require(script.Parent.BaseEnemy)
local AIState = BaseEnemy.AIState

-- ============================================================
-- CLASS
-- ============================================================

local Brute = setmetatable({}, { __index = BaseEnemy })
Brute.__index = Brute

-- ============================================================
-- CONSTRUCTOR
-- ============================================================

function Brute.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "Brute", services)
	return setmetatable(self, Brute)
end

-- ============================================================
-- PRIVATE: WEIGHTED ATTACK PICKER
-- ============================================================

local function pickWeightedAttack(attacks: { any }, distance: number?): any?
	-- Filter by MinRange/MaxRange
	local eligible = {}
	for _, atk in attacks do
		local ok = true
		if distance then
			if atk.MinRange and distance < atk.MinRange then
				ok = false
			end
			if atk.MaxRange and distance > atk.MaxRange then
				ok = false
			end
		end
		if ok then
			table.insert(eligible, atk)
		end
	end
	if #eligible == 0 then
		eligible = attacks
	end

	-- Weighted random selection
	local totalWeight = 0
	for _, atk in eligible do
		totalWeight += (atk.Weight or 1)
	end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, atk in eligible do
		cumulative += (atk.Weight or 1)
		if roll <= cumulative then
			return atk
		end
	end
	return eligible[1]
end

-- ============================================================
-- OVERRIDE: OnChaseOverride
-- Intercepts the Chase tick to trigger a LeapSlam gap-closer.
-- Returns true when a gap-closer fires (suppresses base movement).
-- ============================================================

function Brute:OnChaseOverride(targetPos: Vector3, distance: number): boolean
	local config = self.Config
	if not config.Attacks then
		return false
	end

	local now = os.clock()
	-- Must be off attack cooldown before considering any special
	if now - self.LastAttackTime < (config.AttackCooldown or 2.0) then
		return false
	end

	for _, atk in config.Attacks do
		if atk.Type ~= "Leap" then
			continue
		end
		if not (atk.MinRange and atk.MaxRange) then
			continue
		end
		if distance < atk.MinRange or distance > atk.MaxRange then
			continue
		end

		local lastTime = self.LastSpecialTimes[atk.Name] or 0
		local cooldown = atk.Cooldown or 12
		if now - lastTime < cooldown then
			continue
		end

		local chance = atk.Chance or 0.6
		if math.random() > chance then
			-- Back off next roll by 1s to prevent 20 identical rolls per second
			self.LastSpecialTimes[atk.Name] = now - cooldown + 1.0
			continue
		end

		-- Commit to the leap
		self.State = AIState.Attack
		self.LastAttackTime = now
		self.LastSpecialTimes[atk.Name] = now
		self.AttackTriggered = false
		self.CurrentAttack = atk
		self:StopMovement()
		if self.WalkTrack and self.WalkTrack.IsPlaying then
			self.WalkTrack:Stop(0.15)
		end
		return true
	end

	return false
end

-- ============================================================
-- OVERRIDE: OnAttackEnter
-- Picks a weighted attack from config.Attacks, then dispatches
-- to the correct handler based on attack.Type.
-- ============================================================

function Brute:OnAttackEnter()
	local config = self.Config

	-- Use pre-selected attack (e.g. from gap-closer trigger), or pick now
	local attackData = self.CurrentAttack
	if not attackData and config.Attacks then
		local targetPos = self:_getTargetPosition()
		local dist = if targetPos then (targetPos - self.RootPart.Position).Magnitude else nil
		attackData = pickWeightedAttack(config.Attacks, dist)
		self.CurrentAttack = attackData
	end

	if not attackData then
		self:_doStandardAttack(nil) -- No Attacks table: plain melee
		return
	end

	if attackData.Type == "Leap" then
		self.State = AIState.LeapAttack
		task.spawn(function()
			self:_doLeapAttack(attackData)
		end)
	elseif attackData.Type == "Charge" then
		self.State = AIState.ChargeAttack
		task.spawn(function()
			self:_doChargeAttack(attackData)
		end)
	else
		self:_doStandardAttack(attackData)
	end
end

-- ============================================================
-- BRUTE-SPECIFIC: 4-Phase Leap Attack
--
-- Phase 1 — Windup  : crouch animation on the ground
-- Phase 2 — Rise    : straight up to peak height (ease-out)
-- Phase 3 — Flight  : horizontal arc toward player (ease-in descent)
-- Phase 4 — Land    : slam AoE at impact point, recovery delay
-- ============================================================

function Brute:_doLeapAttack(attackData: { [string]: any })
	-- Capture target before nil checks so notifyAttackEnd can always reference it.
	local target = self.Target
	if not target then
		self.State = AIState.Chase
		return
	end

	local rootPart = self.RootPart
	if not rootPart or not rootPart.Parent then
		return
	end
	local windupDuration: number = attackData.WindupDuration or 1.2
	local launchDuration: number = attackData.LaunchDuration or 0.5
	local flightDuration: number = attackData.FlightDuration or 0.6
	local flightHeight: number = attackData.FlightHeight or 40
	local landDuration: number = attackData.LandDuration or 0.8
	local attackDamage: number = attackData.Damage or 25
	local hitRadius: number = attackData.HitRadius or 20
	local vfxType: string = attackData.VFXType or "LeapSlam"

	self:StopMovement()
	self:FaceToward(self:_getTargetPosition() or rootPart.Position)

	-- ── Phase 1: Windup ──────────────────────────────────────────────
	local windupTrack: AnimationTrack? = nil
	if attackData.WindupAnimId and self.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.WindupAnimId
			windupTrack = (self.Animator :: Animator):LoadAnimation(anim)
			;(windupTrack :: AnimationTrack).Priority = Enum.AnimationPriority.Action4
			;(windupTrack :: AnimationTrack):Play()
			;(windupTrack :: AnimationTrack):AdjustSpeed(attackData.WindupAnimSpeed or 1.0)
		end)
	end

	self._services.fireEnemyAttack({
		Enemy = self.Model,
		Target = target,
		HitPosition = rootPart.Position,
		Damage = attackDamage,
		AttackType = "LeapStart",
	})

	task.wait(windupDuration)

	if not rootPart.Parent or self.State == AIState.Dead then
		if windupTrack then
			windupTrack:Stop()
		end
		return
	end

	-- ── Phase 2: Rise ────────────────────────────────────────────────
	if windupTrack then
		windupTrack:Stop(0.1)
	end

	local midairTrack: AnimationTrack? = nil
	if attackData.MidairAnimId and self.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.MidairAnimId
			midairTrack = (self.Animator :: Animator):LoadAnimation(anim)
			;(midairTrack :: AnimationTrack).Priority = Enum.AnimationPriority.Action4
			;(midairTrack :: AnimationTrack).Looped = true
			;(midairTrack :: AnimationTrack):Play()
		end)
	end

	local startPos = rootPart.Position
	local baseY = startPos.Y
	local wasAnchored = rootPart.Anchored
	rootPart.Anchored = true
	if self.LinearVelocity then
		self.LinearVelocity.PlaneVelocity = Vector2.zero
	end

	-- Ease-out rise (fast start, slows at peak)
	local launchStart = os.clock()
	while true do
		local t = math.clamp((os.clock() - launchStart) / launchDuration, 0, 1)
		if t >= 1 then
			break
		end
		local easedT = 1 - (1 - t) ^ 2
		local currentY = baseY + flightHeight * easedT
		rootPart.CFrame = CFrame.lookAt(
			Vector3.new(startPos.X, currentY, startPos.Z),
			Vector3.new(startPos.X, currentY, startPos.Z) + rootPart.CFrame.LookVector
		)
		task.wait()
	end

	-- Snap to peak
	local peakY = baseY + flightHeight
	rootPart.CFrame = CFrame.lookAt(
		Vector3.new(startPos.X, peakY, startPos.Z),
		Vector3.new(startPos.X, peakY, startPos.Z) + rootPart.CFrame.LookVector
	)

	if not rootPart.Parent or self.State == AIState.Dead then
		if midairTrack then
			midairTrack:Stop()
		end
		rootPart.Anchored = wasAnchored
		return
	end

	-- ── Phase 3: Horizontal Flight ───────────────────────────────────
	local landingPos = self:_getTargetPosition()
	if not landingPos then
		if midairTrack then
			midairTrack:Stop()
		end
		rootPart.Anchored = wasAnchored
		if target then
			self._services.notifyAttackEnd(target)
		end
		self.State = AIState.Chase
		return
	end

	local flightStartPos = rootPart.Position
	local flightStart = os.clock()
	while true do
		local t = math.clamp((os.clock() - flightStart) / flightDuration, 0, 1)
		if t >= 1 then
			break
		end
		-- Ease-in descent (slow start → accelerating down, gravity feel)
		local easedT = t ^ 2
		local currentX = flightStartPos.X + (landingPos.X - flightStartPos.X) * t
		local currentZ = flightStartPos.Z + (landingPos.Z - flightStartPos.Z) * t
		local currentY = flightStartPos.Y + (landingPos.Y - flightStartPos.Y) * easedT
		local currentPos = Vector3.new(currentX, currentY, currentZ)
		local lookTarget = Vector3.new(landingPos.X, currentY, landingPos.Z)
		if (lookTarget - currentPos).Magnitude > 1 then
			rootPart.CFrame = CFrame.lookAt(currentPos, lookTarget)
		else
			rootPart.CFrame = CFrame.new(currentPos)
				* CFrame.Angles(0, select(2, rootPart.CFrame:ToEulerAnglesYXZ()), 0)
		end
		task.wait()
	end

	-- ── Phase 4: Landing Slam ────────────────────────────────────────
	rootPart.Anchored = wasAnchored
	if midairTrack then
		midairTrack:Stop(0.1)
	end

	if attackData.LandAnimId and self.Animator then
		pcall(function()
			local anim = Instance.new("Animation")
			anim.AnimationId = attackData.LandAnimId
			local landTrack = (self.Animator :: Animator):LoadAnimation(anim)
			landTrack.Priority = Enum.AnimationPriority.Action4
			landTrack:Play()
		end)
	end

	-- Raycast down to find ground at landing point
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged(CombatConfig.Targeting.TargetTag)
	local rayOrigin = Vector3.new(landingPos.X, rootPart.Position.Y + 5, landingPos.Z)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -60, 0), rayParams)
	local impactPos = if rayResult then rayResult.Position else landingPos

	rootPart.CFrame = CFrame.new(impactPos.X, impactPos.Y + 3, impactPos.Z)
		* CFrame.Angles(0, select(2, rootPart.CFrame:ToEulerAnglesYXZ()), 0)

	self._services.fireEnemyAttack({
		Enemy = self.Model,
		Target = target,
		HitPosition = impactPos,
		Damage = attackDamage,
		AttackType = vfxType,
		IsSlam = true,
	})

	-- AoE: damage all players within hitRadius of impact point
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local targetRoot = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetRoot then
			continue
		end
		if (targetRoot.Position - impactPos).Magnitude > hitRadius then
			continue
		end
		local hum = character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			continue
		end

		local iframeExpiry = self._services.getIFrameExpiry(player)
		if iframeExpiry and os.clock() < iframeExpiry then
			self._services.blockDamage(player, self.Model, targetRoot.Position, attackDamage)
			continue
		end

		local knockbackDir = (targetRoot.Position - impactPos)
		knockbackDir = Vector3.new(knockbackDir.X, 0.5, knockbackDir.Z).Unit
		self._services.dealDamage(player, attackDamage, knockbackDir * 35)
	end

	-- Recovery, then return to Chase.
	-- Same token-leak fix as _doStandardAttack: notifyAttackEnd must be called
	-- here because the state change happens outside Tick and the transition
	-- block never sees LeapAttack → Chase.
	task.delay(landDuration, function()
		if self.State == AIState.LeapAttack then
			if target then
				self._services.notifyAttackEnd(target)
			end
			self.State = AIState.Chase
			self.CurrentAttack = nil
			if self.WalkTrack and not self.WalkTrack.IsPlaying then
				self.WalkTrack:Play(0.2)
			end
		end
	end)
end

-- ============================================================
-- SHARED HELPER: Charge Attack
-- Also inherited by MossFrog via its own class.
-- Phase 1 — Windup  : stop, face player, brief pause
-- Phase 2 — Dash    : high LinearVelocity toward locked direction
-- Phase 3 — Impact  : hit detection + knockback at end of dash
-- ============================================================

function Brute:_doChargeAttack(attackData: { [string]: any })
	local rootPart = self.RootPart
	if not rootPart or not rootPart.Parent then
		return
	end

	-- Capture before any nil checks (same token-leak fix pattern as _doLeapAttack).
	local target = self.Target
	local windup: number = attackData.Windup or 0.25
	local chargeDuration: number = attackData.Duration or 0.75
	local chargeSpeed: number = attackData.ChargeSpeed or 58
	local damage: number = attackData.Damage or 14
	local hitRadius: number = attackData.HitRadius or 9

	self:StopMovement()
	self:FaceToward(self:_getTargetPosition() or rootPart.Position)

	-- Telegraph the charge
	self._services.fireEnemyAttack({
		Enemy = self.Model,
		Target = target,
		HitPosition = rootPart.Position,
		Damage = damage,
		AttackType = "ChargeStart",
	})

	task.wait(windup)

	if not rootPart.Parent or self.State == AIState.Dead then
		return
	end

	-- Lock direction at launch moment so Brute can't steer mid-charge
	local targetPos = self:_getTargetPosition()
	if not targetPos then
		if target then
			self._services.notifyAttackEnd(target)
		end
		self.State = AIState.Chase
		return
	end

	local diff = targetPos - rootPart.Position
	local direction = Vector3.new(diff.X, 0, diff.Z)
	if direction.Magnitude < 0.1 then
		if target then
			self._services.notifyAttackEnd(target)
		end
		self.State = AIState.Chase
		return
	end
	direction = direction.Unit

	-- Walk anim at 3x speed sells the frantic sprint
	if self.WalkTrack then
		if not self.WalkTrack.IsPlaying then
			self.WalkTrack:Play(0.05)
		end
		self.WalkTrack:AdjustSpeed(3.0)
	end
	if self.LinearVelocity then
		self.LinearVelocity.PlaneVelocity = Vector2.new(direction.X, direction.Z) * chargeSpeed
	end
	if self.AlignOrientation then
		local facingOffset = math.rad(self.Config.FacingOffset or 0)
		self.AlignOrientation.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + direction)
			* CFrame.Angles(0, facingOffset, 0)
	end

	task.wait(chargeDuration)

	-- Stop the dash
	self:StopMovement()
	if self.WalkTrack then
		self.WalkTrack:AdjustSpeed(self.Config.WalkAnimationSpeed or 1.0)
		if self.WalkTrack.IsPlaying then
			self.WalkTrack:Stop(0.2)
		end
	end

	if not rootPart.Parent or self.State == AIState.Dead then
		return
	end

	-- Hit detection at landing position
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local targetRoot = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetRoot then
			continue
		end
		if (targetRoot.Position - rootPart.Position).Magnitude > hitRadius then
			continue
		end
		local hum = character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			continue
		end

		local iframeExpiry = self._services.getIFrameExpiry(player)
		if iframeExpiry and os.clock() < iframeExpiry then
			self._services.blockDamage(player, self.Model, targetRoot.Position, damage)
			continue
		end

		self._services.fireEnemyAttack({
			Enemy = self.Model,
			Target = target,
			HitPosition = rootPart.Position,
			Damage = damage,
			AttackType = "Swing",
		})
		-- Strong forward knockback + slight upward launch
		self._services.dealDamage(player, damage, direction * 35 + Vector3.new(0, 12, 0))
	end

	-- Brief recovery, then Chase.
	-- notifyAttackEnd called here for the same token-leak reason as
	-- _doStandardAttack and _doLeapAttack.
	task.delay(0.3, function()
		if self.State == AIState.ChargeAttack then
			if target then
				self._services.notifyAttackEnd(target)
			end
			self.State = AIState.Chase
			self.CurrentAttack = nil
			if self.WalkTrack and not self.WalkTrack.IsPlaying then
				self.WalkTrack:Play(0.2)
			end
		end
	end)
end

return Brute
