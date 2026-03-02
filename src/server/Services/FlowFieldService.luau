--[[
	FlowFieldService.luau
	=====================
	Generates a per-player flow field (vector field) over a 2D grid so that
	enemies can navigate around obstacles in O(1) per-Tick rather than calling
	Humanoid:MoveTo() or doing expensive raycasts at query time.

	HOW IT WORKS (overview):
	  1. GRID — The map is divided into a uniform grid of square cells
	     (default: 4-stud cells over a 256×256 stud area → 64×64 = 4096 cells).
	     Each cell is either Walkable or Obstacle.

	  2. OBSTACLE BAKING — At server start, we raycast downward from each cell's
	     world-centre. Cells with no floor (pits, voids) or no head-clearance
	     (walls, ceilings) are permanently marked as obstacles. This runs once
	     per server session — dynamic obstacles are NOT supported.

	  3. BFS COST MAP — For each active player, we run a Breadth-First Search
	     (BFS) starting from the cell directly beneath that player. BFS floods
	     outward, assigning each reachable cell its step-distance to the target.
	     This produces a "cost map" — a 2D array where costMap[col][row] = N
	     means "N steps from here to the player". Obstacle cells stay at -1.

	     WHY BFS, not Dijkstra?
	     All edges have weight 1 (each step costs the same), so BFS is identical
	     to Dijkstra on a uniform grid but runs in O(cells) with zero heap overhead.

	  4. VECTOR FIELD / GetDirection — To move toward the target, an enemy calls
	     GetDirection(worldPos, player). This:
	       a) Converts worldPos → (col, row).
	       b) Looks at the 4 cardinal neighbours (N, S, E, W).
	       c) Returns a unit Vector3 pointing toward the neighbour with the LOWEST
	          cost — i.e., the direction that decreases distance to the target.
	     This is O(1): four table lookups and a subtraction.

	  5. LAZY REBUILDS — The BFS is re-run whenever the target player moves more
	     than REGEN_THRESHOLD studs since the last BFS. The check is made inside
	     BaseEnemy:MoveTowardTarget() via the shouldRebuildFlow/rebuildFlow
	     callbacks injected by EnemyService into the services bag.

	     SELF-DEDUPLICATION: If 20 enemies all ask "should I rebuild?" in the
	     same AI Heartbeat batch, the FIRST one to call rebuildFlow() updates
	     lastTargetPos. All subsequent enemies see ShouldRebuild() = false and
	     skip it. One BFS per player per target-cell-change, regardless of enemy count.

	INTEGRATION:
	  EnemyService injects three callbacks into the services bag:
	    - getFlowDirection(pos, player) → Vector3
	    - shouldRebuildFlow(player, targetPos) → boolean
	    - rebuildFlow(player, targetPos)
	  BaseEnemy:MoveTowardTarget() calls these instead of computing a direct vector.
	  FlowFieldService is a standard service (Init/Start) auto-discovered by init.server.luau.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local FlowFieldService = {
	Name = "FlowFieldService",
}

-- ── Grid Configuration ──────────────────────────────────────────────────────
-- Tune these constants to match your map layout.

-- Side length (in studs) of each square cell.
-- 4 studs ≈ 1 enemy body-width (finer paths, larger RAM).
-- 8 studs ≈ 2 body-widths (slightly coarser paths, 4× less RAM and BFS work).
-- We use 8 to trade a small path-fidelity loss for a 4× reduction in costMap
-- size (1024 cells vs 4096), halving peak RAM consumption.
local CELL_SIZE = 8

-- Map bounds: the grid covers [ORIGIN_X .. ORIGIN_X + WIDTH] × [ORIGIN_Z .. ORIGIN_Z + DEPTH].
-- Default covers ±128 studs from the origin — adjust to your world size.
local ORIGIN_X = -128
local ORIGIN_Z = -128
local WIDTH_STUDS = 256
local DEPTH_STUDS = 256

-- Number of cells along each axis (derived)
local GRID_COLS = math.floor(WIDTH_STUDS / CELL_SIZE) -- X axis (left ↔ right)
local GRID_ROWS = math.floor(DEPTH_STUDS / CELL_SIZE) -- Z axis (front ↔ back)
local TOTAL_CELLS = GRID_COLS * GRID_ROWS

-- How far the target player must move (studs) before we re-run BFS.
-- 1 cell = the minimum meaningful change at the current resolution.
-- Increase to reduce BFS frequency at the cost of slightly stale paths.
local REGEN_THRESHOLD = CELL_SIZE

-- How many seconds a per-player flow field can sit without a RebuildForPlayer
-- call before we consider it stale and drop it to free RAM.
-- A flow field that hasn't been rebuilt in 10 s means no enemy has been
-- chasing that player, so the data is safe to discard.
local STALE_TIMEOUT = 10

-- How often (seconds) the stale-cleanup sweep runs.
local STALE_SWEEP_INTERVAL = 30

-- ── Obstacle Baking Parameters ──────────────────────────────────────────────

-- Height (Y) from which the downward floor-check raycast is fired.
local BAKE_RAYCAST_Y = 200

-- Length of the downward floor-check ray.
local BAKE_RAYCAST_DOWN = 400

-- Minimum floor Y. Cells where the floor is below this height are treated
-- as pits/voids and marked as obstacles.
local FLOOR_Y_MIN = -50

-- Height of the head-clearance check above the detected floor.
-- Cells with a solid surface within this many studs of the floor are too
-- cramped for an enemy to walk through → marked as obstacle.
local HEAD_CLEARANCE = 6 -- studs

-- ── BFS Sentinel Values ──────────────────────────────────────────────────────

local COST_OBSTACLE = -1 -- Cell is permanently blocked
local COST_UNVISITED = math.maxinteger -- Cell is reachable but not yet visited

-- ── Private State ─────────────────────────────────────────────────────────────

-- obstacle[col][row] = true for permanently blocked cells.
-- Populated once by BakeObstacles() at server start and never modified again.
local obstacle: { [number]: { [number]: boolean } } = {}

-- Per-player flow data:
--   costMap[col][row]  = integer step-distance from the player's cell (0 = player's cell)
--   lastTargetPos      = the Vector3 used in the most recent BFS (for regen threshold check)
--   lastUpdateTime     = os.clock() at the last RebuildForPlayer call (for stale culling)
--
-- Weak keys (__mode = "k"): if a Player instance is GC'd (e.g. PlayerRemoving fires but
-- the nil-set races with something), the entry is automatically collected. This is a
-- belt-and-suspenders safety net on top of the PlayerRemoving cleanup in Start().
local flowFields: { [Player]: { costMap: { [number]: { [number]: number } }, lastTargetPos: Vector3?, lastUpdateTime: number } } =
	setmetatable({}, { __mode = "k" }) :: any

-- Pre-allocated BFS queue (col, row pairs packed flat).
-- Reused every BFS to avoid allocating a new table each time.
-- Size = TOTAL_CELLS × 2 to hold all possible (col, row) entries.
local bfsQueue: { number } = table.create(TOTAL_CELLS * 2, 0)

-- ── Grid Utilities ────────────────────────────────────────────────────────────

--[[
	worldToCell(x, z) -> col?, row?
	Converts a world-space XZ position to 1-indexed grid coordinates.
	Returns nil, nil if the position is outside the grid bounds.
]]
local function worldToCell(x: number, z: number): (number?, number?)
	local col = math.floor((x - ORIGIN_X) / CELL_SIZE) + 1
	local row = math.floor((z - ORIGIN_Z) / CELL_SIZE) + 1
	if col < 1 or col > GRID_COLS or row < 1 or row > GRID_ROWS then
		return nil, nil
	end
	return col, row
end

--[[
	cellToWorld(col, row) -> Vector3
	Returns the world-space XZ centre of the given cell.
	Y is set to 0 — flow field directions are XZ-only.
]]
local function cellToWorld(col: number, row: number): Vector3
	return Vector3.new(
		ORIGIN_X + (col - 0.5) * CELL_SIZE, -- Centre of cell on X
		0,
		ORIGIN_Z + (row - 0.5) * CELL_SIZE -- Centre of cell on Z
	)
end

--[[
	isWalkable(col, row) -> boolean
	Returns true only if (col, row) is in bounds AND not marked as an obstacle.
]]
local function isWalkable(col: number, row: number): boolean
	if col < 1 or col > GRID_COLS or row < 1 or row > GRID_ROWS then
		return false
	end
	local obsRow = obstacle[col]
	return not (obsRow and obsRow[row])
end

-- ── Obstacle Baking ────────────────────────────────────────────────────────────

--[[
	FlowFieldService:BakeObstacles()

	Raycasts downward from every cell centre to build the permanent obstacle map.
	Call this ONCE at server start (done automatically in Start() via task.defer).

	Two checks per cell:
	  1. Floor check: if no surface is detected within BAKE_RAYCAST_DOWN studs,
	     or the floor is below FLOOR_Y_MIN, the cell is a pit/void → obstacle.
	  2. Head clearance: if a solid surface exists within HEAD_CLEARANCE studs
	     above the detected floor, the gap is too tight for an enemy → obstacle.

	A task.wait() is inserted every 32 rows so the bake doesn't block the main
	thread for the full duration on large grids. Players rarely join within the
	first second of a fresh server start, so this is safe.
]]
function FlowFieldService:BakeObstacles()
	-- Exclude enemy models from the raycasts so their bodies don't pollute the bake.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged("Enemy")

	local markedCount = 0

	for col = 1, GRID_COLS do
		-- Spread work across frames: yield every 32 columns to avoid frame spikes.
		-- 32 cols × 64 rows × 2 raycasts = 4096 raycasts before yielding.
		if col % 32 == 0 then
			task.wait()
		end

		obstacle[col] = obstacle[col] or {}

		for row = 1, GRID_ROWS do
			local worldPos = cellToWorld(col, row)
			local origin = Vector3.new(worldPos.X, BAKE_RAYCAST_Y, worldPos.Z)

			-- ── Check 1: Is there a floor? ───────────────────────────────────────
			local floorHit = workspace:Raycast(origin, Vector3.new(0, -BAKE_RAYCAST_DOWN, 0), rayParams)

			if not floorHit or floorHit.Position.Y < FLOOR_Y_MIN then
				-- No floor detected, or floor is too deep (pit / void)
				obstacle[col][row] = true
				markedCount += 1
				continue
			end

			-- ── Check 2: Is there enough head clearance above the floor? ─────────
			-- An enemy is roughly 5 studs tall. Cast HEAD_CLEARANCE studs upward from
			-- just above the floor surface to detect low ceilings or narrow gaps.
			local floorY = floorHit.Position.Y
			local headOrigin = Vector3.new(worldPos.X, floorY + 0.3, worldPos.Z)
			local headHit = workspace:Raycast(headOrigin, Vector3.new(0, HEAD_CLEARANCE, 0), rayParams)

			if headHit then
				-- Solid surface within HEAD_CLEARANCE studs of the floor → too cramped
				obstacle[col][row] = true
				markedCount += 1
			end
		end
	end

	print(
		("[FlowFieldService] Bake complete — %d/%d cells marked as obstacles (%.1f%%)"):format(
			markedCount,
			TOTAL_CELLS,
			markedCount / TOTAL_CELLS * 100
		)
	)
end

-- ── BFS — Core Pathfinding Algorithm ──────────────────────────────────────────

--[[
	_runBFS(targetCol, targetRow, costMap)

	Fills `costMap` with the minimum step-count distance from every walkable
	cell to (targetCol, targetRow), using Breadth-First Search.

	WHY BFS works here:
	  The grid is uniform — every edge (step from one cell to its neighbour) has
	  the same cost (1). On a uniform graph, BFS visits cells in non-decreasing
	  distance order, so the first time a cell is reached, it has the shortest
	  possible cost. This is identical to Dijkstra on a uniform-weight graph,
	  but BFS uses a simple FIFO queue instead of a priority heap → faster.

	COMPLEXITY: O(C) where C = GRID_COLS × GRID_ROWS.
	For a 64×64 grid: C = 4096 cells, ~0.2–0.5ms on a Roblox server thread.

	THE INTEGRATION MAP:
	  costMap[col][row] stores the "integration value" — how many steps it takes
	  to walk from that cell to the target. The gradient of this map gives us the
	  flow direction: to get closer to the target, move toward the neighbour with
	  the smallest integration value (GetDirection does this in O(1)).

	@param targetCol  1-indexed column of the BFS root (player's cell).
	@param targetRow  1-indexed row of the BFS root (player's cell).
	@param costMap    2D table costMap[col][row]; will be reset and filled.
]]
local function _runBFS(targetCol: number, targetRow: number, costMap: { [number]: { [number]: number } })
	-- ── Step 1: Reset the cost map ────────────────────────────────────────────
	-- All walkable cells → COST_UNVISITED; obstacle cells → COST_OBSTACLE.
	for col = 1, GRID_COLS do
		costMap[col] = costMap[col] or {}
		local obsCol = obstacle[col]
		for row = 1, GRID_ROWS do
			if obsCol and obsCol[row] then
				costMap[col][row] = COST_OBSTACLE
			else
				costMap[col][row] = COST_UNVISITED
			end
		end
	end

	-- ── Step 2: Seed BFS from the target cell ─────────────────────────────────
	-- The target cell has cost 0 — it IS the goal; zero steps needed.
	costMap[targetCol][targetRow] = 0

	-- ── Step 3: BFS queue using pre-allocated flat array ─────────────────────
	-- Encoding: queue[i] = col, queue[i+1] = row. head/tail are indices into this array.
	-- head advances when we dequeue; tail advances when we enqueue.
	-- This avoids table.remove (O(n)) and is allocation-free (reuses bfsQueue).
	local head = 1
	local tail = 3 -- Points to the slot after the last enqueued entry (starts at 3 because we enqueue index 1&2 below)
	bfsQueue[1] = targetCol
	bfsQueue[2] = targetRow

	-- Cardinal direction offsets: {Δcol, Δrow} for N, S, E, W
	-- N = row - 1, S = row + 1, E = col + 1, W = col - 1
	local dC = { 0, 0, 1, -1 }
	local dR = { -1, 1, 0, 0 }

	-- ── Step 4: Flood-fill outward from the target cell ───────────────────────
	while head < tail do
		local col = bfsQueue[head]
		local row = bfsQueue[head + 1]
		head += 2

		local nextCost = costMap[col][row] + 1

		for i = 1, 4 do
			local nc = col + dC[i]
			local nr = row + dR[i]
			-- Enqueue only if in-bounds, not an obstacle, and not yet visited.
			-- isWalkable handles both bounds and obstacle checks in one call.
			if isWalkable(nc, nr) and costMap[nc][nr] == COST_UNVISITED then
				costMap[nc][nr] = nextCost
				bfsQueue[tail] = nc
				bfsQueue[tail + 1] = nr
				tail += 2
			end
		end
	end
end

-- ── Public: RebuildForPlayer ──────────────────────────────────────────────────

--[[
	FlowFieldService:RebuildForPlayer(player, targetPos)

	Runs BFS to regenerate the flow field for this player, targeting the cell
	beneath `targetPos`. Updates lastTargetPos so subsequent ShouldRebuild
	calls return false until the player moves another REGEN_THRESHOLD studs.

	This function is O(C) — C cells in the grid. On a 64×64 grid it runs in
	~0.3ms. The self-deduplication in ShouldRebuild means it's called at most
	once per REGEN_THRESHOLD stud of player movement, not per enemy per tick.

	@param player     The player this flow field targets.
	@param targetPos  Current world position of the player.
]]
function FlowFieldService:RebuildForPlayer(player: Player, targetPos: Vector3)
	local col, row = worldToCell(targetPos.X, targetPos.Z)
	if not col or not row then
		return -- Player is outside the grid — no flow field possible
	end

	local data = flowFields[player]
	if not data then
		-- Lazily allocate the cost map on the first rebuild for this player.
		-- Pre-allocate all columns to avoid repeated table creation during BFS.
		local costMap: { [number]: { [number]: number } } = {}
		for c = 1, GRID_COLS do
			costMap[c] = {}
		end
		data = { costMap = costMap, lastTargetPos = nil, lastUpdateTime = os.clock() }
		flowFields[player] = data
	end

	_runBFS(col, row, data.costMap)
	data.lastTargetPos = targetPos
	data.lastUpdateTime = os.clock()
end

-- ── Public: ShouldRebuild ─────────────────────────────────────────────────────

--[[
	FlowFieldService:ShouldRebuild(player, currentTargetPos) -> boolean

	Returns true if:
	  - No flow field exists yet for this player, OR
	  - The player has moved more than REGEN_THRESHOLD studs since the last BFS.

	Calls to this function are O(1) — one table lookup and a squared-distance check.
	The squared-distance check avoids math.sqrt:
	  dist² > threshold²  ⟺  dist > threshold
]]
function FlowFieldService:ShouldRebuild(player: Player, currentTargetPos: Vector3): boolean
	local data = flowFields[player]
	if not data or not data.lastTargetPos then
		return true
	end
	-- Squared distance in XZ only (Y movement doesn't change which cell the player is in).
	local dx = currentTargetPos.X - data.lastTargetPos.X
	local dz = currentTargetPos.Z - data.lastTargetPos.Z
	return (dx * dx + dz * dz) > (REGEN_THRESHOLD * REGEN_THRESHOLD)
end

-- ── Public: GetDirection ──────────────────────────────────────────────────────

--[[
	FlowFieldService:GetDirection(worldPos, player) -> Vector3

	Returns a unit Vector3 (XZ plane, Y = 0) pointing from `worldPos` toward
	the cheapest passable cardinal neighbour in the flow field — O(1) per call.

	HOW THE DIRECTION IS COMPUTED:
	  Let the enemy's cell be E with cost costMap[E] = C.
	  We check all 4 neighbours: N, S, E, W.
	  The neighbour with the smallest cost is "closer to the target" — the flow
	  field gradient points from high-cost to low-cost (downhill toward the target).
	  We return the unit vector from E's world centre to the best neighbour's
	  world centre. Since cells are axis-aligned squares, this is always one of:
	  (1,0,0), (-1,0,0), (0,0,1), (0,0,-1).

	FALLBACK: Returns Vector3.zero if:
	  - No flow field exists for this player yet.
	  - worldPos is outside the grid.
	  - The enemy's cell is on an obstacle or unvisited (disconnected island).
	  - The enemy is already AT the target cell (cost 0).
	  The caller (BaseEnemy:MoveTowardTarget) falls back to direct-target direction.

	@param worldPos  Enemy's current world position.
	@param player    The player this enemy is chasing.
	@returns Vector3 Unit direction toward the target, or Vector3.zero on failure.
]]
function FlowFieldService:GetDirection(worldPos: Vector3, player: Player): Vector3
	local data = flowFields[player]
	if not data then
		return Vector3.zero
	end

	local col, row = worldToCell(worldPos.X, worldPos.Z)
	if not col or not row then
		return Vector3.zero
	end

	local costMap = data.costMap
	local myCost = costMap[col][row]

	-- Can't navigate from an obstacle cell or a cell that BFS couldn't reach.
	if myCost == COST_OBSTACLE or myCost == COST_UNVISITED then
		return Vector3.zero
	end

	-- Already standing on the target cell — no direction needed.
	if myCost == 0 then
		return Vector3.zero
	end

	-- ── Find the cardinal neighbour with the lowest integration cost ──────────
	-- We start with bestCost = myCost so we only move if a neighbour is BETTER.
	-- If all neighbours are worse or equal, we return zero (shouldn't happen in
	-- a well-connected BFS, but guards against map-edge corner cases).
	local bestCost = myCost
	local bestCol = col
	local bestRow = row

	-- North (row - 1)
	if isWalkable(col, row - 1) then
		local c = costMap[col][row - 1]
		if c ~= COST_OBSTACLE and c ~= COST_UNVISITED and c < bestCost then
			bestCost = c
			bestCol = col
			bestRow = row - 1
		end
	end
	-- South (row + 1)
	if isWalkable(col, row + 1) then
		local c = costMap[col][row + 1]
		if c ~= COST_OBSTACLE and c ~= COST_UNVISITED and c < bestCost then
			bestCost = c
			bestCol = col
			bestRow = row + 1
		end
	end
	-- East (col + 1)
	if isWalkable(col + 1, row) then
		local c = costMap[col + 1][row]
		if c ~= COST_OBSTACLE and c ~= COST_UNVISITED and c < bestCost then
			bestCost = c
			bestCol = col + 1
			bestRow = row
		end
	end
	-- West (col - 1)
	if isWalkable(col - 1, row) then
		local c = costMap[col - 1][row]
		if c ~= COST_OBSTACLE and c ~= COST_UNVISITED and c < bestCost then
			bestCost = c
			bestCol = col - 1
			bestRow = row
		end
	end

	-- No cheaper neighbour found — return zero so the caller uses direct targeting.
	if bestCol == col and bestRow == row then
		return Vector3.zero
	end

	-- Direction from this cell's centre to the best neighbour's centre.
	-- Since cells are axis-aligned, this always normalises to a cardinal unit vector.
	local from = cellToWorld(col, row)
	local to = cellToWorld(bestCol, bestRow)
	local dir = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return dir.Unit
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────────

function FlowFieldService:Init()
	print(
		("[FlowFieldService] Initialized — grid: %dx%d (%d cells, %d-stud cells)"):format(
			GRID_COLS,
			GRID_ROWS,
			TOTAL_CELLS,
			CELL_SIZE
		)
	)
end

function FlowFieldService:Start()
	-- Bake obstacle map after all services have started (world fully loaded).
	-- task.defer defers until after the current frame so all other services
	-- have completed their Start() routines and placed their geometry.
	task.defer(function()
		self:BakeObstacles()
	end)

	-- Clean up per-player flow field data when players leave to free memory.
	Players.PlayerRemoving:Connect(function(player)
		flowFields[player] = nil
	end)

	-- Stale-flow sweep: runs every STALE_SWEEP_INTERVAL seconds.
	-- If a player's flow field hasn't been rebuilt in STALE_TIMEOUT seconds,
	-- there are no enemies actively chasing them — drop the costMap to free RAM.
	-- The next RebuildForPlayer call will lazily re-allocate it.
	task.spawn(function()
		while true do
			task.wait(STALE_SWEEP_INTERVAL)
			local now = os.clock()
			for player, data in flowFields do
				if (now - data.lastUpdateTime) > STALE_TIMEOUT then
					-- Nil the entry; RebuildForPlayer re-creates it on next demand.
					flowFields[player] = nil
				end
			end
		end
	end)

	print("[FlowFieldService] Started — obstacle bake scheduled")
end

return FlowFieldService
