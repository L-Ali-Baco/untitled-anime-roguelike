--[[
	ChestService.luau
	Server-side manager for world-placed Gold Chests.

	Responsibilities:
	  - SpawnChest(position, stageNumber): instantiate a chest Model with a ProximityPrompt
	    whose ActionText displays the stage-scaled cost.
	  - On prompt trigger: validate gold → deduct → RollItem → GrantItem → fire VFX remote.
	  - Deactivate the prompt after opening so each chest can only be opened once.

	Stage-scaled cost formula:
	  cost = floor( BASE_CHEST_COST × STAGE_COST_MULT ^ (stageNumber - 1) )

	  Why (stageNumber - 1)?
	    At Stage 1 the exponent is 0, so 1.15^0 = 1 → cost equals BASE_CHEST_COST exactly.
	    At Stage 2: 1.15^1 = 1.15 → +15%
	    At Stage 5: 1.15^4 ≈ 1.75 → 43g
	    At Stage 10: 1.15^9 ≈ 3.52 → 88g
	    At Stage 20: 1.15^19 ≈ 16.4 → 410g (effectively forces gold stockpiling in late game)

	  Rationale: a flat cost would trivialise chests once the player has good gold income.
	  Compound scaling keeps the decision "do I save for the next beacon or spend now?" relevant
	  across all stages without manual tuning of each individual stage.

	Chest VFX (lid tween + item float) is handled client-side by ChestVFXController via the
	"ChestOpened" remote. Keeping VFX client-side provides smooth 60fps animation without
	server-replication lag affecting the visual.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local LootManager = require(Shared:WaitForChild("Lib"):WaitForChild("LootManager"))

-- Lazy-require ItemService to avoid circular dependency concerns at module load time.
-- Required on first chest open, not at startup.
local ItemService: any = nil
local EconomyService: any = nil

-- ============================================================
-- TUNING CONSTANTS
-- ============================================================

-- Base gold cost for a Stage 1 chest.
local BASE_CHEST_COST = 25 -- gold

-- Per-stage cost multiplier. 1.15 = 15% more expensive each stage.
-- See the cost formula in the header comment for a worked example.
local STAGE_COST_MULT = 1.15

-- ============================================================
-- CHEST MODEL FACTORY
-- ============================================================

-- Returns a chest Model, either cloning an asset from ReplicatedStorage.Shared.Assets.Chests
-- if one exists, or creating a simple procedural placeholder.
--
-- The model MUST have a BasePart named "Body" — the ProximityPrompt is attached there.
-- Optionally it may have a BasePart named "Lid" for the open animation on the client.
local function makeChestModel(position: Vector3): Model
	-- Try to load from assets first
	local assetsFolder = Shared:FindFirstChild("Assets")
	if assetsFolder then
		local chestsFolder = assetsFolder:FindFirstChild("Chests")
		if chestsFolder then
			local asset = chestsFolder:FindFirstChild("GoldChest")
			if asset and asset:IsA("Model") then
				local clone = asset:Clone()
				clone.Name = "GoldChest"
				clone:PivotTo(CFrame.new(position))
				return clone
			end
		end
	end

	-- ── Procedural placeholder ────────────────────────────────────────────────
	local model = Instance.new("Model")
	model.Name = "GoldChest"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(4, 3, 3)
	body.Color = Color3.fromRGB(180, 130, 50) -- Wooden brown
	body.Material = Enum.Material.Wood
	body.Anchored = true
	body.Position = position + Vector3.new(0, 1.5, 0)
	body.Parent = model

	-- Lid sits on top of the body; ChestVFXController tweens it open by rotating ~90°
	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Vector3.new(4, 0.4, 3)
	lid.Color = Color3.fromRGB(200, 155, 60)
	lid.Material = Enum.Material.Wood
	lid.Anchored = true
	-- The lid pivot is at the BACK edge of the body so it swings open naturally.
	-- Centre of lid is 0.2 studs above the body top (half of lid thickness = 0.2).
	lid.CFrame = body.CFrame * CFrame.new(0, 1.7, -1.5) -- top of body, back-offset
	lid.Parent = model

	-- Gold trim strip (decorative)
	local trim = Instance.new("Part")
	trim.Name = "Trim"
	trim.Size = Vector3.new(4.1, 0.3, 0.3)
	trim.Color = Color3.fromRGB(255, 200, 0)
	trim.Material = Enum.Material.Neon
	trim.Anchored = true
	trim.CFrame = body.CFrame * CFrame.new(0, 0, 1.55) -- front face
	trim.Parent = model

	model.PrimaryPart = body
	return model
end

-- ============================================================
-- CHEST COST CALCULATION
-- ============================================================

--[[
	Compute the gold cost for a chest at the given stage number.

	Formula:  cost = floor( BASE_CHEST_COST × STAGE_COST_MULT ^ (stageNumber - 1) )

	Examples (BASE_CHEST_COST=25, STAGE_COST_MULT=1.15):
	  Stage  1 →  25g   (1.15^0  = 1.000)
	  Stage  2 →  28g   (1.15^1  = 1.150)
	  Stage  3 →  32g   (1.15^2  = 1.323)
	  Stage  5 →  44g   (1.15^4  = 1.749)
	  Stage 10 →  88g   (1.15^9  = 3.518)
	  Stage 15 → 177g   (1.15^14 = 7.076)
	  Stage 20 → 409g   (1.15^19 = 16.37) ← save-up required
]]
local function computeChestCost(stageNumber: number): number
	-- Clamp stage to 1+ so we never get a negative exponent (which would make chests cheaper).
	local stage = math.max(1, stageNumber)
	return math.floor(BASE_CHEST_COST * (STAGE_COST_MULT ^ (stage - 1)))
end

-- ============================================================
-- SERVICE DEFINITION
-- ============================================================

local ChestService = {
	Name = "ChestService",
}

-- Active chest registry: Model → { stageNumber: number, opened: boolean }
-- Allows per-chest state without polluting the Model with attributes.
local activeChests: { [Model]: { stageNumber: number, opened: boolean } } = {}

-- ============================================================
-- INTERNAL: UNLOCK SEQUENCE
-- ============================================================

--[[
	Called when a player triggers a ProximityPrompt on a known chest.
	Performs the full unlock sequence:
	  1. Guard checks (chest state, prompt still enabled)
	  2. Validate + deduct gold via EconomyService
	  3. Disable prompt immediately to prevent double-triggers
	  4. Roll a random item via LootManager
	  5. Grant the item via ItemService
	  6. Fire "ChestOpened" for client-side lid tween + item preview VFX
]]
local function onPromptTriggered(player: Player, chestModel: Model, prompt: ProximityPrompt)
	local chestData = activeChests[chestModel]
	if not chestData then
		return
	end
	if chestData.opened then
		return -- Already opened by another player (race condition guard)
	end
	if not prompt.Enabled then
		return -- Prompt was disabled between trigger fire and this callback
	end

	-- ── Lazy-require services ─────────────────────────────────────────────────
	-- Required here so ChestService can be required before these services Start().
	if not EconomyService then
		EconomyService = _G.EconomyService
	end
	if not ItemService then
		local ok, svc = pcall(require, script.Parent.ItemService)
		if ok then
			ItemService = svc
		end
	end
	if not EconomyService or not ItemService then
		warn("[ChestService] Missing EconomyService or ItemService — chest cannot open")
		return
	end

	-- ── Validate and spend gold ───────────────────────────────────────────────
	local cost = computeChestCost(chestData.stageNumber)
	local success = EconomyService:SpendGold(player, cost)
	if not success then
		-- Insufficient gold — inform the player via a chat hint or dedicated remote.
		-- For now we simply print server-side; a proper UI hint can be added later.
		print(("[ChestService] %s cannot afford chest (need %dg)"):format(player.Name, cost))
		return
	end

	-- ── Disable prompt immediately ────────────────────────────────────────────
	-- Mark as opened BEFORE any yielding calls so concurrent triggers see the flag.
	chestData.opened = true
	prompt.Enabled = false

	-- ── Roll item ─────────────────────────────────────────────────────────────
	-- LootManager.RollItem returns TWO values: (itemKey: string?, rarity: string).
	-- We must capture both; discarding the second would silently lose the rarity info.
	local itemKey, rarity = LootManager.RollItem(chestData.stageNumber)

	-- ── Grant item ────────────────────────────────────────────────────────────
	if itemKey then
		local grantOk, grantErr = pcall(ItemService.GrantItem, ItemService, player, itemKey)
		if not grantOk then
			warn(("[ChestService] GrantItem failed for %s (key=%s): %s"):format(player.Name, itemKey, grantErr))
		end
	else
		-- RollItem can return nil itemKey if the rarity table is empty for this stage.
		-- Grant a small gold consolation prize so the player isn't left with nothing.
		EconomyService:AddGold(player, math.ceil(cost * 0.5))
		warn(("[ChestService] RollItem returned nil for stage %d — consolation gold granted"):format(chestData.stageNumber))
	end

	-- ── Fire VFX remote ───────────────────────────────────────────────────────
	-- ChestVFXController on every client receives this and plays the lid tween +
	-- floating item preview. Firing to AllClients so spectating players see it too.
	local chestOpenedRemote = Remotes:GetEvent("ChestOpened")
	if chestOpenedRemote then
		chestOpenedRemote:FireAllClients({
			ChestModel = chestModel,
			ItemKey = itemKey or "",
			Rarity = rarity or "Common",
		})
	end
end

-- ============================================================
-- PUBLIC API
-- ============================================================

--[[
	Spawns a new chest at `position` tuned for `stageNumber`.
	Returns the created Model so callers can track or parent it.

	The ProximityPrompt ActionText is set to the cost so players can see it without
	approaching the chest — a UX choice from Risk of Rain 2's chest UI.

	stageNumber must be ≥ 1. Values less than 1 are clamped to 1 internally.
]]
function ChestService:SpawnChest(position: Vector3, stageNumber: number): Model
	stageNumber = math.max(1, stageNumber)
	local cost = computeChestCost(stageNumber)

	local chestModel = makeChestModel(position)
	chestModel.Parent = workspace

	-- Find the "Body" part to attach the ProximityPrompt.
	-- ProximityPrompts must be children of a BasePart (not a Model).
	local body = chestModel:FindFirstChild("Body") :: BasePart?
	if not body then
		-- Fallback: use PrimaryPart or first BasePart found
		body = chestModel.PrimaryPart
			or chestModel:FindFirstChildWhichIsA("BasePart") :: BasePart?
	end
	if not body then
		warn("[ChestService] Chest model has no BasePart — cannot attach ProximityPrompt")
		return chestModel
	end

	-- ── ProximityPrompt setup ─────────────────────────────────────────────────
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "$" .. tostring(cost) .. " Gold"
	prompt.ObjectText = "Chest"
	-- Style: no hold required (tap to confirm) — feels snappier than a charge-hold.
	-- Could be changed to HoldDuration = 0.5 for a more deliberate chest interaction.
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false -- Don't punish players standing behind thin walls
	prompt.Parent = body

	-- Register chest before connecting Triggered so the callback can find it instantly.
	activeChests[chestModel] = { stageNumber = stageNumber, opened = false }

	-- Connect the trigger callback. Uses a local closure to capture chestModel + prompt.
	prompt.Triggered:Connect(function(player: Player)
		onPromptTriggered(player, chestModel, prompt)
	end)

	-- Auto-cleanup when the model is removed from the world (e.g. round end).
	chestModel.AncestryChanged:Connect(function(_, newParent)
		if not newParent then
			activeChests[chestModel] = nil
		end
	end)

	print(("[ChestService] Chest spawned at %s — Stage %d, costs %dg"):format(
		tostring(position),
		stageNumber,
		cost
	))
	return chestModel
end

--[[
	Returns the gold cost for a chest at the given stage, without spawning anything.
	Useful for UI previews or Director budget calculations.
]]
function ChestService:GetCost(stageNumber: number): number
	return computeChestCost(stageNumber)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function ChestService:Init()
	print("[ChestService] Initializing...")
end

function ChestService:Start()
	-- Expose globally for Director, SpawnerService, or debug commands.
	_G.ChestService = self
	print("[ChestService] Started")
end

return ChestService
