--!strict
--[[
	ObjectPool.luau
	===============
	Advanced Part/Instance pooling system to eliminate Garbage Collection spikes
	caused by frequent Instance.new() / :Destroy() calls for VFX, projectiles, and
	short-lived BaseParts (Air Slashes, chain-lightning sparks, explosion debris).

	WHY GC SPIKES HAPPEN:
	Every Instance.new() allocates a Lua userdata wrapper on the Lua heap AND
	triggers a C++ heap allocation inside the Roblox engine. When :Destroy() is
	called, the C++ object is freed immediately, but the Lua userdata sits on the
	heap until the next GC cycle. The Lua GC runs mark-and-sweep: it must pause
	execution (a "stop-the-world" pause) to trace all live references. The more
	short-lived objects you create and destroy per second, the more GC pressure
	you accumulate, and the more frequent and longer those pauses become.

	HOW POOLING SOLVES THIS:
	Instead of destroying a part, we teleport it to a hidden parking zone
	10,000 studs underground and reset its properties. The Lua userdata wrapper
	is never freed — it stays alive, the GC never marks it as dead, and the
	stop-the-world pause is avoided entirely. We pay the Instance.new() cost
	once (at pool construction or expansion), never on the hot VFX path.

	PERFORMANCE CHARACTERISTICS:
	  GetPart()    → O(1) amortised (O(expansionSize) on rare expansion)
	  ReturnPart() → O(1) always
	  Query stats  → O(1) always
	  Expansion    → O(expansionSize), batched to amortise clone cost

	USAGE EXAMPLE (server VFX):
	  local slashTemplate = workspace.Templates.AirSlash  -- pre-made BasePart
	  local slashPool = ObjectPool.new(slashTemplate, 40, 20)

	  -- Inside air-slash VFX:
	  local slash = slashPool:GetPart()
	  slash.CFrame = hitCFrame
	  slash.Transparency = 0
	  slash.CanCollide = false
	  task.delay(0.18, function()
	      slashPool:ReturnPart(slash)
	  end)

	OOP DESIGN:
	  ObjectPool.new() returns a table with ObjectPool as its metatable.
	  All methods operate on `self`, so multiple independent pools can coexist
	  (one per VFX type, one for projectiles, etc.) without sharing state.
]]

-- ── Module Declaration ──────────────────────────────────────────────────────

local ObjectPool = {}
ObjectPool.__index = ObjectPool

-- ── Constants ───────────────────────────────────────────────────────────────

-- Parts are parked at this CFrame when dormant.
-- 10,000 studs underground ensures:
--   1. They are outside every player's camera frustum (no draw calls).
--   2. They are beyond distance-based LOD thresholds.
--   3. They cannot accidentally overlap gameplay geometry.
local PARK_CFRAME: CFrame = CFrame.new(0, -10000, 0)

-- Default number of parts to mint per expansion batch.
-- Growing by 1 at a time would cause an O(n) series of Clone() calls on a
-- single hot frame. Batching amortises that cost across future frames.
local DEFAULT_EXPANSION_SIZE: number = 16

-- ── Type Declarations ────────────────────────────────────────────────────────

-- Public type exported so callers can annotate variables.
export type ObjectPool = typeof(setmetatable(
	{} :: {
		_template: BasePart,
		_expansionSize: number,
		_maxIdleLimit: number,
		_freeList: { BasePart },
		_totalCreated: number,
		_activeCount: number,
		_storageFolder: Folder,
	},
	ObjectPool
))

-- ── Constructor ──────────────────────────────────────────────────────────────

--[[
	ObjectPool.new(template, initialSize, expansionSize?) -> ObjectPool

	Creates a new pool pre-populated with `initialSize` clones of `template`.

	@param template      BasePart   The source part to clone for every pool slot.
	                                MUST be parented somewhere in the DataModel
	                                (not nil) before passing here, otherwise
	                                Roblox may GC it between frames.

	@param initialSize   number     Parts to pre-allocate at construction time.
	                                Set this to your expected PEAK demand so no
	                                runtime expansion occurs on the first busy
	                                frame (e.g. 40 for air-slash pools, 80 for
	                                chain-lightning spark pools).

	@param expansionSize number?    Parts to add per expansion batch when the
	                                pool runs dry. Defaults to DEFAULT_EXPANSION_SIZE.
	                                Tune upward if your pool frequently exhausts.

	@param maxIdleLimit  number?    Maximum dormant parts to keep alive when culling.
	                                Every 60 seconds the pool destroys free parts
	                                beyond this cap to reclaim RAM. Defaults to
	                                `initialSize` (never cull the original allocation).
]]
function ObjectPool.new(template: BasePart, initialSize: number, expansionSize: number?, maxIdleLimit: number?): ObjectPool
	-- Validate inputs at construction time so bugs surface immediately,
	-- not silently during a frame-critical GetPart() call at runtime.
	assert(
		typeof(template) == "Instance" and template:IsA("BasePart"),
		"[ObjectPool] `template` must be a BasePart instance."
	)
	assert(
		type(initialSize) == "number" and initialSize > 0 and initialSize == math.floor(initialSize),
		"[ObjectPool] `initialSize` must be a positive integer."
	)

	local self = setmetatable({}, ObjectPool)

	-- Keep a reference to the template so we can Clone() it during expansion
	-- without the caller needing to pass it again. The template itself is
	-- NEVER issued to callers — only its clones are.
	self._template = template

	-- Batch size for runtime expansion. Stored per-pool so different pools
	-- can have different growth strategies.
	self._expansionSize = expansionSize or DEFAULT_EXPANSION_SIZE

	-- Idle ceiling for the Cull() background loop.
	-- If the free list exceeds this count, excess parts are :Destroy()ed.
	self._maxIdleLimit = maxIdleLimit or initialSize

	-- The free list is a stack (LIFO array). We use table.insert/remove on
	-- the END of the array, which is O(1) in Luau (no shifting required).
	-- LIFO ordering is intentional: recently-returned parts are still in
	-- CPU cache, making LIFO slightly faster than FIFO for memory access.
	self._freeList = {} :: { BasePart }

	-- Diagnostic counters. Neither is used in the hot path; they exist
	-- purely for GetStats() and leak detection tooling.
	self._totalCreated = 0 -- total parts ever minted by this pool
	self._activeCount = 0 -- parts currently checked out by callers

	-- A dedicated Folder holds all dormant parts.
	-- CRITICAL: Parts must be parented to a real Instance (not nil).
	-- Roblox's instance lifecycle will schedule destruction of nil-parented
	-- instances within 1-2 frames, which would corrupt the pool silently.
	self._storageFolder = Instance.new("Folder")
	self._storageFolder.Name = "ObjectPool_" .. template.Name
	self._storageFolder.Parent = workspace -- workspace persists for the session

	-- Pre-populate to initialSize. Done synchronously in the constructor so
	-- the caller's first frame of heavy usage hits no allocation cost.
	self:_expand(initialSize)

	-- Background culling loop: every 60 seconds, destroy excess dormant parts
	-- so a burst event (horde wave) that grew the pool doesn't permanently bloat RAM.
	-- The loop checks the storage folder parent to detect pool destruction.
	task.spawn(function()
		while self._storageFolder and self._storageFolder.Parent do
			task.wait(60)
			self:Cull()
		end
	end)

	return self :: ObjectPool
end

-- ── Private: Part Creation ────────────────────────────────────────────────────

--[[
	ObjectPool:_createOne() -> BasePart

	Clones the template, configures it as "dormant", and parents it to the
	storage folder. Called only from _expand(); never from the hot path.

	Properties set on dormant parts and WHY each one matters:

	  Transparency = 1    → Renderer skips the geometry pass entirely for
	                         fully-transparent parts. Zero draw calls.

	  CanCollide = false  → Disables this part in the physics broadphase.
	                         The broadphase is O(n log n); removing dormant
	                         parts shrinks n, reducing its cost.

	  CanTouch = false    → Prevents Touched / TouchEnded event overhead.
	                         Each collidable part adds an entry to Roblox's
	                         internal touch-tracking table.

	  Anchored = true     → Frozen parts are entirely skipped by the physics
	                         island solver. This is the single largest win:
	                         an anchored part costs nearly zero physics budget.

	  CastShadow = false  → Shadow maps are re-rendered every frame from
	                         shadow-casting geometry. Parked parts underground
	                         should never cast shadows into the play area.

	  AssemblyLinearVelocity  = zero  →  Cleared so a re-issued part doesn't
	  AssemblyAngularVelocity = zero     inherit stale velocity if it was
	                                     temporarily unanchored during its
	                                     previous use (e.g. projectile flight).
]]
function ObjectPool:_createOne(): BasePart
	-- Clone() is the only expensive call in the entire pool system.
	-- It costs ~3–8 µs per call depending on part complexity and the number
	-- of child instances. This is why we batch-allocate.
	local part: BasePart = self._template:Clone()

	-- Parent FIRST. Roblox defers property replication to the client until
	-- the parent is set; setting properties on a nil-parented instance is
	-- technically allowed but some property writes (e.g. Anchored) may not
	-- behave correctly until the parent chain is resolved.
	part.Parent = self._storageFolder

	-- ── Dormant state configuration ──────────────────────────────────────
	part.CFrame = PARK_CFRAME -- move underground immediately
	part.Transparency = 1 -- invisible to renderer
	part.CanCollide = false -- out of broadphase
	part.CanTouch = false -- no Touched events
	part.Anchored = true -- skipped by physics solver
	part.CastShadow = false -- no shadow overhead
	part.AssemblyLinearVelocity = Vector3.zero -- clear residual velocity
	part.AssemblyAngularVelocity = Vector3.zero -- clear residual spin

	-- Increment the diagnostic counter.
	self._totalCreated += 1

	return part
end

-- ── Private: Expansion ────────────────────────────────────────────────────────

--[[
	ObjectPool:_expand(count)

	Mints `count` new parts and pushes them onto the free list.
	Called by the constructor (initial fill) and GetPart() (runtime exhaustion).

	Expansion is always batched (never 1-at-a-time) to spread Clone() cost
	across multiple frames via task.defer would break the synchronous contract,
	so we accept the cost inline — but the batch size should be tuned so
	expansion events are rare (< once per 10 seconds of heavy gameplay).

	@param count  number  Number of parts to mint in this expansion.
]]
function ObjectPool:_expand(count: number)
	for _ = 1, count do
		-- Push to the END of the array for O(1) insertion (stack discipline).
		self._freeList[#self._freeList + 1] = self:_createOne()
	end
end

-- ── Public: GetPart ───────────────────────────────────────────────────────────

--[[
	ObjectPool:GetPart() -> BasePart

	Checks out one part from the free list. If the free list is empty, the pool
	auto-expands by _expansionSize parts before returning one.

	CONTRACT FOR CALLERS:
	  1. Set CFrame to the desired world position immediately after GetPart().
	  2. Configure Transparency, Size, Color, Material, etc. for this use.
	  3. If you need CanCollide = true or Anchored = false, set those too.
	  4. Call ReturnPart() when the part is finished (after tweens complete,
	     after the hitbox lifetime ends, etc.).
	  5. Do NOT call :Destroy() on a pooled part. Ever.
	  6. Do NOT hold references to the part after calling ReturnPart().

	Time complexity: O(1) amortised.
	Space complexity: O(1).

	@return BasePart  A configured, dormant part ready for placement.
]]
function ObjectPool:GetPart(): BasePart
	-- Check for exhaustion before attempting to pop.
	if #self._freeList == 0 then
		-- Issue a warning in development so engineers know to raise initialSize.
		-- We don't error here because a late expansion is better than a crash.
		warn(string.format(
			"[ObjectPool] '%s' pool exhausted (total=%d active=%d). Expanding by %d — consider raising initialSize.",
			self._template.Name,
			self._totalCreated,
			self._activeCount,
			self._expansionSize
		))
		self:_expand(self._expansionSize)
	end

	-- Pop from the END of the array — O(1), no shifting.
	local part: BasePart = self._freeList[#self._freeList]
	self._freeList[#self._freeList] = nil

	-- Track how many parts are currently outstanding.
	-- If _activeCount grows without bound, there is a leak (caller not
	-- returning parts). Cross-reference with GetStats() in diagnostics.
	self._activeCount += 1

	return part
end

-- ── Public: ReturnPart ────────────────────────────────────────────────────────

--[[
	ObjectPool:ReturnPart(part)

	Returns a part to the free list, resetting it to the dormant state.
	The pool parks the part underground and clears all runtime modifications
	so the next caller receives a clean, predictable object.

	WARNING — DOUBLE-RETURN:
	Returning the same part twice is a logic bug analogous to a double-free
	in C. The second return will push a duplicate reference onto the free list,
	so two future callers receive the same BasePart object. This guard is
	deliberately lightweight (one nil check) — it detects the most obvious
	case (returning a destroyed part) but cannot detect all double-returns.
	Callers should nil their local reference after ReturnPart() to minimise
	risk: `pool:ReturnPart(part); part = nil`.

	Time complexity: O(1).

	@param part  BasePart  The part to return. Must have been obtained via GetPart().
]]
function ObjectPool:ReturnPart(part: BasePart)
	-- Guard: if the part was somehow destroyed externally (e.g. workspace:ClearAllChildren
	-- in a round-reset script), skip the return to avoid operating on a dead instance.
	if not part or not part.Parent then
		warn("[ObjectPool] ReturnPart() called with a nil or destroyed part. Skipping.")
		self._activeCount = math.max(0, self._activeCount - 1)
		return
	end

	-- ── Reset to dormant state ────────────────────────────────────────────
	-- Every property set here undoes a change the caller may have made.
	-- We reset unconditionally (not conditionally) because the branch
	-- overhead of checking `if part.Transparency ~= 1 then` is not worth it.

	part.Transparency = 1 -- hide from renderer
	part.CanCollide = false -- remove from broadphase
	part.CanTouch = false -- disable Touched events
	part.Anchored = true -- freeze in physics solver
	part.CastShadow = false -- no shadow cost
	part.AssemblyLinearVelocity = Vector3.zero -- clear linear velocity
	part.AssemblyAngularVelocity = Vector3.zero -- clear angular velocity

	-- Reparent to storage folder. The caller may have reparented the part
	-- to a model or another folder during use (e.g. to attach accessories).
	-- Reparenting is O(1) in Roblox's scene graph (linked list adjustment).
	part.Parent = self._storageFolder

	-- Park underground AFTER reparenting, so the CFrame write is authoritative
	-- against the storage folder's coordinate space (which is world-space).
	part.CFrame = PARK_CFRAME

	-- Push back to the top of the stack — O(1).
	self._freeList[#self._freeList + 1] = part

	self._activeCount -= 1
end

-- ── Public: ReturnPartDelayed ─────────────────────────────────────────────────

--[[
	ObjectPool:ReturnPartDelayed(part, delay)

	Convenience wrapper that returns a part after `delay` seconds using task.delay.
	Useful for fire-and-forget VFX where the lifetime is fixed.

	Example:
	  local spark = sparkPool:GetPart()
	  spark.CFrame = hitPos
	  spark.Transparency = 0
	  sparkPool:ReturnPartDelayed(spark, 0.25)
	  -- No manual cleanup needed.

	@param part   BasePart
	@param delay  number    Seconds to wait before returning.
]]
function ObjectPool:ReturnPartDelayed(part: BasePart, delay: number)
	-- task.delay schedules a callback on the task scheduler with minimal overhead.
	-- It is NOT a busy-wait; the thread yields completely until the delay expires.
	task.delay(delay, function()
		self:ReturnPart(part)
	end)
end

-- ── Public: Prewarm ───────────────────────────────────────────────────────────

--[[
	ObjectPool:Prewarm(targetSize)

	Expands the pool to at least `targetSize` total parts.
	Useful to call before a predictably heavy event (boss spawn, chest explosion)
	so no runtime expansion occurs during the event itself.

	If the pool already has >= targetSize parts, this is a no-op.

	@param targetSize  number  Desired minimum total pool size (free + active).
]]
function ObjectPool:Prewarm(targetSize: number)
	local current = self._totalCreated
	if targetSize > current then
		self:_expand(targetSize - current)
	end
end

-- ── Public: GetStats ──────────────────────────────────────────────────────────

--[[
	ObjectPool:GetStats() -> {total: number, active: number, free: number}

	Returns a snapshot of pool utilisation for diagnostics.
	Log this periodically (e.g. every 10 seconds) to detect leaks:
	  - If `active` grows monotonically without returning, parts are leaking.
	  - If `total` grows faster than expected, expansionSize is too small.
]]
function ObjectPool:GetStats(): { total: number, active: number, free: number }
	return {
		total = self._totalCreated, -- all parts ever minted
		active = self._activeCount, -- currently checked out
		free = #self._freeList, -- available for immediate reuse
	}
end

-- ── Public: Cull ─────────────────────────────────────────────────────────────

--[[
	ObjectPool:Cull()

	Destroys free (dormant) parts that exceed _maxIdleLimit.

	Call pattern: the background task.spawn loop fires this every 60 seconds.
	Callers may also invoke it manually before memory-sensitive operations.

	WHY we only cull the FREE list:
	  Active parts are in use by callers and must not be touched. We only
	  destroy parts that are parked underground and immediately available for
	  re-issue. If demand spikes again after a cull, the pool re-expands
	  normally via GetPart() — paying Clone() cost once per new burst.

	Time complexity: O(excess) where excess = free - maxIdleLimit.
]]
function ObjectPool:Cull()
	local idleCount = #self._freeList
	local excess = idleCount - self._maxIdleLimit
	if excess <= 0 then
		return
	end

	-- Destroy from the TAIL of the free list (LIFO — most recently returned
	-- parts, which are cold in cache and least likely to be needed next).
	for _ = 1, excess do
		local part = self._freeList[#self._freeList]
		self._freeList[#self._freeList] = nil
		part:Destroy()
		self._totalCreated -= 1
	end

	-- Optional: diagnostic log (remove in production if too noisy).
	-- print(string.format("[ObjectPool] '%s' culled %d parts (idle now %d).", self._template.Name, excess, self._maxIdleLimit))
end

-- ── Public: Destroy ───────────────────────────────────────────────────────────

--[[
	ObjectPool:Destroy()

	Tears down the pool completely. Destroys the storage folder (and all child
	parts via Roblox's instance hierarchy cleanup) and clears all Lua references.
	Call this on round-end or when the pool is no longer needed to free memory.

	WARNING: Any parts currently checked out (active) become orphaned when the
	folder is destroyed. Callers holding references to those parts will get a
	destroyed-instance error if they try to use them. Ensure all callers have
	finished before calling Destroy().
]]
function ObjectPool:Destroy()
	-- Destroying the folder destroys all child parts atomically.
	-- Roblox's C++ destructor walk is more efficient than destroying
	-- each part individually from Lua (no per-iteration Lua→C++ call overhead).
	self._storageFolder:Destroy()

	-- Clear the Lua table so the GC can collect the array's memory.
	table.clear(self._freeList)

	self._totalCreated = 0
	self._activeCount = 0
end

-- ── Return ────────────────────────────────────────────────────────────────────

return ObjectPool
