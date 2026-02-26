--!strict
--[[
	LootManager.luau
	Weighted item drop tables with stage-based loot scaling.

	Responsibilities:
	  - Define base rarity weights (stage 1 baseline)
	  - Scale weights toward rarer tiers as stageNumber increases
	  - Weighted random rarity selection (correct normalized CDF)
	  - Roll a random item key for a given stage
	  - Roll N distinct items (for pick-1-of-N chest UI)

	──────────────────────────────────────────────────────────────────────────
	WEIGHT MATH
	──────────────────────────────────────────────────────────────────────────
	Raw weights shift per stage via STAGE_DELTA. The deltas must sum to 0
	so the total pool stays constant before normalization:

	  Common    -2.5 per stage
	  Rare      +1.0 per stage
	  Epic      +1.0 per stage
	  Legendary +0.5 per stage
	  Sum:      0.0 ✓ (zero-sum transfer)

	Weights are clamped to WEIGHT_FLOORS before normalizing.
	Normalization (divide each raw weight by total) ensures the probability
	distribution always sums to exactly 1.0 regardless of clamping.

	Example progression:
	  Stage 1  → Common 55%  Rare 28%  Epic 13%  Legendary  4%
	  Stage 5  → Common 45%  Rare 32%  Epic 17%  Legendary  6%
	  Stage 10 → Common 33%  Rare 37%  Epic 22%  Legendary  9%  (floors active)
	  Stage 20 → Common 15%  Rare 42%  Epic 30%  Legendary 14%  (floors active)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("Config"):WaitForChild("ItemRegistry"))

-- ── CONFIGURATION ────────────────────────────────────────────────────────────

-- Raw starting weights at Stage 1 (not percentages — will be normalized).
local BASE_WEIGHTS: { [string]: number } = {
	Common = 55,
	Rare = 28,
	Epic = 13,
	Legendary = 4,
}

-- Weight transferred away from Common toward rarer tiers each stage.
-- Must sum to 0 to keep the total self-consistent before normalization.
local STAGE_DELTA: { [string]: number } = {
	Common = -2.5, -- loses 2.5 raw weight per stage
	Rare = 1.0, -- gains 1.0 raw weight per stage
	Epic = 1.0, -- gains 1.0 raw weight per stage
	Legendary = 0.5, -- gains 0.5 raw weight per stage
}

-- Minimum raw weight any rarity can reach (prevents a tier from disappearing).
local WEIGHT_FLOORS: { [string]: number } = {
	Common = 15,
	Rare = 8,
	Epic = 4,
	Legendary = 2,
}

-- Iteration order used for the CDF roll (must be stable).
local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary" }

-- ── INTERNAL HELPERS ─────────────────────────────────────────────────────────

--[[
	Compute normalized probability weights for a given stage.
	Returns { Common: probability, Rare: probability, ... } summing to 1.0.
]]
local function computeRarityWeights(stageNumber: number): { [string]: number }
	local stage = math.max(1, stageNumber)
	local stageBonus = stage - 1 -- 0 at stage 1, 1 at stage 2, etc.

	-- Apply per-stage delta to base weights, clamped to floors
	local raw: { [string]: number } = {}
	local total = 0
	for rarity, base in BASE_WEIGHTS do
		local delta = (STAGE_DELTA[rarity] or 0) * stageBonus
		local floor = WEIGHT_FLOORS[rarity] or 0
		local weight = math.max(floor, base + delta)
		raw[rarity] = weight
		total += weight
	end

	-- Normalize: each weight becomes a 0–1 probability
	local normalized: { [string]: number } = {}
	for rarity, weight in raw do
		normalized[rarity] = weight / total
	end
	return normalized
end

-- ── PUBLIC API ────────────────────────────────────────────────────────────────

local LootManager = {}

--[[
	RollRarity(stageNumber) → string

	Weighted random rarity selection using a cumulative distribution function.
	Rolls math.random() once (uniform 0–1) and steps through the sorted CDF.

	Example at Stage 1: roll=0.72 → 0.55 (Common) + 0.28 (Rare) = 0.83 → "Rare"
]]
function LootManager.RollRarity(stageNumber: number): string
	local weights = computeRarityWeights(stageNumber)
	local roll = math.random() -- uniform [0, 1)
	local cumulative = 0

	for _, rarity in RARITY_ORDER do
		cumulative += weights[rarity] or 0
		if roll <= cumulative then
			return rarity
		end
	end

	return "Common" -- floating-point safety fallback
end

--[[
	RollItem(stageNumber) → (itemKey: string?, rarity: string)

	Rolls a rarity for the stage, then picks uniformly among all items
	of that rarity. If a rarity has no items in the pool yet (e.g. you
	haven't made any Epic items), falls back to Common so the chest
	always returns something.

	Returns:
	  itemKey  — key into ItemRegistry.Pool (nil only if entire pool is empty)
	  rarity   — the rarity that was rolled (even on fallback)
]]
function LootManager.RollItem(stageNumber: number): (string?, string)
	local rarity = LootManager.RollRarity(stageNumber)

	-- Collect all item keys of the rolled rarity
	local pool: { string } = {}
	for key, item in ItemRegistry.Pool do
		if item.Rarity == rarity then
			table.insert(pool, key)
		end
	end

	-- Rarity has no items yet — fall back to Common
	if #pool == 0 then
		for key, item in ItemRegistry.Pool do
			if item.Rarity == "Common" then
				table.insert(pool, key)
			end
		end
	end

	if #pool == 0 then
		return nil, rarity -- entire pool is empty (should never happen in prod)
	end

	return pool[math.random(#pool)], rarity
end

--[[
	RollDistinctItems(stageNumber, count) → { string }

	Rolls `count` distinct item keys for a chest UI (e.g. pick-1-of-3).
	Each item is rolled independently so different rarities can appear
	in the same chest — a player might see 2 Commons and 1 Legendary.

	Guarantees all returned keys are unique. If the pool is too small to
	fill `count` distinct items, fills remaining slots with any unseen key
	from the full pool.
]]
function LootManager.RollDistinctItems(stageNumber: number, count: number): { string }
	local chosen: { string } = {}
	local seen: { [string]: boolean } = {}
	local maxAttempts = count * 12 -- prevent infinite loop on small pools

	local attempts = 0
	while #chosen < count and attempts < maxAttempts do
		attempts += 1
		local key = LootManager.RollItem(stageNumber)
		if key and not seen[key] then
			seen[key] = true
			table.insert(chosen, key)
		end
	end

	-- Fill any remaining slots with unseen keys if the pool was too small
	if #chosen < count then
		for key, _ in ItemRegistry.Pool do
			if #chosen >= count then
				break
			end
			if not seen[key] then
				seen[key] = true
				table.insert(chosen, key)
			end
		end
	end

	return chosen
end

--[[
	GetRarityOdds(stageNumber) → { [string]: number }

	Returns the normalized probability table for a stage.
	Useful for debug displays or tooltips.

	Example output at Stage 5:
	  { Common=0.452, Rare=0.323, Epic=0.166, Legendary=0.059 }
]]
function LootManager.GetRarityOdds(stageNumber: number): { [string]: number }
	return computeRarityWeights(stageNumber)
end

return LootManager
