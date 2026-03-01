--!strict
--[[
	VFXPool.luau
	============
	Singleton pool registry for ALL client-side VFX BaseParts.

	WHY A CENTRAL REGISTRY:
	Each VFX module (ExplosionVFX, ProjectileEffects, CombatEffects, LightningVFX)
	was creating and destroying Parts independently. That means:
	  - Four separate GC pressure sources with no coordination
	  - Each module independently calling Instance.new() per frame at peak load
	  - No ability to see the total Part count in flight

	This module owns all ObjectPool instances, creates all template parts
	procedurally at Init() time (no Studio template setup required), and
	provides a single three-function API used by every VFX file.

	POOL SIZES — rationale for each:
	  MuzzleFlash    8   — very short lifetime (0.05 s); 4 players × 2 rapid shots
	  Tracer        20   — 0.08 s lifetime; Scrapper + Shooter fire fast; +Buckshot 5-spread
	  HitSpark      48   — 4 sparks × 4 players × 3 targets, 0.25 s lifetime
	  HitFlash      20   — one per hit, 0.1 s lifetime
	  ImpactRing    10   — finisher only (every 3rd hit); two rings per finisher
	  SlashTrail    12   — melee combos; 0.2 s lifetime
	  LightningBeam 40   — up to 10 bounces × 4 players proc simultaneously
	  ExplosionSphere 6  — rare; single per explosion; 0.4 s lifetime
	  ExplosionDebris 64 — 8 shards × up to 8 simultaneous procs; 1.7 s lifetime
	  HitSparkEmitter 20 — generic emitter-Part; 1 s return delay

	HIT SPARK EMITTER POOL — special case:
	  "HitSparkEmitter" pool entries are Parts that have a pre-built ParticleEmitter
	  child. The emitter's Rate = 0 always; VFX code calls :Emit(n) to burst.
	  After return to pool, residual particles have already faded (lifetime ≤ 0.3 s).
	  Next use: emit again. Zero allocation on the hot path.

	PHYSICS PARTS (HitSpark, ExplosionDebris):
	  ObjectPool always returns parts with Anchored = true.
	  VFX code MUST follow this sequence:
	    1. part = VFXPool:GetPart("HitSpark")
	    2. part.CFrame = CFrame.new(spawnPos)   -- teleport while still anchored
	    3. part.Anchored = false                 -- release to physics
	    4. part.AssemblyLinearVelocity = vel     -- apply impulse
	  ObjectPool.ReturnPart() re-anchors and zeros velocity automatically.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ObjectPool = require(Shared:WaitForChild("ObjectPool"))

-- ── Module ───────────────────────────────────────────────────────────────────

local VFXPool = {}
VFXPool.Name = "VFXPool"

-- ── Private State ─────────────────────────────────────────────────────────────

-- Named pool instances, populated in Init().
local _pools: { [string]: any } = {}

-- Folder that holds all template parts (not storage — that is inside each pool).
local _templateFolder: Folder

-- ── Private: Template Factory ─────────────────────────────────────────────────

--[[
	_makePart(name, shape, material, size) -> BasePart

	Creates a bare template part with all VFX-safe defaults applied.
	Parented to _templateFolder so it stays alive for the duration of the session.
]]
local function _makePart(
	name: string,
	shape: Enum.PartType,
	material: Enum.Material,
	size: Vector3
): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Material = material
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1 -- dormant
	p.Color = Color3.fromRGB(255, 255, 255) -- default; overridden at use-time
	p.Parent = _templateFolder
	return p
end

--[[
	_makeEmitterPart(name, emitterConfig) -> BasePart

	Creates a template Part with a pre-configured ParticleEmitter child.
	Rate is always 0 — callers use :Emit(n) to burst particles.
	The emitter is fully configured here so no allocation occurs at use-time.
]]
local function _makeEmitterPart(
	name: string,
	color: ColorSequence,
	size: NumberSequence,
	transparency: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange,
	spreadAngle: Vector2,
	drag: number
): BasePart
	local p = _makePart(name, Enum.PartType.Ball, Enum.Material.Neon, Vector3.new(0.5, 0.5, 0.5))

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = color
	emitter.Size = size
	emitter.Transparency = transparency
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Lifetime = lifetime
	emitter.Speed = speed
	emitter.SpreadAngle = spreadAngle
	emitter.Drag = drag
	emitter.Rate = 0 -- BURST ONLY — never continuous
	emitter.Parent = p

	return p
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function VFXPool:Init()
	-- Template folder: holds one representative part per pool.
	-- Kept alive in workspace rather than nil to prevent Roblox's
	-- nil-parent deferred-destruction from eating our templates.
	_templateFolder = Instance.new("Folder")
	_templateFolder.Name = "VFXPool_Templates"
	_templateFolder.Parent = workspace

	-- ── MUZZLE FLASH ─────────────────────────────────────────────────────
	-- Orange-gold neon ball; very short lifetime (0.05 s).
	-- VFX code sets Color + Size before use.
	_pools["MuzzleFlash"] = ObjectPool.new(
		_makePart("MuzzleFlash", Enum.PartType.Ball, Enum.Material.Neon, Vector3.new(1.5, 1.5, 1.5)),
		8, -- initialSize
		8 -- expansionSize
	)

	-- ── BULLET TRACER ────────────────────────────────────────────────────
	-- Thin neon box; VFX code sets Size.Z to the bullet travel distance,
	-- CFrame to the midpoint facing the target.
	_pools["Tracer"] = ObjectPool.new(
		_makePart("BulletTracer", Enum.PartType.Block, Enum.Material.Neon, Vector3.new(0.15, 0.15, 1)),
		20,
		10
	)

	-- ── HIT SPARK ────────────────────────────────────────────────────────
	-- Tiny neon ball; used with physics (see physics sequence in module header).
	-- VFX code MUST: GetPart → set CFrame → Anchored=false → AssemblyLinearVelocity.
	_pools["HitSpark"] = ObjectPool.new(
		_makePart("HitSpark", Enum.PartType.Ball, Enum.Material.Neon, Vector3.new(0.1, 0.1, 0.1)),
		48,
		16
	)

	-- ── HIT FLASH ────────────────────────────────────────────────────────
	-- Small neon ball; expands and fades in ~0.1 s.
	-- Used for melee hits, bullet impacts, finisher pulses.
	_pools["HitFlash"] = ObjectPool.new(
		_makePart("HitFlash", Enum.PartType.Ball, Enum.Material.Neon, Vector3.new(0.8, 0.8, 0.8)),
		20,
		10
	)

	-- ── IMPACT RING ──────────────────────────────────────────────────────
	-- Flat cylinder used for ground shockwave rings.
	-- VFX code sets CFrame rotation (Angles 90°) + tweens Size outward.
	-- Used for BOTH the outer and inner rings (two GetPart() calls per finisher).
	_pools["ImpactRing"] = ObjectPool.new(
		_makePart("ImpactRing", Enum.PartType.Cylinder, Enum.Material.Neon, Vector3.new(0.5, 0.1, 0.5)),
		10,
		6
	)

	-- ── SLASH TRAIL ──────────────────────────────────────────────────────
	-- Flat block for melee slash arcs; VFX code sets Size + CFrame.
	_pools["SlashTrail"] = ObjectPool.new(
		_makePart("SlashTrail", Enum.PartType.Block, Enum.Material.Neon, Vector3.new(4, 0.1, 0.5)),
		12,
		6
	)

	-- ── LIGHTNING BEAM ───────────────────────────────────────────────────
	-- Very thin neon box; positioned between two chain targets.
	-- Color = electric cyan/white; flashes in and fades in 0.2 s.
	-- High initial count because chain procs can fire many bounces simultaneously.
	_pools["LightningBeam"] = ObjectPool.new(
		_makePart("LightningBeam", Enum.PartType.Block, Enum.Material.Neon, Vector3.new(0.08, 0.08, 1)),
		40,
		20
	)

	-- ── EXPLOSION SPHERE ─────────────────────────────────────────────────
	-- Large neon ball for the core explosion bloom.
	-- VFX code tweens Size outward and Transparency → 1 over 0.4 s.
	_pools["ExplosionSphere"] = ObjectPool.new(
		_makePart("ExplosionSphere", Enum.PartType.Ball, Enum.Material.Neon, Vector3.new(2, 2, 2)),
		6,
		4
	)

	-- ── EXPLOSION DEBRIS ─────────────────────────────────────────────────
	-- Wood-coloured block shards; used with physics (same sequence as HitSpark).
	-- Size is overridden per-shard with math.random at use-time.
	-- 64 slots: 8 shards × 8 simultaneous VolatileCasing explosions at 50 stacks.
	_pools["ExplosionDebris"] = ObjectPool.new(
		_makePart("ExplosionDebris", Enum.PartType.Block, Enum.Material.Wood, Vector3.new(0.5, 1.5, 0.2)),
		64,
		16
	)

	-- ── HIT SPARK EMITTER ────────────────────────────────────────────────
	-- Part with a pre-built ParticleEmitter child (Rate = 0, burst-only).
	-- Generic hit feedback: GetPart → position → :Emit(n) → ReturnPartDelayed(1 s).
	-- The emitter uses a generic yellow-orange-white spark colour sequence.
	-- VFX code can override Color by finding the emitter child before emitting.
	_pools["HitSparkEmitter"] = ObjectPool.new(
		_makeEmitterPart(
			"HitSparkEmitter",
			ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 200)),
				ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 180, 50)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 80, 10)),
			}),
			NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.45),
				NumberSequenceKeypoint.new(0.3, 0.28),
				NumberSequenceKeypoint.new(1, 0),
			}),
			NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.25),
				NumberSequenceKeypoint.new(1, 1),
			}),
			NumberRange.new(0.12, 0.25),
			NumberRange.new(12, 22),
			Vector2.new(50, 50),
			5
		),
		20,
		10
	)

	print("[VFXPool] Initialized —", #(function()
		local t = {}
		for k in _pools do
			t[#t + 1] = k
		end
		return t
	end)(), "pools ready")
end

-- ── Public API ────────────────────────────────────────────────────────────────

--[[
	VFXPool:GetPart(poolName) -> BasePart

	Returns a dormant part from the named pool, ready for configuration.
	If the pool doesn't exist (typo/missing Init call), falls back to
	Instance.new("Part") with a warning rather than erroring.
]]
function VFXPool:GetPart(poolName: string): BasePart
	local pool = _pools[poolName]
	if not pool then
		warn(string.format("[VFXPool] Unknown pool '%s' — falling back to Instance.new. Check pool name or call Init().", poolName))
		local fallback = Instance.new("Part")
		fallback.CanCollide = false
		fallback.CastShadow = false
		fallback.Anchored = true
		fallback.Parent = workspace
		return fallback
	end
	return pool:GetPart()
end

--[[
	VFXPool:ReturnPart(poolName, part)

	Returns a part to its pool immediately. Resets physics state.
	Call this after a tween completes and the part is no longer visible.
]]
function VFXPool:ReturnPart(poolName: string, part: BasePart)
	local pool = _pools[poolName]
	if pool then
		pool:ReturnPart(part)
	end
end

--[[
	VFXPool:ReturnPartDelayed(poolName, part, delay)

	Returns a part after `delay` seconds using task.delay.
	Fire-and-forget: no reference to the part is needed after this call.

	IMPORTANT: Do NOT touch the part after calling ReturnPartDelayed.
	The pool may re-issue it to another caller before the delay fires
	if the pool is under pressure — but this cannot happen because the
	delay is set to the VFX lifetime, not longer.
]]
function VFXPool:ReturnPartDelayed(poolName: string, part: BasePart, delay: number)
	local pool = _pools[poolName]
	if pool then
		pool:ReturnPartDelayed(part, delay)
	end
end

--[[
	VFXPool:EmitHitSpark(position, count, colorOverride?)

	Convenience helper for Task 4 — Generic Particle Emitter Pool.
	Gets a HitSparkEmitter part, positions it, emits `count` particles,
	and returns it to the pool after 1 second (particle lifetime is 0.25 s max,
	so the emitter is fully settled before return).

	@param position       Vector3   World position for the spark burst.
	@param count          number    Number of particles to emit.
	@param colorOverride  ColorSequence?  Optional replacement colour for the emitter.
]]
function VFXPool:EmitHitSpark(position: Vector3, count: number, colorOverride: ColorSequence?)
	local part = self:GetPart("HitSparkEmitter")

	-- Position the part while still anchored (safe).
	part.CFrame = CFrame.new(position)
	part.Transparency = 1 -- part itself is invisible; only emitter matters

	-- Optionally override the emitter colour for class-specific sparks.
	local emitter = part:FindFirstChildOfClass("ParticleEmitter")
	if emitter then
		if colorOverride then
			emitter.Color = colorOverride
		end
		emitter:Emit(count)
	end

	-- Return after the particle lifetime expires so no visible pop-out occurs.
	self:ReturnPartDelayed("HitSparkEmitter", part, 1.0)
end

--[[
	VFXPool:GetStats() -> { [poolName]: {total, active, free} }

	Returns utilisation stats for all pools. Useful during development:
	call this from a debug command and print to output to tune pool sizes.
]]
function VFXPool:GetStats(): { [string]: { total: number, active: number, free: number } }
	local stats = {}
	for name, pool in _pools do
		stats[name] = pool:GetStats()
	end
	return stats
end

-- ── Stub Lifecycle (required by Controller auto-discovery) ────────────────────

function VFXPool:Start() end

return VFXPool
