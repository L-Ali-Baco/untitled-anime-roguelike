--!strict
--[[
	BogShambler.luau
	================
	Swarm fodder enemy with a single leaping headbutt attack.

	ATTACK OVERVIEW — _doHeadbuttAttack()
	──────────────────────────────────────
	 [0.0 s]  Animation plays (Action2 priority; overrides walk).
	 [0.6 s]  Impact frame:
	            • AnimationTrack.Speed = 0  → enemy freezes completely.
	            • AoE sphere hitbox fires (6-stud radius, 3 studs forward).
	            • BogSlamImpact remote fires to all clients (Mud Slam VFX).
	 [1.1 s]  AnimationTrack.Speed = 1  → animation resumes through recovery.
	 [1.6 s]  Attack token released. State → Chase.

	HITSTOP MECHANIC
	────────────────
	Setting AnimationTrack.Speed = 0 freezes that specific track in-place.
	The LinearVelocity / AlignOrientation constraints keep the physics body
	rigid during the pause. The result is a full "freeze frame" at the moment
	of impact that sells the weight of the slam to players.

	FRAME-PERFECT ALTERNATIVE (GetMarkerReachedSignal)
	────────────────────────────────────────────────────
	The default implementation uses task.wait(HeadbuttWindup) which is
	accurate to ±1 frame (~17 ms at 60 fps). For frame-perfect hitstop:
	  1. Open rbxassetid://86362610167476 in the Roblox Animation Editor.
	  2. Select the keyframe where the head contacts the ground.
	  3. Right-click → "Add Keyframe Marker" → type "Impact" as the name.
	  4. In _doHeadbuttAttack below, replace the task.wait(windup) block
	     with:
	           local impactSignal = track:GetMarkerReachedSignal("Impact")
	           impactSignal:Wait()
	     GetMarkerReachedSignal fires at the authored frame regardless of
	     Speed adjustments made *before* that point.

	INTERRUPTION SAFETY
	────────────────────
	Every resume point in the coroutine checks self._destroyed and
	self.State before proceeding. If the enemy is hitstunned or killed
	during the attack:
	  • ApplyHitstun / _onDeath release the attack token and change State.
	  • The coroutine wakes, sees State ≠ AIState.Attack, cleans up the
	    frozen track, and returns without double-releasing the token.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseEnemy = require(script.Parent.BaseEnemy)
local AIState = BaseEnemy.AIState

-- ── Constants (fallback values if EnemyConfig fields are absent) ──────────────

-- Animation ID for the leaping headbutt clip.
local HEADBUTT_ANIM_ID: string = "rbxassetid://86362610167476"

-- Seconds from animation start to the head-contacts-ground impact frame.
local DEFAULT_WINDUP: number = 0.6

-- Seconds the animation is frozen at impact (AnimationTrack.Speed = 0).
local DEFAULT_HITSTOP: number = 0.5

-- Seconds of recovery animation that play after the freeze lifts.
local DEFAULT_RECOVERY: number = 0.5

-- ── Class ─────────────────────────────────────────────────────────────────────

local BogShambler = setmetatable({}, { __index = BaseEnemy })
BogShambler.__index = BogShambler

-- ── Constructor ───────────────────────────────────────────────────────────────

function BogShambler.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "BogShambler", services)
	setmetatable(self, BogShambler)

	-- Pre-load headbutt animation so each attack reuses the same track
	-- rather than allocating a new Animation instance every time.
	self._headbuttTrack = nil :: AnimationTrack?
	self:_loadHeadbuttAnim()

	return self
end

-- ── Private: Load Animation ───────────────────────────────────────────────────

function BogShambler:_loadHeadbuttAnim()
	local animator = self.Animator
	if not animator then
		return
	end

	local animId: string = (self.Config.HeadbuttAnimId :: string?) or HEADBUTT_ANIM_ID
	local ok, result = pcall(function()
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = (animator :: Animator):LoadAnimation(anim)
		track.Looped = false
		-- Action2 priority: sits above the walk (Movement) and standard attack
		-- (Action) so it cannot be interrupted by those tracks mid-slam.
		track.Priority = Enum.AnimationPriority.Action2
		return track
	end)

	if ok then
		self._headbuttTrack = result :: AnimationTrack
	else
		warn(("[BogShambler] Failed to load headbutt animation %s: %s"):format(animId, result))
	end
end

-- ── Private: Get Slam Remote (lazy, non-yielding) ─────────────────────────────
-- FindFirstChild never yields so it is safe to call inside a task.spawn coroutine.

local function getSlamRemote(): RemoteEvent?
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		return folder:FindFirstChild("BogSlamImpact") :: RemoteEvent?
	end
	return nil
end

-- ── Virtual Hook: OnAttackEnter ───────────────────────────────────────────────

--[[
	Called exactly once by BaseEnemy.Tick when the enemy enters AIState.Attack.
	Spawns the headbutt sequence in a task.spawn so Tick is not blocked.
]]
function BogShambler:OnAttackEnter()
	print("[BogShambler] OnAttackEnter called — spawning headbutt coroutine")
	task.spawn(function()
		self:_doHeadbuttAttack()
	end)
end

-- ── Private: Headbutt Attack Sequence ─────────────────────────────────────────

function BogShambler:_doHeadbuttAttack()
	print("[BogShambler] _doHeadbuttAttack entered")
	local config = self.Config

	-- Read timing from config; fall back to module constants.
	local windup: number = (config.HeadbuttWindup :: number?) or DEFAULT_WINDUP
	local hitstop: number = (config.HeadbuttHitstop :: number?) or DEFAULT_HITSTOP
	local recovery: number = (config.HeadbuttRecovery :: number?) or DEFAULT_RECOVERY
	local damage: number = (config.HeadbuttDamage :: number?) or (config.Damage :: number?) or 8
	local hitRadius: number = (config.HeadbuttRadius :: number?) or 6
	local knockbackMag: number = (config.HeadbuttKnockback :: number?) or 18

	-- ── 1. Play the headbutt animation ────────────────────────────────────
	local track = self._headbuttTrack
	if track then
		track:Play(0.05)
	end

	-- ── 2. Wait for the impact frame ──────────────────────────────────────
	-- Use track.Length - 0.05 so the freeze always lands just before the clip
	-- would auto-cancel. If the track hasn't loaded, fall back to the config
	-- windup. Replace with GetMarkerReachedSignal("Impact"):Wait() once you've
	-- added a KeyframeMarker in the Animation Editor (see file header).
	local impactWait: number = if track and track.Length > 0.05
		then track.Length - 0.05
		else windup
	task.wait(impactWait)

	-- Check for interruption that happened during the windup wait.
	-- ApplyHitstun / _onDeath already released the token and changed State.
	if self._destroyed or self.State ~= AIState.Attack then
		if track and track.IsPlaying then
			track:Stop(0.05)
		end
		return
	end

	-- ── 3. Hitstop — freeze the animation at the impact frame ─────────────
	if track then
		track:AdjustSpeed(0)
	end
	-- Redundant StopMovement: Tick already zeroed velocity on Attack entry,
	-- but calling it again here ensures physics is locked for the freeze window.
	self:StopMovement()

	-- ── 4. AoE hit detection ──────────────────────────────────────────────
	-- CFrame composition: 4 studs forward in HRP local space (-Z = forward).
	-- .Position always yields a Vector3 — no manual component extraction,
	-- no type-mismatch risk when passing to GetPartBoundsInRadius.
	local impactPos: Vector3 = (self.RootPart.CFrame * CFrame.new(0, 0, -4)).Position

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { self.Model }

	local parts = workspace:GetPartBoundsInRadius(impactPos, hitRadius, overlapParams)
	local alreadyHit: { [Player]: boolean } = {}

	for _, part in parts do
		local player = Players:GetPlayerFromCharacter(part.Parent)
		if not player or alreadyHit[player] then
			continue
		end
		alreadyHit[player] = true

		-- I-frame check — consistent with _doStandardAttack.
		local iframeExpiry = self._services.getIFrameExpiry(player)
		if iframeExpiry and os.clock() < iframeExpiry then
			self._services.blockDamage(player, self.Model, part.Position, damage)
			continue
		end

		local charRoot = (part.Parent :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?
		if not charRoot then
			continue
		end

		-- Knockback: flat direction away from the shambler + slight upward arc.
		local flatDir = Vector3.new(
			charRoot.Position.X - self.RootPart.Position.X,
			0,
			charRoot.Position.Z - self.RootPart.Position.Z
		)
		local knockDir: Vector3 = if flatDir.Magnitude > 0.01
			then (flatDir.Unit + Vector3.new(0, 0.45, 0)).Unit
			else Vector3.new(0, 1, 0)

		self._services.dealDamage(player, damage, knockDir * knockbackMag)
	end

	-- ── 5. Fire Mud Slam VFX to all clients ───────────────────────────────
	local remote = getSlamRemote()
	print("[BogShambler] Impact at", impactPos, "| remote found:", remote ~= nil)
	if remote then
		remote:FireAllClients(impactPos)
	end

	-- ── 6. Hold the hitstop freeze for the configured duration ────────────
	task.wait(hitstop)

	-- Check for interruption that happened during the hitstop window.
	-- The track is still frozen (Speed = 0); we must unfreeze before stopping.
	if self._destroyed or self.State ~= AIState.Attack then
		if track then
			-- Unfreeze first so Stop() can blend out cleanly.
			track:AdjustSpeed(1)
			if track.IsPlaying then
				track:Stop(0.1)
			end
		end
		return
	end

	-- ── 7. Unfreeze — let the recovery animation play ─────────────────────
	if track then
		track:AdjustSpeed(1)
	end

	task.wait(recovery)

	-- ── 8. Cleanup and return to Chase ────────────────────────────────────
	if track and track.IsPlaying then
		track:Stop(0.2)
	end

	-- Guard: ApplyHitstun may have changed State during the recovery wait.
	-- Only release the token once, from whoever still owns the Attack state.
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
end

-- OnChaseOverride: inherited (returns false) — base flow-field movement used.

return BogShambler
