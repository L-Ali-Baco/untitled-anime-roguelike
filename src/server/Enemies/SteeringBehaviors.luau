--[[
	SteeringBehaviors.luau
	======================
	Stateless utility module for computing steering forces on enemies.
	All functions are pure — they read from their arguments and return a Vector2;
	they do NOT modify any global state.

	Currently provides:
	  CalculateSeparation(enemy, spatialGrid, cfg) -> Vector2
	    Returns a repulsion vector that pushes `enemy` away from nearby neighbours.
	    Uses SpatialGrid:QueryRadiusPrecise() for O(k) lookup instead of the
	    original O(n²) all-pairs scan. At 50 enemies with an average of 3
	    neighbours in range, this reduces comparisons from 2500 to ~150.

	  CalculateCohesion(enemy, spatialGrid, cfg) -> Vector2
	    Optional attraction toward the local group centre. Useful for pack enemies
	    (wolves, minions) that should cluster. Disabled until cfg.CohesionRadius is set.

	HOW SEPARATION WORKS (vector math):
	  For each neighbour B within `cfg.Radius` studs of enemy A:
	    1. Compute the horizontal difference vector: diff = A.pos - B.pos (XZ only).
	    2. Compute the distance: dist = diff.Magnitude.
	    3. Apply linear falloff:  strength = cfg.Strength × (1 - dist / Radius)
	       → Full push at dist=0, zero push at dist=Radius, smooth in-between.
	    4. Add normalised(diff) × strength to the running repulsion sum.
	  The final sum is returned as Vector2 and ADDED to PlaneVelocity by the caller.

	CALLER (MovementService):
	  local sep = SteeringBehaviors.CalculateSeparation(enemy, spatialGrid, cfg)
	  if sep.Magnitude > 0.01 then
	      enemy.LinearVelocity.PlaneVelocity += sep
	  end
]]

local SteeringBehaviors = {}

--[[
	CalculateSeparation(enemy, spatialGrid, cfg) -> Vector2

	Computes a repulsion (separation) steering force for `enemy`, pushing it away
	from other enemies that are within `cfg.Radius` studs.

	The returned Vector2 is in the XZ plane (X maps to world X, Y maps to world Z).
	It is designed to be ADDED to LinearVelocity.PlaneVelocity, not replace it,
	so it blends naturally with the flow-field movement intent.

	Only horizontal (XZ) distance is considered. Enemies on different floors
	(e.g. one on a platform, one below) do not push each other sideways.

	@param enemy        Any object with { RootPart: BasePart, _destroyed: boolean }.
	@param spatialGrid  A SpatialGrid instance (see src/shared/SpatialGrid.luau).
	                    Must be kept up-to-date by the caller before this is invoked.
	@param cfg          EnemyConfig.Separation: { Enabled: bool, Radius: number, Strength: number }
	@returns Vector2    Repulsion force. Returns Vector2.zero if separation is disabled,
	                    the enemy has no valid RootPart, or no neighbours are found.
]]
function SteeringBehaviors.CalculateSeparation(enemy: any, spatialGrid: any, cfg: any): Vector2
	if not cfg or not cfg.Enabled then
		return Vector2.zero
	end
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return Vector2.zero
	end

	local myPos = enemy.RootPart.Position
	local radius = cfg.Radius
	local strength = cfg.Strength

	-- ── Query the spatial grid for all enemies within `radius` studs ──────────
	-- QueryRadiusPrecise performs a per-entity distance check (not just cell-level)
	-- so results are guaranteed to be within the exact radius.
	-- We pass a getter function so SpatialGrid can compute distances without
	-- storing raw Vector3 positions inside the grid (which would need per-tick updates).
	local neighbours = spatialGrid:QueryRadiusPrecise(myPos, radius, function(e: any): Vector3
		return e.RootPart and e.RootPart.Parent and e.RootPart.Position or myPos
	end)

	if not neighbours or #neighbours == 0 then
		return Vector2.zero
	end

	-- ── Accumulate repulsion vectors ──────────────────────────────────────────
	local sepX = 0
	local sepZ = 0

	for _, other in neighbours do
		if other == enemy or other._destroyed then
			continue
		end
		if not other.RootPart or not other.RootPart.Parent then
			continue
		end

		local otherPos = other.RootPart.Position

		-- XZ-only difference: ignore vertical separation (enemies on different floors).
		local diffX = myPos.X - otherPos.X
		local diffZ = myPos.Z - otherPos.Z
		local dist = math.sqrt(diffX * diffX + diffZ * diffZ)

		if dist < radius and dist > 0.01 then
			-- Linear falloff: push is strongest at full overlap, zero at the radius edge.
			-- falloff ∈ (0, 1]  →  force = Strength × falloff × direction
			local falloff = 1 - dist / radius
			local invDist = 1 / dist -- Normalise without Vector3 constructor
			sepX += diffX * invDist * strength * falloff
			sepZ += diffZ * invDist * strength * falloff
		end
	end

	return Vector2.new(sepX, sepZ)
end

--[[
	CalculateCohesion(enemy, spatialGrid, cfg) -> Vector2

	Computes an attraction (cohesion) steering force that pulls `enemy` toward
	the average position of nearby allies. Useful for pack-style enemies that
	should cluster together (wolves, minion swarms).

	HOW COHESION WORKS:
	  1. Find all allies within cfg.CohesionRadius.
	  2. Compute their average XZ position (the "group centre").
	  3. Return a vector pointing from the enemy toward the group centre,
	     scaled by cfg.CohesionStrength.

	Currently unused — activate by setting EnemyConfig.Separation.CohesionRadius
	and CohesionStrength for a specific enemy type and calling this from
	MovementService alongside CalculateSeparation.

	@param enemy        Any object with { RootPart: BasePart, _destroyed: boolean }.
	@param spatialGrid  A SpatialGrid instance.
	@param cfg          Config table: { CohesionRadius: number, CohesionStrength: number }
	@returns Vector2    Cohesion force. Returns Vector2.zero if no cfg or no neighbours.
]]
function SteeringBehaviors.CalculateCohesion(enemy: any, spatialGrid: any, cfg: any): Vector2
	if not cfg or not cfg.CohesionRadius then
		return Vector2.zero
	end
	if not enemy.RootPart or not enemy.RootPart.Parent then
		return Vector2.zero
	end

	local myPos = enemy.RootPart.Position

	local neighbours = spatialGrid:QueryRadiusPrecise(myPos, cfg.CohesionRadius, function(e: any): Vector3
		return e.RootPart and e.RootPart.Parent and e.RootPart.Position or myPos
	end)

	if not neighbours or #neighbours <= 1 then
		return Vector2.zero
	end

	-- Compute the average position of all valid neighbours (excluding self).
	local sumX, sumZ = 0, 0
	local count = 0
	for _, other in neighbours do
		if other == enemy or other._destroyed then
			continue
		end
		if not other.RootPart or not other.RootPart.Parent then
			continue
		end
		local p = other.RootPart.Position
		sumX += p.X
		sumZ += p.Z
		count += 1
	end

	if count == 0 then
		return Vector2.zero
	end

	-- Direction from self toward the group centre.
	local toCentreX = sumX / count - myPos.X
	local toCentreZ = sumZ / count - myPos.Z
	local dist = math.sqrt(toCentreX * toCentreX + toCentreZ * toCentreZ)
	if dist < 0.1 then
		return Vector2.zero
	end

	local cohesionStrength = cfg.CohesionStrength or 0.5
	return Vector2.new(toCentreX / dist * cohesionStrength, toCentreZ / dist * cohesionStrength)
end

return SteeringBehaviors
