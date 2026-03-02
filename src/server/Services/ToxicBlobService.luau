--!strict
--[[
	ToxicBlobService.luau
	=====================
	Owns the lifecycle of every ToxicBlob projectile fired by the HexCaster.

	RESPONSIBILITIES:
	  • Maintain a pooled server-side blob Part (Neon sphere, toxic green).
	  • Compute an arc launch velocity and apply it via AssemblyLinearVelocity.
	  • Detect hits via .Touched (player characters) and terrain (any BasePart
	    the blob lands on that is not a player).
	  • On player hit  : deal direct damage + fire ToxicBlobImpact (no puddle).
	  • On ground hit  : spawn a Toxic Puddle + fire ToxicBlobImpact.
	  • Manage puddle tick-damage (every 0.5 s for 3 s) via a Heartbeat loop.
	  • Auto-return blobs to the pool after BLOB_LIFETIME seconds if they miss.

	INTEGRATION WITH HexCaster:
	  HexCaster:OnAttackEnter() calls ToxicBlobService:FireBlob() at windup
	  expiry. ToxicBlobService handles all server-side hit/damage/puddle logic.
	  EnemyVFXController.luau (client) listens to ToxicBlobImpact for splash VFX.

	SETUP — no Studio work required:
	  The blob template is built in code. If you later want a fancier mesh,
	  parent a Part named "ToxicBlob" under ReplicatedStorage.Shared.Assets.Projectiles
	  and this service will use that instead of the procedural fallback.
]]

-- ── Services ───────────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Shared Modules ─────────────────────────────────────────────────────────────

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ObjectPool = require(Shared:WaitForChild("ObjectPool"))
local Remotes = require(Shared:WaitForChild("Remotes"))

-- ── Constants ──────────────────────────────────────────────────────────────────

-- Height the blob rises above the launch point before falling to target (studs).
-- Apex-height arc: avoids the "rocket into sky" caused by long time-based flight durations.
local APEX_HEIGHT: number = 8

-- Kill-switch: if the blob flies for this long without hitting anything
-- (e.g. fired into the void), return it to the pool automatically.
local BLOB_LIFETIME: number = 8

-- Visual radius of the blob sphere in studs.
local BLOB_SIZE: Vector3 = Vector3.new(1.4, 1.4, 1.4)

-- Downward probe distance from blob centre used by the Heartbeat ground detector.
-- blob radius (0.7) + 0.5 gap; catches the instant the surface grazes terrain.
local GROUND_PROBE: number = BLOB_SIZE.Y / 2 + 0.5

-- Toxic green — Neon material makes it glow without a PointLight.
local BLOB_COLOR: Color3 = Color3.fromRGB(70, 220, 40)

-- Slow random spin added at launch for a tumbling organic look.
local SPIN_RANGE: number = 4 -- max radians/sec per axis

-- ── Puddle constants ────────────────────────────────────────────────────────────

local PUDDLE_RADIUS: number = 4.5 -- studs, horizontal proximity check
local PUDDLE_DURATION: number = 3 -- seconds the puddle stays active
local PUDDLE_TICK_INTERVAL: number = 0.5 -- seconds between damage pulses
local PUDDLE_HEIGHT: number = 0.25 -- thickness of the flat cylinder

-- ── Module ────────────────────────────────────────────────────────────────────

local ToxicBlobService = {}
ToxicBlobService.Name = "ToxicBlobService"

-- ── Private State ─────────────────────────────────────────────────────────────

local _blobPool: ObjectPool.ObjectPool
local _impactRemote: RemoteEvent

-- Per-blob debounce flag: prevents Touched firing twice before we disconnect.
-- Key = active blob Part; value = true while in debounce cooldown.
local _hitDebounce: { [BasePart]: boolean } = {}

-- ── Private: Template ─────────────────────────────────────────────────────────

--[[
	Tries to load a custom blob template from:
	  ReplicatedStorage.Shared.Assets.Projectiles.ToxicBlob
	Falls back to a procedurally-built sphere if the folder/asset is absent.

	STUDIO SETUP (optional, for richer visuals):
	  1. Create folder: ReplicatedStorage → Shared → Assets → Projectiles
	  2. Insert a Part named "ToxicBlob" (Shape: Ball, Size: 1.4,1.4,1.4).
	  3. Material: Neon.  Color: RGB(70, 220, 40).  CastShadow: false.
	  4. Add a Trail child:
	       Trail.Attachment0 = front attachment (0, 0, -0.7 offset from centre)
	       Trail.Attachment1 = rear  attachment (0, 0,  0.7 offset from centre)
	       Trail.Color: ColorSequence (bright green → transparent)
	       Trail.Transparency: NumberSequence (0 → 1)
	       Trail.Lifetime: 0.25
	       Trail.MinDistance: 0.05
	  5. Add a ParticleEmitter child:
	       Rate: 30,  Lifetime: 0.15–0.3,  Speed: 0–1
	       Color: bright lime green → transparent
	       Size: NumberSequence (0.2 → 0)
	       Rotation: random,  RotSpeed: 60–120 deg/s
	       (Drag modifier: enabled, 5 drag — makes particles decelerate naturally)
	  6. Set the Part as Anchored=true, CanCollide=false before saving — the
	     pool and FireBlob() configure them correctly at runtime.
]]
local function getBlobTemplate(): BasePart
	local assets = Shared:FindFirstChild("Assets")
	if assets then
		local projectiles = assets:FindFirstChild("Projectiles")
		if projectiles then
			local custom = projectiles:FindFirstChild("ToxicBlob")
			if custom and custom:IsA("BasePart") then
				return custom
			end
		end
	end

	-- Procedural fallback — no Studio setup needed to get started.
	local t = Instance.new("Part")
	t.Name = "ToxicBlob"
	t.Shape = Enum.PartType.Ball
	t.Size = BLOB_SIZE
	t.Color = BLOB_COLOR
	t.Material = Enum.Material.Neon
	t.CastShadow = false
	t.Anchored = true
	t.CanCollide = false
	t.CanTouch = false
	t.Transparency = 1
	-- Parent before pool creation — Roblox GCs nil-parented instances.
	t.Parent = workspace
	return t
end

-- ── Private: Arc Physics ───────────────────────────────────────────────────────

--[[
	Computes AssemblyLinearVelocity for a natural arc from p0 to p1.
	Uses an apex-height approach: the blob rises APEX_HEIGHT studs above p0,
	then falls freely to p1. This gives a consistent, visible arc regardless
	of horizontal distance.

	Derivation:
	  vy0     = sqrt(2 × g × APEX_HEIGHT)   initial upward Y speed
	  t_up    = vy0 / g                      time to apex
	  apexY   = p0.Y + APEX_HEIGHT
	  fallDist = max(0.1, apexY − p1.Y)     height to fall from apex to target
	  t_down  = sqrt(2 × fallDist / g)
	  totalT  = t_up + t_down
	  vx/vz   = horizontal delta / totalT
]]
local function computeArcVelocity(p0: Vector3, p1: Vector3): Vector3
	local g = workspace.Gravity
	local vy0 = math.sqrt(2 * g * APEX_HEIGHT)
	local t_up = vy0 / g
	local apexY = p0.Y + APEX_HEIGHT
	local fallDist = math.max(0.1, apexY - p1.Y)
	local t_down = math.sqrt(2 * fallDist / g)
	local totalT = t_up + t_down
	return Vector3.new((p1.X - p0.X) / totalT, vy0, (p1.Z - p0.Z) / totalT)
end

-- ── Private: Puddle ────────────────────────────────────────────────────────────

--[[
	Spawns a glowing puddle at `hitPos` that deals `tickDamage` HP every
	PUDDLE_TICK_INTERVAL seconds to any player within PUDDLE_RADIUS studs.
	The puddle fades out and self-destructs after PUDDLE_DURATION seconds.

	Not pooled — puddles are rare (one per ground hit, max one per HexCaster
	in flight at a time), so the instance overhead is negligible.
]]
local function spawnPuddle(hitPos: Vector3, tickDamage: number)
	local puddle = Instance.new("Part")
	puddle.Name = "ToxicPuddle"
	-- Roblox cylinders stand upright along the Y axis by default.
	-- We rotate 90° around Z so the flat face is horizontal.
	puddle.Shape = Enum.PartType.Cylinder
	puddle.Size = Vector3.new(PUDDLE_HEIGHT, PUDDLE_RADIUS * 2, PUDDLE_RADIUS * 2)
	puddle.Color = Color3.fromRGB(30, 130, 15)
	puddle.Material = Enum.Material.Neon
	puddle.Transparency = 0.35
	puddle.Anchored = true
	puddle.CanCollide = false
	puddle.CanTouch = false
	puddle.CastShadow = false
	-- Sit the puddle flush on the ground surface.
	puddle.CFrame = CFrame.new(hitPos.X, hitPos.Y + PUDDLE_HEIGHT * 0.5, hitPos.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	puddle.Parent = workspace

	local startTime = os.clock()
	local lastTick = startTime

	-- Heartbeat: fade + tick damage in a single connection to keep overhead low.
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if not puddle.Parent then
			conn:Disconnect()
			return
		end

		local now = os.clock()
		local age = now - startTime

		-- Destroy after duration.
		if age >= PUDDLE_DURATION then
			conn:Disconnect()
			puddle:Destroy()
			return
		end

		-- Fade to invisible over the last second.
		if age > PUDDLE_DURATION - 1 then
			puddle.Transparency = 0.35 + 0.65 * ((age - (PUDDLE_DURATION - 1)) / 1)
		end

		-- Damage pulse every PUDDLE_TICK_INTERVAL seconds.
		if now - lastTick >= PUDDLE_TICK_INTERVAL then
			lastTick = now
			local puddlePos = puddle.Position
			for _, player in Players:GetPlayers() do
				local char = player.Character
				if not char then
					continue
				end
				local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not hrp then
					continue
				end
				-- 2D horizontal distance only — puddle is flat, we don't care about Y.
				local dx = hrp.Position.X - puddlePos.X
				local dz = hrp.Position.Z - puddlePos.Z
				if dx * dx + dz * dz <= PUDDLE_RADIUS * PUDDLE_RADIUS then
					local hum = char:FindFirstChildOfClass("Humanoid")
					if hum and hum.Health > 0 then
						hum:TakeDamage(tickDamage)
					end
				end
			end
		end
	end)
end

-- ── Init / Start ───────────────────────────────────────────────────────────────

function ToxicBlobService:Init()
	_impactRemote = Remotes:GetEvent("ToxicBlobImpact") :: RemoteEvent

	local template = getBlobTemplate()
	-- 20 pre-allocated blobs: far more than can ever be in flight simultaneously.
	-- maxIdleLimit = 20 so the pool never culls below that floor.
	_blobPool = ObjectPool.new(template, 20, 8, 20)
end

function ToxicBlobService:Start()
	-- No perpetual loop needed — work is driven by FireBlob() calls.
end

-- ── Public: FireBlob ──────────────────────────────────────────────────────────

--[[
	ToxicBlobService:FireBlob(origin, targetPos, damage, tickDamage, shooter)

	Launches one ToxicBlob from `origin` toward `targetPos` on an arc.

	@param origin     Vector3  Launch position (HexCaster's RootPart.Position).
	@param targetPos  Vector3  World position to arc toward (player HRP position
	                           captured at windup expiry, not at fire time).
	@param damage     number   Direct hit damage (applied to player Humanoid).
	@param tickDamage number   Damage per puddle tick (applied every 0.5 s).
	@param shooter    Model    The HexCaster's model — excluded from self-hit.
]]
function ToxicBlobService:FireBlob(
	origin: Vector3,
	targetPos: Vector3,
	damage: number,
	tickDamage: number,
	shooter: Model
)
	local blob = _blobPool:GetPart()

	-- ── Activate blob ─────────────────────────────────────────────────────
	blob.CFrame = CFrame.new(origin)
	blob.Transparency = 0
	blob.CanCollide = false -- blob flies through terrain; hits detected via Touched
	blob.CanTouch = true
	blob.Anchored = false
	blob.Parent = workspace

	-- ── Apply arc + spin ─────────────────────────────────────────────────
	blob.AssemblyLinearVelocity = computeArcVelocity(origin, targetPos)
	blob.AssemblyAngularVelocity = Vector3.new(
		math.random() * SPIN_RANGE * 2 - SPIN_RANGE,
		math.random() * SPIN_RANGE * 2 - SPIN_RANGE,
		math.random() * SPIN_RANGE * 2 - SPIN_RANGE
	)

	-- ── Hit handling ──────────────────────────────────────────────────────
	local returned = false

	local function returnBlob()
		if returned then
			return
		end
		returned = true
		_hitDebounce[blob] = nil
		_blobPool:ReturnPart(blob)
	end

	-- Declare both connections up front so each closure can reference the other.
	local touchConn: RBXScriptConnection
	local groundConn: RBXScriptConnection

	-- RaycastParams for ground probe: exclude shooter so HexCaster parts don't self-hit.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { shooter }

	-- Touched: handles player-body hits and non-terrain BasePart ground hits.
	touchConn = blob.Touched:Connect(function(hit: BasePart)
		if returned or _hitDebounce[blob] then
			return
		end
		-- Never trigger on the shooter's own parts.
		if hit:IsDescendantOf(shooter) then
			return
		end

		_hitDebounce[blob] = true
		touchConn:Disconnect()
		groundConn:Disconnect()

		local hitPos = blob.Position
		local isGroundHit = true

		-- ── Player hit? ───────────────────────────────────────────────────
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if player then
			isGroundHit = false
			local hum = (hit.Parent :: Model):FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				hum:TakeDamage(damage)
			end
		end

		-- ── Broadcast impact VFX ─────────────────────────────────────────
		_impactRemote:FireAllClients(hitPos, isGroundHit)

		-- ── Spawn puddle on ground/terrain hits ───────────────────────────
		if isGroundHit then
			spawnPuddle(hitPos, tickDamage)
		end

		returnBlob()
	end)

	-- Heartbeat ground probe: supplements Touched for smooth terrain.
	-- workspace.Terrain does not reliably fire Touched for CanCollide=false parts;
	-- a short downward raycast catches the moment the blob grazes the surface.
	-- Only probes while the blob is descending to avoid false positives at launch.
	groundConn = RunService.Heartbeat:Connect(function()
		if returned then
			groundConn:Disconnect()
			return
		end
		-- Still rising — skip.
		if blob.AssemblyLinearVelocity.Y > 0 then
			return
		end
		local pos = blob.Position
		local ray = workspace:Raycast(pos, Vector3.new(0, -GROUND_PROBE, 0), groundParams)
		if not ray then
			return
		end
		-- Ignore player character parts — Touched handles those.
		if Players:GetPlayerFromCharacter(ray.Instance.Parent) then
			return
		end
		-- Ground contact confirmed.
		groundConn:Disconnect()
		touchConn:Disconnect()
		if returned or _hitDebounce[blob] then
			return
		end
		_hitDebounce[blob] = true
		_impactRemote:FireAllClients(pos, true)
		spawnPuddle(pos, tickDamage)
		returnBlob()
	end)

	-- ── Safety timeout ────────────────────────────────────────────────────
	-- If the blob flies into the void or misses entirely, reclaim it.
	task.delay(BLOB_LIFETIME, function()
		groundConn:Disconnect()
		touchConn:Disconnect()
		returnBlob()
	end)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return ToxicBlobService
