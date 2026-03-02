--[[
	EconomyService.luau
	Server-side economy manager: tracks PlayerGold, spawns physical GoldOrbs on enemy death,
	and runs a Heartbeat magnet loop that pulls orbs toward nearby players.

	Gold is stored as a Player Instance attribute ("Gold") so it:
	  1. Persists through character respawns (Player Instance lives longer than Character).
	  2. Auto-replicates to that player's client — no polling needed on the HUD side.
	  3. Is readable server-side at O(1) via :GetAttribute().

	GoldOrb lifecycle:
	  1. Enemy dies → _spawnOrbs() fetches ORB_COUNT parts from orbPool.
	  2. Each orb is given a random upward + radial fountain velocity.
	  3. Heartbeat loop: after ORB_MAGNET_DELAY seconds the orb enters "magnet mode" and
	     is steered toward the nearest living player.
	  4. When the orb reaches ORB_COLLECT_RADIUS of the player → AddGold + ReturnPart.
	  5. If uncollected after ORB_LIFETIME seconds → ReturnPart (no gold granted).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ObjectPool = require(Shared:WaitForChild("ObjectPool"))

-- ============================================================
-- TUNING CONSTANTS
-- ============================================================

-- Gold value dropped per enemy type on death.
-- Design intent: rarer enemies (lower SpawnWeight) drop more gold.
-- SpawnWeight reference from EnemyConfig:
--   Minion(60) Shooter/MossFrog(15) Brute(7) Keg(3)
local GOLD_DROP_TABLE: { [string]: number } = {
	Minion = 2,
	Shooter = 8,
	MossFrog = 8,
	Brute = 15,
	Keg = 5, -- Suicide runner: moderate reward relative to the danger imposed
	Drone = 10, -- Placeholder for future aerial enemy
	Shaman = 20, -- High-value assassination target; should feel rewarding to kill
}
local GOLD_DROP_DEFAULT = 3 -- Fallback for enemy types not in the table

-- Number of individual orbs spawned per enemy kill.
-- Splitting into N orbs is more satisfying than a single large pickup
-- (coin shower feel vs a single glowing blob).
-- Each orb carries math.floor(totalGold / ORB_COUNT) gold, minimum 1.
local ORB_COUNT = 3

-- ── Fountain physics ────────────────────────────────────────────────────────
-- On spawn each orb receives a velocity that is the SUM of:
--   upward  = Vector3.new(0, upSpeed,   0)             -- straight up
--   radial  = Vector3.new(cos θ, 0, sin θ) * radialSpd  -- random horizontal direction
-- The random angle θ ∈ [0, 2π] ensures orbs scatter in all directions,
-- not just one side. The upward bias makes the arc clearly readable mid-air.
local ORB_UPWARD_MIN = 20 -- studs/sec minimum upward launch speed
local ORB_UPWARD_MAX = 35 -- studs/sec maximum upward launch speed
local ORB_RADIAL_MIN = 5 -- studs/sec minimum outward scatter speed
local ORB_RADIAL_MAX = 15 -- studs/sec maximum outward scatter speed

-- ── Magnet parameters ───────────────────────────────────────────────────────
-- After ORB_MAGNET_DELAY seconds the orb switches from pure physics to magnet mode.
-- This lets the fountain arc complete naturally before homing behaviour kicks in.
local ORB_MAGNET_DELAY = 0.5 -- seconds; let orbs land before homing starts

-- The magnet activates when the nearest player is within this radius.
-- Outside this range the orb bounces on the ground untouched by the magnet,
-- preserving the "scattered coins" feel from a distance.
local ORB_MAGNET_RADIUS = 20.0 -- studs

-- Pull speed applied once the magnet activates.
-- At 20 studs away and 35 studs/sec pull → orb reaches the player in ~0.57 s.
-- Using direct velocity assignment (not additive) keeps the speed capped and
-- prevents the orb from accelerating uncontrollably in a long approach.
local ORB_PULL_SPEED = 35.0 -- studs/sec

-- Distance at which the orb is considered "collected" and gold is granted.
-- Slightly larger than the orb's visual radius (0.3 studs) to feel generous.
local ORB_COLLECT_RADIUS = 3.0 -- studs

-- Maximum lifespan of an active orb. Prevents littering maps with uncollected coins
-- during chaotic fights where players keep moving away from kills.
local ORB_LIFETIME = 15.0 -- seconds

-- ── ObjectPool config ───────────────────────────────────────────────────────
local ORB_POOL_INITIAL = 30 -- Pre-warm N orbs at startup (handles ~10 simultaneous deaths)
local ORB_POOL_EXPAND = 10 -- Expand by this many when the pool runs dry

-- ============================================================
-- ORB TEMPLATE FACTORY
-- ============================================================

-- Returns a fresh BasePart that ObjectPool will clone ORB_POOL_INITIAL times.
-- The template is Anchored=true and Transparency=1 — ObjectPool's dormant state.
-- ObjectPool.ReturnPart() resets all these properties on collection, so they're
-- always correct when GetPart() hands the part out.
local function makeOrbTemplate(): BasePart
	local part = Instance.new("Part")
	part.Name = "GoldOrb"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.6, 0.6, 0.6) -- Small coin-sized sphere
	part.Color = Color3.fromRGB(255, 200, 0) -- Classic gold yellow
	part.Material = Enum.Material.Neon -- Self-lit: readable against any background
	part.CastShadow = false -- No shadow for cheap sub-1-stud parts
	part.CanCollide = false -- Pass through terrain; only proximity matters for collection
	part.Anchored = true -- Must match ObjectPool's dormant state expectation
	part.Transparency = 1 -- Hidden while pooled (ObjectPool's dormant requirement)

	-- A small PointLight makes the orb visible in dark areas without adding geometry.
	-- The light is 10 000 studs underground when pooled, so it never bleeds into the scene.
	local light = Instance.new("PointLight")
	light.Brightness = 1.5
	light.Color = Color3.fromRGB(255, 210, 0)
	light.Range = 8
	light.Parent = part

	return part
end

-- ============================================================
-- SERVICE
-- ============================================================

local EconomyService = {
	Name = "EconomyService",
}

-- Populated in Start() after workspace is accessible
local orbPool: any = nil

-- Active orb table — iterated every Heartbeat.
-- Entry shape: { Part: BasePart, GoldValue: number, SpawnTime: number }
-- Swap-removal (backwards iteration) keeps iteration O(n) with no array shifts.
local activeOrbs: { { Part: BasePart, GoldValue: number, SpawnTime: number } } = {}

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

-- Returns the nearest alive Player and the SQUARED distance from `position`.
-- Using squared distance avoids a sqrt per player per frame (O(p) sqrt operations
-- become O(1) sqrt only at the single final comparison site).
-- Returns (nil, math.huge) when no players are available.
local function nearestPlayer(position: Vector3): (Player?, number)
	local bestPlayer: Player? = nil
	local bestDistSq = math.huge
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then
			continue
		end
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end
		-- Magnitude^2 avoids the square root — we only need relative comparison.
		local distSq = (root.Position - position).Magnitude ^ 2
		if distSq < bestDistSq then
			bestDistSq = distSq
			bestPlayer = player
		end
	end
	return bestPlayer, bestDistSq
end

-- ============================================================
-- PUBLIC GOLD API
-- ============================================================

--[[
	Returns the current gold balance for `player` (0 if not set yet).
	Gold lives on the Player Instance (not Character) so it survives respawns.
]]
function EconomyService:GetGold(player: Player): number
	return (player:GetAttribute("Gold") :: number?) or 0
end

--[[
	Add `amount` gold to `player` and fire GoldChanged to update the HUD.
	Silent no-op for zero or negative amounts.
]]
function EconomyService:AddGold(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	local current = (player:GetAttribute("Gold") :: number?) or 0
	local newTotal = current + amount
	player:SetAttribute("Gold", newTotal)
	-- Notify the owning client so the HUD can animate the counter.
	local remote = Remotes:GetEvent("GoldChanged")
	if remote then
		remote:FireClient(player, newTotal)
	end
end

--[[
	Attempt to spend `amount` gold from `player`.
	Returns true and deducts the gold if the player can afford it.
	Returns false and leaves gold unchanged if funds are insufficient.
	Fires GoldChanged on success so the HUD updates immediately.
]]
function EconomyService:SpendGold(player: Player, amount: number): boolean
	if amount <= 0 then
		return true
	end
	local current = (player:GetAttribute("Gold") :: number?) or 0
	if current < amount then
		return false
	end
	local newTotal = current - amount
	player:SetAttribute("Gold", newTotal)
	local remote = Remotes:GetEvent("GoldChanged")
	if remote then
		remote:FireClient(player, newTotal)
	end
	return true
end

-- ============================================================
-- GOLD ORB SPAWN
-- ============================================================

--[[
	Spawns ORB_COUNT orbs at `deathPosition`, each carrying (totalGold / ORB_COUNT) gold.
	The orbs fountain outward with a random upward + radial velocity so they scatter
	naturally from the corpse before the magnet loop takes over.

	Fountain velocity math:
	  • upSpeed   ∈ [ORB_UPWARD_MIN, ORB_UPWARD_MAX]  — how high the orb pops
	  • radialSpd ∈ [ORB_RADIAL_MIN, ORB_RADIAL_MAX]  — how far it scatters sideways
	  • angle     ∈ [0, 2π]  — random azimuth; ensures uniform scatter in a full circle
	  • radialDir = Vector3(cos θ, 0, sin θ)            — unit vector on the XZ plane
	  • velocity  = (0, upSpeed, 0) + radialDir * radialSpd
	The upward and radial components are independent, so orbs form a crown/fountain shape.
]]
function EconomyService:_spawnOrbs(deathPosition: Vector3, totalGold: number)
	if not orbPool then
		return
	end
	-- Distribute gold evenly across orbs; each orb is worth at least 1 gold.
	local goldPerOrb = math.max(1, math.floor(totalGold / ORB_COUNT))

	for _ = 1, ORB_COUNT do
		local part = orbPool:GetPart()
		if not part then
			continue -- Pool fully exhausted; skip quietly rather than erroring
		end

		-- ── Position the orb ─────────────────────────────────────────────────
		-- ObjectPool returns parts with Anchored=true, so CFrame assignment works.
		-- We raise it 1 stud so the initial velocity doesn't clip through the ground.
		part.CFrame = CFrame.new(deathPosition + Vector3.new(0, 1, 0))
		part.Transparency = 0 -- Make visible

		-- ── Unanchor BEFORE applying velocity ────────────────────────────────
		-- AssemblyLinearVelocity is ignored on anchored parts — always unanchor first.
		part.Anchored = false

		-- ── Fountain velocity ─────────────────────────────────────────────────
		local upSpeed = ORB_UPWARD_MIN + math.random() * (ORB_UPWARD_MAX - ORB_UPWARD_MIN)
		local radialSpd = ORB_RADIAL_MIN + math.random() * (ORB_RADIAL_MAX - ORB_RADIAL_MIN)
		-- Random angle on the unit circle → even coverage in all horizontal directions.
		local angle = math.random() * math.pi * 2
		local radialDir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		part.AssemblyLinearVelocity = Vector3.new(0, upSpeed, 0) + (radialDir * radialSpd)

		-- Register in the active list so the Heartbeat loop can track this orb.
		table.insert(activeOrbs, {
			Part = part,
			GoldValue = goldPerOrb,
			SpawnTime = os.clock(),
		})
	end
end

--[[
	Called by EnemyService when an enemy dies.
	Payload shape: { Target: Model, ... }
	Looks up the enemy type via Model.Name and spawns the appropriate orb count.
]]
function EconomyService:OnEnemyDied(payload: { [string]: any })
	local model: Model? = payload.Target
	if not model then
		return
	end
	local goldAmount: number = GOLD_DROP_TABLE[model.Name] or GOLD_DROP_DEFAULT
	if goldAmount <= 0 then
		return
	end
	-- Use the model's bounding-box centre so orbs pop from the actual enemy body
	-- regardless of whether the model has a PrimaryPart or not.
	local cf: CFrame = model:GetBoundingBox()
	self:_spawnOrbs(cf.Position, goldAmount)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function EconomyService:Init()
	print("[EconomyService] Initializing...")
end

function EconomyService:Start()
	-- ── Build the GoldOrb ObjectPool ──────────────────────────────────────────
	-- The template must be parented to workspace before ObjectPool clones it;
	-- unparented BaseParts can't be cloned reliably in all Roblox executor contexts.
	-- We destroy the template immediately after so no extra stray part remains.
	local template = makeOrbTemplate()
	template.Parent = workspace
	orbPool = ObjectPool.new(template, ORB_POOL_INITIAL, ORB_POOL_EXPAND)
	template:Destroy() -- Pool has already cloned it N times; template is no longer needed.

	-- Clean up gold attribute on player leave (prevents stale data if the player rejoins
	-- in the same server session and the attribute was somehow reused).
	Players.PlayerRemoving:Connect(function(player: Player)
		player:SetAttribute("Gold", nil)
	end)

	-- ── Magnet + Collection Heartbeat ─────────────────────────────────────────
	-- Runs every frame. Iterates the activeOrbs list BACKWARDS so we can swap-remove
	-- entries safely without skipping elements or needing a copy of the list.
	--
	-- Per-orb decision tree each frame:
	--   1. Guard: part was externally destroyed (e.g. /clear in Studio) → remove entry.
	--   2. Lifetime expiry (SpawnTime + ORB_LIFETIME < now) → ReturnPart, remove entry.
	--   3. Pre-magnet window (SpawnTime + ORB_MAGNET_DELAY > now) → skip, let physics run.
	--   4. Find nearest living player. If none → skip.
	--   5. Compute distance (one sqrt after squared comparison).
	--   6. Collect check: dist ≤ ORB_COLLECT_RADIUS → AddGold, fire GoldPickup, ReturnPart, remove.
	--   7. Magnet check: dist ≤ ORB_MAGNET_RADIUS → override velocity with pull direction.
	--      direction = (playerPos - orbPos) / dist   (avoids second .Magnitude call)
	--      velocity  = direction * ORB_PULL_SPEED    (constant speed, no acceleration)
	--      Direct assignment (NOT +=): prevents speed accumulation over frames.
	RunService.Heartbeat:Connect(function(_dt: number)
		local now = os.clock()
		local i = #activeOrbs
		while i >= 1 do
			local entry = activeOrbs[i]
			local part = entry.Part

			-- ── Guard: externally destroyed ───────────────────────────────────
			if not part.Parent then
				activeOrbs[i] = activeOrbs[#activeOrbs]
				activeOrbs[#activeOrbs] = nil
				i -= 1
				continue
			end

			-- ── Lifetime expiry ────────────────────────────────────────────────
			if now - entry.SpawnTime > ORB_LIFETIME then
				orbPool:ReturnPart(part) -- Reanchors + parks at PARK_CFRAME
				activeOrbs[i] = activeOrbs[#activeOrbs]
				activeOrbs[#activeOrbs] = nil
				i -= 1
				continue
			end

			-- ── Pre-magnet delay ───────────────────────────────────────────────
			-- Do nothing for the first ORB_MAGNET_DELAY seconds; let physics handle it.
			if now - entry.SpawnTime < ORB_MAGNET_DELAY then
				i -= 1
				continue
			end

			-- ── Nearest player ─────────────────────────────────────────────────
			local orbPos = part.Position
			local player, distSq = nearestPlayer(orbPos)
			if not player then
				i -= 1
				continue
			end
			local playerChar = player.Character
			local playerRoot = playerChar and playerChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not playerRoot then
				i -= 1
				continue
			end

			-- One sqrt for both the collect and magnet comparisons.
			-- We already have distSq from nearestPlayer(), so this is the only sqrt per orb.
			local dist = math.sqrt(distSq)

			-- ── Collection check ───────────────────────────────────────────────
			if dist <= ORB_COLLECT_RADIUS then
				self:AddGold(player, entry.GoldValue)
				local pickupRemote = Remotes:GetEvent("GoldPickup")
				if pickupRemote then
					pickupRemote:FireClient(player, entry.GoldValue) -- Client plays pickup sound/VFX
				end
				orbPool:ReturnPart(part)
				activeOrbs[i] = activeOrbs[#activeOrbs]
				activeOrbs[#activeOrbs] = nil
				i -= 1
				continue
			end

			-- ── Magnetic pull ──────────────────────────────────────────────────
			-- Only steer orbs that are within the magnet radius.
			-- Outside that radius the orb rolls/bounces on the ground naturally
			-- until the player walks close enough to "attract" it.
			if dist <= ORB_MAGNET_RADIUS then
				local playerPos = playerRoot.Position
				-- Reuse dist (already computed) to normalise: dir = delta / |delta|.
				-- This avoids calling .Unit which would recompute the magnitude internally.
				local direction = (playerPos - orbPos) / dist
				-- Constant pull speed: direct assignment, not +=.
				-- If we used += the orb would accelerate each frame → runaway velocity.
				part.AssemblyLinearVelocity = direction * ORB_PULL_SPEED
			end

			i -= 1
		end
	end)

	-- Expose globally (same _G pattern as EnemyService / DirectorService)
	_G.EconomyService = self
	print(("[EconomyService] Started — GoldOrb pool ready (%d slots pre-warmed)"):format(ORB_POOL_INITIAL))
end

return EconomyService
