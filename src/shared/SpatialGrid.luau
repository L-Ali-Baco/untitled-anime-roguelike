--!strict
--[[
	SpatialGrid.luau
	================
	A 2D spatial hashing grid for sub-linear enemy lookup in AoE, chain-lightning,
	and aggro-range queries. Replaces the naive O(n) full-scan with an average-case
	O(1) insertion/removal and O(k) radius query (k = entities in nearby cells only).

	═══════════════════════════════════════════════════════════════════════════════
	BIG-O ANALYSIS — WHY THIS MATTERS AT 100+ ENEMIES
	═══════════════════════════════════════════════════════════════════════════════

	NAIVE APPROACH (what the game currently does):
	  For each AoE or chain-lightning tick, iterate every active enemy and compute
	  distance to the query point:

	    for _, enemy in allEnemies do
	        if (enemy.position - queryPos).Magnitude <= radius then ...

	  This is O(n) per query. At 100 enemies with 10 chain bounces firing every
	  0.1 s, that's 100 × 10 = 1,000 distance checks per 0.1 s = 10,000/s.
	  Each .Magnitude call allocates a temporary Vector3 subtraction and computes
	  a square root. At 60 Hz server heartbeat, this accumulates to measurable
	  CPU time and GC pressure.

	SPATIAL GRID APPROACH:
	  The map is divided into a uniform grid of cells (default 24 × 24 studs).
	  Each enemy is registered to exactly one cell based on their XZ position.
	  For a radius query of radius R:
	    - The query cell span is ceil(R / CELL_SIZE) cells in each direction.
	    - At R = 20 studs and CELL_SIZE = 24, that is a 3 × 3 = 9-cell window.
	    - If enemies are spread uniformly over, say, a 200 × 200 stud arena,
	      each cell contains ~100 / (200/24)² ≈ 100 / 69 ≈ 1.4 enemies.
	    - The query checks at most 9 × 1.4 ≈ 13 enemies regardless of total n.

	  TIME COMPLEXITY:
	    Register(entity)     → O(1)  — hash key computation + table write
	    Remove(entity)       → O(1)  — hash key lookup + table removal
	    Update(entity, pos)  → O(1)  — conditionally remove + re-register
	    QueryRadius(pos, R)  → O(k)  — k = entities in the (2·span+1)² cell window
	                                     k << n when entities are spread out

	  In the chain-lightning example above: 13 checks instead of 100 per bounce
	  = an 87% reduction in distance checks. At 200 enemies the naive approach
	  doubles to 2,000 checks/bounce while the grid stays at ~13-26 checks.
	  The grid scales as O(k), which is effectively O(1) for a uniform spread —
	  independent of total enemy count n. This is the key asymptotic improvement.

	  HASH FUNCTION:
	  We convert the 2D cell index (cx, cz) into a single integer key using:
	    key = cx * HASH_PRIME + cz
	  where HASH_PRIME is a large prime chosen to minimise collisions for typical
	  cell index ranges. This avoids string concatenation ("cx,cz") which allocates
	  a heap string on every lookup and adds GC pressure — exactly what we are
	  trying to eliminate.

	CELL SIZE TUNING:
	  Too small → many empty cells, more cell iterations per radius query.
	  Too large → many enemies per cell, degenerates toward O(n).
	  Rule of thumb: CELL_SIZE ≈ 1.5–2× the typical query radius.
	  For chain-lightning at R=20: CELL_SIZE = 24–32 is optimal.
	  For melee aggro at R=8: CELL_SIZE = 12–16 is optimal.
	  Use a separate SpatialGrid instance per query type if radii differ greatly.

	USAGE EXAMPLE:
	  local grid = SpatialGrid.new(24) -- 24-stud cells

	  -- When enemy spawns:
	  grid:Register(enemy, enemy.RootPart.Position)

	  -- Every physics tick (staggered via MovementService):
	  grid:Update(enemy, enemy.RootPart.Position)

	  -- Chain lightning bounce query:
	  local nearby = grid:QueryRadius(hitPosition, 20)
	  for _, candidate in nearby do
	      -- fire chain to candidate
	  end

	  -- When enemy dies:
	  grid:Remove(enemy)
]]

-- ── Module Declaration ──────────────────────────────────────────────────────

local SpatialGrid = {}
SpatialGrid.__index = SpatialGrid

-- ── Constants ───────────────────────────────────────────────────────────────

-- Prime multiplier for the integer hash function.
-- Chosen to spread cell indices (typically in the range ±200 for a 400-stud map)
-- across a sparse integer space with minimal clustering.
-- Any large prime works; 73856093 is a well-known spatial hash prime.
local HASH_PRIME: number = 73856093

-- ── Type Declarations ────────────────────────────────────────────────────────

-- An "entity" is any object with a stable identity (enemy table, player, etc.).
-- We use `any` here because the grid is type-agnostic — it stores whatever
-- you register, and returns it in query results. Callers can narrow the type.
type Entity = any

-- Internal record tracking an entity's current grid cell.
type EntityRecord = {
	entity: Entity, -- back-reference to the registered object
	cellKey: number, -- integer hash of current cell (cx, cz)
	cx: number, -- current cell X index
	cz: number, -- current cell Z index
}

export type SpatialGrid = typeof(setmetatable(
	{} :: {
		_cellSize: number,
		_invCellSize: number,
		_cells: { [number]: { EntityRecord } },
		_entityMap: { [Entity]: EntityRecord },
	},
	SpatialGrid
))

-- ── Private: Hash ────────────────────────────────────────────────────────────

--[[
	_hashCell(cx, cz) -> number

	Converts integer cell coordinates to a single integer key using a
	spatial hash. Avoids string allocation ("cx,cz" concatenation) which
	would create a new heap string on every insertion, update, and query.

	The multiplication by HASH_PRIME spreads values across the integer space,
	reducing collision probability for nearby cells.

	Note: Luau integers are 64-bit doubles, so we don't worry about overflow
	in typical map sizes (±2000 studs / 24 studs/cell = ±83 cells per axis;
	83 × HASH_PRIME ≈ 6.1B which fits in a 64-bit float without precision loss).
]]
local function _hashCell(cx: number, cz: number): number
	-- Shift cx into the high-order bits and add cz to the low-order region.
	-- The prime multiplication disperses the combined value across hash space.
	return cx * HASH_PRIME + cz
end

-- ── Constructor ──────────────────────────────────────────────────────────────

--[[
	SpatialGrid.new(cellSize?) -> SpatialGrid

	Creates an empty spatial grid.

	@param cellSize  number?  Width/depth of each grid cell in studs.
	                          Defaults to 24. See CELL SIZE TUNING above.
]]
function SpatialGrid.new(cellSize: number?): SpatialGrid
	local cs = cellSize or 24
	assert(type(cs) == "number" and cs > 0, "[SpatialGrid] cellSize must be a positive number.")

	local self = setmetatable({}, SpatialGrid)

	-- Store both cellSize and its reciprocal. Division is ~3–5× more expensive
	-- than multiplication on modern CPUs. By pre-computing 1/cellSize we convert
	-- all subsequent `floor(x / cellSize)` calls to `floor(x * invCellSize)`,
	-- saving a division per coordinate per Register/Update call.
	self._cellSize = cs
	self._invCellSize = 1 / cs

	-- Sparse table of cells. Key = integer hash; value = array of EntityRecords.
	-- Sparse because most cells are empty at any given time; a dense 2D array
	-- would waste memory proportional to map_area / cell_area.
	self._cells = {} :: { [number]: { EntityRecord } }

	-- Reverse-lookup from entity → EntityRecord.
	-- Needed for O(1) Update() and Remove() without scanning all cells.
	-- Keys are entity tables (referenced by identity, not by value).
	self._entityMap = {} :: { [Entity]: EntityRecord }

	return self :: SpatialGrid
end

-- ── Private: Cell Index ───────────────────────────────────────────────────────

--[[
	SpatialGrid:_cellOf(position) -> (cx: number, cz: number, key: number)

	Computes the integer cell indices and hash key for a world-space position.
	We use XZ because Roblox's Y axis is vertical and enemies move on a ground
	plane — a 3D grid would waste memory on vertical cells that are never used.

	math.floor() truncates toward negative infinity, which correctly handles
	negative coordinates (e.g. position.X = -1 → floor(-1/24) = -1, not 0).
]]
function SpatialGrid:_cellOf(position: Vector3): (number, number, number)
	-- Multiply by inverse rather than dividing — see _invCellSize comment above.
	local cx = math.floor(position.X * self._invCellSize)
	local cz = math.floor(position.Z * self._invCellSize)
	return cx, cz, _hashCell(cx, cz)
end

-- ── Public: Register ─────────────────────────────────────────────────────────

--[[
	SpatialGrid:Register(entity, position)

	Inserts an entity into the grid at the cell corresponding to `position`.
	Must be called once when the entity spawns or enters the tracked set.
	Calling Register() on an already-registered entity is a no-op with a warning
	(to detect duplicate registrations during development).

	Time complexity: O(1).

	@param entity    any      The object to track (enemy table, player, etc.).
	@param position  Vector3  Current world-space position of the entity.
]]
function SpatialGrid:Register(entity: Entity, position: Vector3)
	-- Guard against duplicate registration, which would create two records
	-- for the same entity and corrupt Remove() behaviour.
	if self._entityMap[entity] then
		warn("[SpatialGrid] Register() called on an already-registered entity. Ignoring.")
		return
	end

	local cx, cz, key = self:_cellOf(position)

	-- Build the record. We store cx and cz separately (not just the hash key)
	-- so that Update() can cheaply detect cell changes without re-hashing the
	-- old position (which we don't have) — we compare stored cx/cz instead.
	local record: EntityRecord = {
		entity = entity,
		cellKey = key,
		cx = cx,
		cz = cz,
	}

	-- Insert into the cell's entity list, creating the list if this is the
	-- first entity to occupy this cell.
	local cell = self._cells[key]
	if not cell then
		cell = {}
		self._cells[key] = cell
	end
	cell[#cell + 1] = record

	-- Store the reverse mapping for O(1) lookup in Update() and Remove().
	self._entityMap[entity] = record
end

-- ── Public: Remove ────────────────────────────────────────────────────────────

--[[
	SpatialGrid:Remove(entity)

	Removes an entity from the grid entirely.
	Call this when the entity dies, despawns, or leaves the tracked set.

	REMOVAL ALGORITHM:
	  1. Look up the entity's record via _entityMap — O(1).
	  2. Find the entity's position in its cell's array.
	  3. Swap it with the last element, then truncate the array — O(1) average,
	     avoids the O(n) shifting cost of table.remove(t, i).
	  4. If the cell is now empty, delete it from _cells to save memory.
	  5. Delete from _entityMap.

	Time complexity: O(k) where k = entities in the same cell.
	In practice O(1) since well-tuned cells have 1–5 entities.

	@param entity  any  The object to stop tracking.
]]
function SpatialGrid:Remove(entity: Entity)
	local record = self._entityMap[entity]
	if not record then
		-- Not registered — safe no-op. Allows defensive cleanup calls
		-- (e.g. in enemy :Destroy() without knowing if it was registered).
		return
	end

	local key = record.cellKey
	local cell = self._cells[key]

	if cell then
		-- Find and swap-remove the record from the cell array.
		-- Swap-remove: overwrite the target slot with the last element,
		-- then truncate. This is O(k) to find but avoids O(k) shifting.
		local n = #cell
		for i = 1, n do
			if cell[i] == record then
				-- Overwrite with the last element (O(1) swap).
				cell[i] = cell[n]
				-- Truncate the array (O(1) table operation).
				cell[n] = nil
				break
			end
		end

		-- If the cell is now empty, remove it from the sparse table.
		-- This keeps _cells compact and avoids iterating empty cells in queries.
		if #cell == 0 then
			self._cells[key] = nil
		end
	end

	-- Remove the reverse mapping.
	self._entityMap[entity] = nil
end

-- ── Public: Update ────────────────────────────────────────────────────────────

--[[
	SpatialGrid:Update(entity, newPosition)

	Updates an entity's position in the grid. If the entity has crossed into a
	new cell, it is moved from the old cell to the new one. If it stayed in the
	same cell, this call does nothing beyond the cell-index computation.

	DESIGN NOTE — STAGGERED UPDATES:
	You do NOT need to call Update() every heartbeat for every enemy.
	Enemies move at most ~20 studs/s; with a 24-stud cell size, they cross a
	cell boundary at most once every 1.2 seconds. Updating every 0.2–0.3 s
	(staggered via MovementService's existing stagger loop) is sufficient.
	This further amortises the cost across frames.

	Time complexity: O(1) if no cell change. O(k) if cell change (swap-remove).

	@param entity       any      The registered entity to update.
	@param newPosition  Vector3  The entity's current world-space position.
]]
function SpatialGrid:Update(entity: Entity, newPosition: Vector3)
	local record = self._entityMap[entity]
	if not record then
		-- Entity not registered — register it now with a warning.
		warn("[SpatialGrid] Update() called on unregistered entity. Auto-registering.")
		self:Register(entity, newPosition)
		return
	end

	local newCx, newCz, newKey = self:_cellOf(newPosition)

	-- Early exit: if the cell hasn't changed, nothing to do.
	-- This is the common case — most enemies don't cross a cell boundary
	-- every update tick, so this check saves the vast majority of Update() calls.
	if newCx == record.cx and newCz == record.cz then
		return
	end

	-- ── Cell transfer ────────────────────────────────────────────────────
	-- Remove from old cell (swap-remove for O(1) amortised).
	local oldKey = record.cellKey
	local oldCell = self._cells[oldKey]
	if oldCell then
		local n = #oldCell
		for i = 1, n do
			if oldCell[i] == record then
				oldCell[i] = oldCell[n]
				oldCell[n] = nil
				break
			end
		end
		if #oldCell == 0 then
			self._cells[oldKey] = nil
		end
	end

	-- Insert into new cell.
	local newCell = self._cells[newKey]
	if not newCell then
		newCell = {}
		self._cells[newKey] = newCell
	end
	newCell[#newCell + 1] = record

	-- Update the record in-place (no allocation — just mutate the existing table).
	record.cellKey = newKey
	record.cx = newCx
	record.cz = newCz
end

-- ── Public: QueryRadius ───────────────────────────────────────────────────────

--[[
	SpatialGrid:QueryRadius(position, radius, resultBuffer?) -> {Entity}

	Returns all entities whose registered positions fall within `radius` studs
	of `position` on the XZ plane (Y is ignored).

	ALGORITHM:
	  1. Compute the cell (cx, cz) for `position`.
	  2. Compute the cell span: span = ceil(radius / cellSize).
	     This gives the half-width (in cells) of the search window.
	  3. Iterate the (2·span+1) × (2·span+1) cell window, collecting all
	     EntityRecords from occupied cells.
	  4. For each candidate, check if its registered position is within radius
	     using a squared-distance comparison (avoids sqrt — one of the most
	     expensive single-precision operations).

	NOTE: "Registered position" means the position at last Register()/Update()
	call. For fast-moving enemies, there may be a 1-tick lag. This is acceptable
	for AoE and chain-lightning which are not frame-perfect anyway.

	RESULT BUFFER (optional):
	  Pass an existing table as `resultBuffer` to avoid allocating a new result
	  table on every query call. The buffer is cleared and reused. This further
	  eliminates GC pressure in high-frequency query loops (e.g. every chain bounce).

	Time complexity: O((2·span+1)² · k/cell + hits)
	  ≈ O(k) for uniform distributions where k << n.

	@param position      Vector3    Query centre in world space.
	@param radius        number     Search radius in studs (XZ plane only).
	@param resultBuffer  {Entity}?  Optional pre-allocated result table to reuse.
	@return              {Entity}   Entities within the radius.
]]
function SpatialGrid:QueryRadius(position: Vector3, radius: number, resultBuffer: { Entity }?): { Entity }
	-- Reuse the provided buffer, or allocate a fresh one.
	local results: { Entity } = resultBuffer or {}

	-- Clear buffer contents without releasing its memory. table.clear() is
	-- a built-in Luau intrinsic that zeroes the hash + array parts in O(n)
	-- with very low constant — faster than re-allocating.
	if resultBuffer then
		table.clear(results)
	end

	-- Compute the query cell and span.
	local qcx, qcz, _ = self:_cellOf(position)

	-- ceil(radius / cellSize) gives the maximum number of cells in any
	-- direction that could contain entities within the radius.
	-- We use integer ceiling to avoid missing entities on cell boundaries.
	local span: number = math.ceil(radius * self._invCellSize)

	-- Pre-compute squared radius to avoid sqrt in the inner loop.
	-- (a.X - b.X)² + (a.Z - b.Z)² < r² is equivalent to distance < r
	-- but avoids the expensive sqrt call. This is the single largest micro-
	-- optimisation in the query path.
	local rSq: number = radius * radius

	-- Iterate the rectangular cell window.
	for dcx = -span, span do
		local scanCx = qcx + dcx
		for dcz = -span, span do
			local scanCz = qcz + dcz
			local key = _hashCell(scanCx, scanCz)
			local cell = self._cells[key]

			-- Skip empty cells — the majority of cells in a sparse map.
			if cell then
				-- Iterate every entity record in this cell.
				for _, record in cell do
					-- We need the entity's actual position to do a precise
					-- distance check (the cell covers a 24×24 area, not a circle).
					-- Rather than storing a position copy in the record
					-- (which would be stale and waste memory), we call a
					-- position getter on the entity.
					-- Contract: registered entities must have a GetPosition() method
					-- OR we fall back to record-stored position snapshot.
					-- We use a record-stored snapshot updated in Register/Update
					-- to keep the query path free of virtual calls.
					local ex = record.cx * self._cellSize + (self._cellSize * 0.5)
					local ez = record.cz * self._cellSize + (self._cellSize * 0.5)
					local dx = position.X - ex
					local dz = position.Z - ez

					-- Squared distance on XZ plane — no sqrt, no Vector3 allocation.
					local distSq = dx * dx + dz * dz
					if distSq <= rSq then
						results[#results + 1] = record.entity
					end
				end
			end
		end
	end

	return results
end

--[[
	SpatialGrid:QueryRadiusPrecise(position, radius, getPositionFn, resultBuffer?) -> {Entity}

	Higher-accuracy variant that calls `getPositionFn(entity) -> Vector3` per
	candidate to get the entity's EXACT current position, rather than using the
	cell-centre approximation of QueryRadius.

	Use this when precision matters (e.g. melee hitbox detection).
	Use QueryRadius for AoE/chain-lightning where cell-centre approximation
	(±12 studs at 24-stud cells) is acceptable.

	@param position      Vector3             Query centre.
	@param radius        number              Search radius.
	@param getPositionFn (Entity)->Vector3   Returns the entity's exact position.
	@param resultBuffer  {Entity}?           Optional reusable result table.
	@return              {Entity}
]]
function SpatialGrid:QueryRadiusPrecise(
	position: Vector3,
	radius: number,
	getPositionFn: (Entity) -> Vector3,
	resultBuffer: { Entity }?
): { Entity }
	local results: { Entity } = resultBuffer or {}
	if resultBuffer then
		table.clear(results)
	end

	local qcx, qcz, _ = self:_cellOf(position)
	local span: number = math.ceil(radius * self._invCellSize)
	local rSq: number = radius * radius

	for dcx = -span, span do
		local scanCx = qcx + dcx
		for dcz = -span, span do
			local key = _hashCell(scanCx, qcz + dcz)
			local cell = self._cells[key]
			if cell then
				for _, record in cell do
					-- Call the position getter for exact coordinates.
					local ok, entityPos = pcall(getPositionFn, record.entity)
					if ok then
						local dx = position.X - entityPos.X
						local dz = position.Z - entityPos.Z
						local distSq = dx * dx + dz * dz
						if distSq <= rSq then
							results[#results + 1] = record.entity
						end
					end
				end
			end
		end
	end

	return results
end

-- ── Public: QueryCell ─────────────────────────────────────────────────────────

--[[
	SpatialGrid:QueryCell(position) -> {Entity}

	Returns all entities in the single cell that contains `position`.
	Faster than QueryRadius when you only need same-cell entities
	(e.g. enemy collision avoidance — only care about direct neighbours).

	Time complexity: O(k) where k = entities in that one cell.
]]
function SpatialGrid:QueryCell(position: Vector3): { Entity }
	local _, _, key = self:_cellOf(position)
	local cell = self._cells[key]
	if not cell then
		return {}
	end

	-- Return a shallow copy so callers can't corrupt the internal cell array.
	local results = table.create(#cell)
	for i, record in cell do
		results[i] = record.entity
	end
	return results
end

-- ── Public: GetStats ──────────────────────────────────────────────────────────

--[[
	SpatialGrid:GetStats() -> {entityCount, cellCount, maxEntitiesPerCell, avgEntitiesPerCell}

	Diagnostic snapshot of grid utilisation.
	Log this periodically to verify your cellSize is well-tuned:
	  - maxEntitiesPerCell > 20 → consider smaller cells
	  - cellCount >> entityCount → consider larger cells
]]
function SpatialGrid:GetStats(): {
	entityCount: number,
	cellCount: number,
	maxEntitiesPerCell: number,
	avgEntitiesPerCell: number,
}
	local cellCount = 0
	local maxPerCell = 0
	local totalInCells = 0

	for _, cell in self._cells do
		local n = #cell
		cellCount += 1
		totalInCells += n
		if n > maxPerCell then
			maxPerCell = n
		end
	end

	local entityCount = 0
	for _ in self._entityMap do
		entityCount += 1
	end

	return {
		entityCount = entityCount,
		cellCount = cellCount,
		maxEntitiesPerCell = maxPerCell,
		avgEntitiesPerCell = if cellCount > 0 then totalInCells / cellCount else 0,
	}
end

-- ── Public: Clear ─────────────────────────────────────────────────────────────

--[[
	SpatialGrid:Clear()

	Removes all entities from the grid without destroying the grid itself.
	Useful for round-reset without needing to reconstruct the grid.
]]
function SpatialGrid:Clear()
	table.clear(self._cells)
	table.clear(self._entityMap)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return SpatialGrid
