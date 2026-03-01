--[[
    RunAnimator.luau
    Location: StarterCharacter (runs inside the character model on spawn)

    PURPOSE:
    Plays a custom looping Run animation whenever the player is moving.
    Crossfades back to Idle when movement stops.
    Designed to be the ONLY locomotion animation driver — disable or
    delete the default Roblox "Animate" LocalScript from StarterCharacter
    so they don't conflict.

    EXPANSION HOOKS:
    Search for these tags when adding new states:
        FUTURE: DODGE   → Dodge-roll anim override
        FUTURE: ATTACK  → Suppress run during attacks (wire CombatController signal)
        FUTURE: JUMP    → Airborne / fall anim via HumanoidStateType
        FUTURE: SPRINT  → Higher-speed variant anim

    REQUIRES:
    - Humanoid with an Animator child inside StarterCharacter
    - Replace RUN_ANIM_ID (and optionally IDLE_ANIM_ID) below
]]

-- ============================================================================
-- CONFIGURATION — Edit these to tune behaviour
-- ============================================================================

-- << Paste your uploaded animation asset IDs here >>
local RUN_ANIM_ID = "rbxassetid://139592018369839" -- Running animation
local IDLE_ANIM_ID = "rbxassetid://77082417243773" -- Neutral stance (idle)

-- Animation priority.
-- Movement = default locomotion layer (will blend with Action-priority anims like attacks).
-- Bump to Action if you want run to hard-override everything.
local RUN_PRIORITY = Enum.AnimationPriority.Movement
local IDLE_PRIORITY = Enum.AnimationPriority.Movement

-- Playback speed of the run animation (1.0 = author-baked speed).
-- Increase if your character feels like they're moonwalking, decrease if too frantic.
local RUN_SPEED = 1.0

-- MoveDirection.Magnitude must exceed this to count as moving.
-- Raise slightly (e.g. 0.2) to kill gamepad deadzone jitter.
local MOVE_THRESHOLD = 0.1

-- Crossfade time between idle ↔ run (seconds)
local FADE_TIME = 0.15

-- ============================================================================
-- SETUP
-- ============================================================================

local character = script.Parent -- The character Model
local humanoid = character:WaitForChild("Humanoid")

-- ── Custom rig guard ───────────────────────────────────────────────────────
-- ClassController already manages all animations for custom rig characters
-- (VanguardRig, Scrapper, BikerKing). If RunAnimator also runs in the same
-- character, both scripts fight over the Animator and neither works.
-- Bail out immediately and let ClassController win.
if character:GetAttribute("IsCustomRig") then
	return
end
-- ──────────────────────────────────────────────────────────────────────────

local animator = humanoid:WaitForChild("Animator") -- Must live inside Humanoid

--[[
    Load an animation from an asset ID.
    Returns nil (and warns) if the ID is "0" / unset so we can safely skip it.
]]
local function loadAnim(id: string, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack?
	if id == "rbxassetid://0" or id == "" then
		return nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Priority = priority
	track.Looped = looped
	return track
end

-- Pre-load so first play has zero stutter
local runTrack: AnimationTrack? = loadAnim(RUN_ANIM_ID, RUN_PRIORITY, true)
local idleTrack: AnimationTrack? = loadAnim(IDLE_ANIM_ID, IDLE_PRIORITY, true)

if not runTrack then
	warn("[RunAnimator] RUN_ANIM_ID is not set — replace the placeholder ID.")
end

-- ============================================================================
-- STATE
-- ============================================================================

local isRunning = false -- Tracks whether the run track is currently active

-- FUTURE: DODGE  local isDodging = false
-- FUTURE: ATTACK local isAttacking = false  -- set by CombatController signal

-- ============================================================================
-- CORE LOGIC
-- ============================================================================

--[[
    Called whenever MoveDirection changes.
    Decides which animation should be playing and crossfades accordingly.
]]
local function updateLocomotion()
	-- FUTURE: DODGE  — early return if dodging, keep dodge anim active
	-- FUTURE: ATTACK — early return if isAttacking, skip run

	local moving = humanoid.MoveDirection.Magnitude > MOVE_THRESHOLD

	if moving and not isRunning then
		-- ── Transition: Idle → Run ─────────────────────────────────────────
		isRunning = true

		if idleTrack and idleTrack.IsPlaying then
			idleTrack:Stop(FADE_TIME)
		end

		if runTrack and not runTrack.IsPlaying then
			runTrack:Play(FADE_TIME)
			runTrack:AdjustSpeed(RUN_SPEED)
		end
	elseif not moving and isRunning then
		-- ── Transition: Run → Idle ─────────────────────────────────────────
		isRunning = false

		if runTrack and runTrack.IsPlaying then
			runTrack:Stop(FADE_TIME)
		end

		-- FUTURE: JUMP — check Humanoid.FloorMaterial here;
		--   if == Enum.Material.Air, play fall/jump anim instead of idle.

		if idleTrack and not idleTrack.IsPlaying then
			idleTrack:Play(FADE_TIME)
		end
	end
end

-- ============================================================================
-- CONNECTIONS
-- ============================================================================

-- MoveDirection fires only when the vector actually changes — cheap to connect.
humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(updateLocomotion)

-- Clean up on death (stop all tracks immediately so no visual glitch)
humanoid.Died:Connect(function()
	if runTrack and runTrack.IsPlaying then
		runTrack:Stop(0)
	end
	if idleTrack and idleTrack.IsPlaying then
		idleTrack:Stop(0)
	end
end)

-- Run immediately in case the character spawns mid-movement (edge case)
updateLocomotion()

-- Play idle on spawn if we have one (character starts standing still)
if idleTrack and not isRunning then
	idleTrack:Play(FADE_TIME)
end
