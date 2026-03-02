--[[
	JumpController.luau
	===================
	Handles 3D verticality for enemies: ledge climbing, gap dropping, and landing
	detection. Called from BaseEnemy:Tick() during the Chase state.

	DESIGN CONTRACT:
	  - JumpController is a STATELESS utility module. It does not store per-enemy
	    data; all state lives on the enemy object itself (see BaseEnemy fields
	    _jumpTrajectory, _landRecoveryEnd, State).
	  - JumpController reads from enemy fields and the workspace geometry.
	  - The DoLedgeJump() and DoGapLeap() functions mutate enemy state directly
	    (set State, _jumpTrajectory, play animations, fire events) because that
	    keeps the BaseEnemy Tick loop clean and mirrors how SteeringBehaviors works.

	INTEGRATION (called from BaseEnemy:Tick → Chase branch):

	  local ledge = JumpController.CheckLedge(self, moveDir)
	  if ledge then
	      JumpController.DoLedgeJump(self, moveDir, ledge.jumpPower)
	      return -- state changed; skip MoveTowardTarget this tick
	  end
	  local gap = JumpController.CheckGap(self, moveDir)
	  if gap then
	      JumpController.DoGapLeap(self, moveDir)
	      return
	  end

	LEDGE DETECTION — how the raycasts work:

	  Enemy is moving in direction D. We probe PROBE_DISTANCE studs ahead.
	  Two horizontal rays are fired from the current enemy position:

	    Ray 1 (feet level):  Origin = (rootPos + D*PROBE_DIST) at footY
	                         Direction = downward, length = LEDGE_SCAN_DEPTH
	                         If hits: there is geometry at foot-level ahead.
	                         ledgeTopY = hitPos.Y

	    Ray 2 (chest level): Origin = rootPos at chestY
	                         Direction = forward (D), length = PROBE_DIST + 1
	                         If hits: solid wall at chest height → can't jump over.
	                         If misses: only a low obstacle → might be climbable.

	  Decision: feet hits AND chest misses AND (ledgeTopY - feetY) <= MAX_JUMP_HEIGHT
	            → climbable ledge; compute jump power.

	GAP DETECTION — how it works:

	  Fire one ray downward from (rootPos + D*PROBE_DIST) with length GAP_SCAN_DEPTH.
	  If no ground found → gap/drop ahead.
	  If ground found at depth > MIN_DROP to depth <= MAX_DROP_DEPTH → safe to drop.
	  (Deeper than MAX_DROP_DEPTH is treated as a void — don't leap into it.)

	JUMP PHYSICS:

	  Roblox gravity = 196.2 studs/s². For an enemy to clear a ledge of height H:
	    v₀ = √(2 × g × (H + CLEARANCE_BUFFER))
	  We multiply by a 15% safety margin so the enemy doesn't graze the edge.
	  The jump is applied as AssemblyLinearVelocity.Y — compatible with the
	  LinearVelocity (Plane mode) setup in BaseEnemy._setupPhysics.
]]

local CollectionService = game:GetService("CollectionService")

local JumpController = {}

-- ── Physics ────────────────────────────────────────────────────────────────────

-- Roblox default gravity (studs/s²). Matches workspace.Gravity default.
local ROBLOX_GRAVITY = 196.2

-- Extra height added to the computed jump power to ensure the enemy clears the
-- ledge edge even if they're not perfectly aligned. 0.8 studs is about half a
-- standard floor tile thickness.
local JUMP_CLEARANCE_BUFFER = 0.8

-- Jump power safety multiplier: 1.15 = 15% extra velocity above the minimum.
-- Prevents enemies from grazing ledges due to positional imprecision.
local JUMP_POWER_MARGIN = 1.15

-- ── Probe Distances ───────────────────────────────────────────────────────────

-- How far ahead (in the movement direction) to probe for ledges/gaps.
local PROBE_DISTANCE = 3.5 -- studs

-- For the feet-level downward scan: how far down to look for a ledge surface.
local LEDGE_SCAN_DEPTH = 6 -- studs downward from foot height

-- For the gap scan: how far down to check for a floor on the other side of a gap.
local GAP_SCAN_DEPTH = 30 -- studs

-- ── Vertical Offsets from RootPart ────────────────────────────────────────────

-- Y offset from root to the enemy's feet level.
-- Most enemies have their root at roughly waist height.
local FEET_Y_OFFSET = -1.5 -- studs

-- Y offset from root to the enemy's chest level.
-- If the chest ray is blocked, it's a wall the enemy cannot jump over.
local CHEST_Y_OFFSET = 1.5 -- studs

-- ── Jump Constraints ──────────────────────────────────────────────────────────

-- Maximum ledge height the enemy will attempt to jump.
-- Ledges taller than this are treated as impassable walls.
local MAX_JUMP_HEIGHT = 7 -- studs (roughly 1 floor height in most Roblox games)

-- Minimum ledge height before we bother jumping. Very shallow bumps (< 0.4 studs)
-- should be navigated over by the GroundCollision box naturally.
local MIN_JUMP_HEIGHT = 0.4 -- studs

-- ── Drop/Gap Constraints ──────────────────────────────────────────────────────

-- Minimum drop depth before we initiate a gap leap.
-- Shallow drops (<1 stud) are handled passively by physics.
local MIN_DROP_DEPTH = 1.0 -- studs

-- Maximum safe drop. Deeper than this is treated as a void / off-limits area.
local MAX_DROP_DEPTH = 20 -- studs

-- ── Landing Detection ─────────────────────────────────────────────────────────

-- Downward ray length for the IsGrounded check.
-- Should be slightly longer than the enemy's foot-to-floor clearance when stationary.
local GROUND_PROBE_DIST = 2.2 -- studs

-- Y velocity threshold for landing: if |vel.Y| is below this, physics considers
-- the body to be resting on a surface. Use a generous threshold because physics
-- contacts don't always zero velocity instantly on the first simulation step.
local GROUND_VEL_THRESHOLD = 3 -- studs/s absolute Y velocity

-- Minimum time after entering Falling state before we start checking for landing.
-- Prevents immediately re-landing at the start of a jump (before the enemy has
-- left the ground surface).
local FALL_GRACE_PERIOD = 0.15 -- seconds

-- ── Private: Build Raycast Params ─────────────────────────────────────────────

--[[
	_makeParams(enemyModel) -> RaycastParams
	Returns a fresh RaycastParams that excludes the calling enemy's model and all
	other enemy models (so enemies don't detect each other as ledge geometry).
]]
local function _makeParams(enemyModel: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Exclude the enemy itself to avoid self-hits on the GroundCollision box.
	-- Also exclude all other enemies by tag so nearby enemies don't fool the probe.
	local excluded = CollectionService:GetTagged("Enemy")
	table.insert(excluded, enemyModel)
	params.FilterDescendantsInstances = excluded
	return params
end

-- ── Public: IsGrounded ────────────────────────────────────────────────────────

--[[
	JumpController.IsGrounded(enemy) -> boolean

	Returns true if the enemy is on (or very near) the ground.
	Uses TWO criteria:
	  1. Y velocity near zero (physics contact zeroes out vertical movement).
	  2. Short downward raycast from feet confirms actual geometry below.

	Both must be satisfied. This prevents false positives when the enemy
	passes through mid-air geometry (e.g. a floating platform overhead).

	Only call this when the enemy is in Falling state. The FALL_GRACE_PERIOD
	check in BaseEnemy:Tick prevents calling it immediately after a jump.
]]
function JumpController.IsGrounded(enemy: any): boolean
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return false
	end

	-- ── Check 1: Y velocity near zero ────────────────────────────────────────
	local yVel = math.abs(enemy.RootPart.AssemblyLinearVelocity.Y)
	if yVel > GROUND_VEL_THRESHOLD then
		return false -- Still meaningfully airborne
	end

	-- ── Check 2: Ground geometry within GROUND_PROBE_DIST studs below feet ───
	local feetPos = enemy.RootPart.Position + Vector3.new(0, FEET_Y_OFFSET, 0)
	local params = _makeParams(enemy.Model)
	local hit = workspace:Raycast(feetPos, Vector3.new(0, -GROUND_PROBE_DIST, 0), params)
	return hit ~= nil
end

-- ── Public: CheckLedge ────────────────────────────────────────────────────────

--[[
	JumpController.CheckLedge(enemy, moveDir) -> { jumpPower: number, ledgeHeight: number }?

	Probes ahead for a jumpable ledge in the movement direction.

	Returns a result table if a climbable ledge is found, nil otherwise.
	  .jumpPower    = initial Y velocity (studs/s) needed to clear the ledge.
	  .ledgeHeight  = actual height of the ledge above the enemy's feet (for logging).

	ALGORITHM:
	  Fire a downward ray from (rootPos + moveDir * PROBE_DIST) at foot level.
	    → This detects the top surface of anything at foot-level ahead.
	  Fire a forward ray from rootPos at chest level.
	    → If this hits anything, it's a wall too tall to jump over.
	  If foot detects geometry AND chest doesn't hit:
	    → Compute ledge height and jump power.

	@param enemy    BaseEnemy instance.
	@param moveDir  Unit Vector3 in the XZ plane (Y should be 0).
	@returns        Table with jumpPower + ledgeHeight, or nil if no climbable ledge.
]]
function JumpController.CheckLedge(
	enemy: any,
	moveDir: Vector3
): { jumpPower: number, ledgeHeight: number }?
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return nil
	end

	local rootPos = enemy.RootPart.Position
	local params = _makeParams(enemy.Model)

	-- ── Feet ray: probe downward from foot height at the probe point ──────────
	-- probePoint = where the enemy's feet would be PROBE_DISTANCE ahead
	local probeCenter = rootPos + moveDir * PROBE_DISTANCE
	local feetOrigin = Vector3.new(probeCenter.X, rootPos.Y + FEET_Y_OFFSET + 0.2, probeCenter.Z)

	-- Cast downward to find any surface at/above foot level ahead
	local feetHit = workspace:Raycast(feetOrigin, Vector3.new(0, -(LEDGE_SCAN_DEPTH + 0.2), 0), params)
	if not feetHit then
		return nil -- No geometry ahead at foot level — likely a gap (handled by CheckGap)
	end

	-- ── Chest ray: probe forward from chest height ────────────────────────────
	-- If this hits, there's a solid wall at chest level — cannot jump over it.
	local chestOrigin = Vector3.new(rootPos.X, rootPos.Y + CHEST_Y_OFFSET, rootPos.Z)
	local chestHit = workspace:Raycast(chestOrigin, moveDir * (PROBE_DISTANCE + 1), params)
	if chestHit then
		return nil -- Solid wall at chest height → impassable
	end

	-- ── Measure ledge height ──────────────────────────────────────────────────
	local feetY = rootPos.Y + FEET_Y_OFFSET
	local ledgeTopY = feetHit.Position.Y
	local ledgeHeight = ledgeTopY - feetY

	-- Filter out ledges that are too shallow (just floor noise) or too tall.
	if ledgeHeight < MIN_JUMP_HEIGHT or ledgeHeight > MAX_JUMP_HEIGHT then
		return nil
	end

	-- ── Compute required jump power using projectile motion ──────────────────
	-- To reach height H above current feet level:
	--   v₀ = √(2 × g × (H + CLEARANCE_BUFFER)) × SAFETY_MARGIN
	-- The safety margin ensures the enemy clears the edge even with slight
	-- positional imprecision from physics staggering.
	local jumpH = ledgeHeight + JUMP_CLEARANCE_BUFFER
	local jumpPower = math.sqrt(2 * ROBLOX_GRAVITY * jumpH) * JUMP_POWER_MARGIN

	return { jumpPower = jumpPower, ledgeHeight = ledgeHeight }
end

-- ── Public: CheckGap ─────────────────────────────────────────────────────────

--[[
	JumpController.CheckGap(enemy, moveDir) -> { dropDepth: number }?

	Probes ahead for a gap (drop-off) in the movement direction.

	Returns a result table if a safe gap is found ahead, nil otherwise.
	  .dropDepth = vertical distance from foot level to the floor below the gap.

	A gap is safe if there IS a floor below (depth <= MAX_DROP_DEPTH).
	If there's no floor (void / very deep pit), we do NOT leap.

	NOTE: The flow field GetDirection result should already be pointing the enemy
	toward the gap if the path requires crossing it. CheckGap is a confirmation
	that the geometry matches what the flow field expects.

	@param enemy    BaseEnemy instance.
	@param moveDir  Unit Vector3 in the XZ plane (Y should be 0).
	@returns        Table with dropDepth, or nil if no gap (or unsafe void).
]]
function JumpController.CheckGap(enemy: any, moveDir: Vector3): { dropDepth: number }?
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return nil
	end

	local rootPos = enemy.RootPart.Position
	local params = _makeParams(enemy.Model)

	-- ── Verify no floor immediately ahead at foot level ───────────────────────
	-- (If CheckLedge found geometry here, CheckGap wouldn't be called — but
	--  guard anyway for robustness.)
	local probeCenter = rootPos + moveDir * PROBE_DISTANCE
	local probeOrigin = Vector3.new(probeCenter.X, rootPos.Y + FEET_Y_OFFSET + 0.2, probeCenter.Z)
	local shallowHit = workspace:Raycast(probeOrigin, Vector3.new(0, -1.5, 0), params)
	if shallowHit then
		return nil -- There IS ground right ahead — not a gap
	end

	-- ── Deep scan: is there a floor below the gap? ────────────────────────────
	local deepOrigin = Vector3.new(probeCenter.X, rootPos.Y + FEET_Y_OFFSET, probeCenter.Z)
	local deepHit = workspace:Raycast(deepOrigin, Vector3.new(0, -GAP_SCAN_DEPTH, 0), params)

	if not deepHit then
		return nil -- No floor detected at all → void / pit → do NOT leap
	end

	local dropDepth = (rootPos.Y + FEET_Y_OFFSET) - deepHit.Position.Y
	if dropDepth < MIN_DROP_DEPTH then
		return nil -- Shallow enough for physics to handle passively
	end
	if dropDepth > MAX_DROP_DEPTH then
		return nil -- Too deep — treat as void
	end

	return { dropDepth = dropDepth }
end

-- ── Public: DoLedgeJump ───────────────────────────────────────────────────────

--[[
	JumpController.DoLedgeJump(enemy, moveDir, jumpPower)

	Initiates a ledge-climbing jump.

	Actions performed:
	  1. Applies a Y velocity impulse (jumpPower) to AssemblyLinearVelocity.
	  2. Records the XZ trajectory so Tick can maintain it during the arc.
	  3. Stops the walk animation, plays the jump animation.
	  4. Transitions the enemy to AIState.Jumping.
	  5. Fires the EnemyStateChanged event so clients update their visuals.

	The XZ PlaneVelocity is NOT zeroed here — the enemy keeps its current
	forward momentum. The Jumping/Falling Tick handlers lock it to _jumpTrajectory.

	@param enemy      BaseEnemy instance.
	@param moveDir    Unit XZ direction the enemy is jumping toward.
	@param jumpPower  Initial Y velocity to apply (studs/s). From CheckLedge result.
]]
function JumpController.DoLedgeJump(enemy: any, moveDir: Vector3, jumpPower: number)
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return
	end

	local AIState = require(script.Parent.BaseEnemy).AIState

	local speed: number = (enemy.Model:GetAttribute("WalkSpeed") :: number?) or 14

	-- ── Record XZ trajectory for the Jumping/Falling Tick lock ───────────────
	enemy._jumpTrajectory = Vector2.new(moveDir.X, moveDir.Z) * speed

	-- ── Apply the jump impulse ────────────────────────────────────────────────
	-- Preserve horizontal velocity; add the computed Y component.
	-- Using AssemblyLinearVelocity.Y directly because LinearVelocity is in
	-- Plane mode and doesn't control the Y axis.
	local currentVel = enemy.RootPart.AssemblyLinearVelocity
	enemy.RootPart.AssemblyLinearVelocity = Vector3.new(
		currentVel.X,
		jumpPower, -- Upward launch
		currentVel.Z
	)

	-- Set XZ PlaneVelocity to the jump direction immediately so the Tick loop
	-- doesn't override it before the first Jumping Tick runs.
	if enemy.LinearVelocity then
		enemy.LinearVelocity.PlaneVelocity = enemy._jumpTrajectory
	end

	-- ── Animation ─────────────────────────────────────────────────────────────
	if enemy.WalkTrack and enemy.WalkTrack.IsPlaying then
		enemy.WalkTrack:Stop(0.1)
	end
	if enemy.JumpTrack then
		enemy.JumpTrack:Play(0.05)
	end

	-- ── State transition ──────────────────────────────────────────────────────
	enemy.State = AIState.Jumping
	enemy._fallingGraceEnd = os.clock() + 0.05 -- brief grace before landing check engages
	enemy.IsMoving = false

	enemy._services.fireEnemyStateChanged(enemy.Model, AIState.Jumping)
end

-- ── Public: DoGapLeap ─────────────────────────────────────────────────────────

--[[
	JumpController.DoGapLeap(enemy, moveDir, dropDepth)

	Commits the enemy to leap across/into a gap.

	For gap drops, the enemy is already moving forward and gravity will carry
	them down. We do NOT need to add extra Y velocity. Instead we:
	  1. Lock XZ trajectory so separation doesn't push them sideways mid-fall.
	  2. Transition directly to Falling state (they're about to go airborne).
	  3. For deeper drops, add a small forward boost so they clear the gap edge.

	@param enemy      BaseEnemy instance.
	@param moveDir    Unit XZ direction toward the gap.
	@param dropDepth  How far the drop is (from CheckGap). Used to scale boost.
]]
function JumpController.DoGapLeap(enemy: any, moveDir: Vector3, dropDepth: number)
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return
	end

	local AIState = require(script.Parent.BaseEnemy).AIState

	local speed: number = (enemy.Model:GetAttribute("WalkSpeed") :: number?) or 14

	-- ── Lock XZ trajectory ────────────────────────────────────────────────────
	-- Give a slight speed boost over the gap (1.2× normal) to help clear the edge.
	enemy._jumpTrajectory = Vector2.new(moveDir.X, moveDir.Z) * (speed * 1.2)

	if enemy.LinearVelocity then
		enemy.LinearVelocity.PlaneVelocity = enemy._jumpTrajectory
	end

	-- ── For deeper drops: small downward boost to start the fall quickly ──────
	-- This prevents the enemy from hovering at the edge briefly before falling.
	if dropDepth > 4 then
		local currentVel = enemy.RootPart.AssemblyLinearVelocity
		enemy.RootPart.AssemblyLinearVelocity = Vector3.new(currentVel.X, -8, currentVel.Z)
	end

	-- ── Animation ─────────────────────────────────────────────────────────────
	if enemy.WalkTrack and enemy.WalkTrack.IsPlaying then
		enemy.WalkTrack:Stop(0.1)
	end
	-- For a gap leap, go straight to FallTrack (no jump arc)
	if enemy.FallTrack then
		enemy.FallTrack:Play(0.05)
	end

	-- ── State transition ──────────────────────────────────────────────────────
	-- Record when we entered Falling so the landing check grace period applies.
	enemy.State = AIState.Falling
	enemy._fallingGraceEnd = os.clock() + FALL_GRACE_PERIOD
	enemy.IsMoving = false

	enemy._services.fireEnemyStateChanged(enemy.Model, AIState.Falling)
end

return JumpController
