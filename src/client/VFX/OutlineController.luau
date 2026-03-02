--!strict
--[[
	OutlineController.luau
	======================
	Manages the 31-Highlight hard limit imposed by Roblox's renderer.

	Priority rules (highest to lowest):
	  1. LocalPlayer's character     — always gets a slot (white outline).
	  2. Boss enemies (CollectionService tag "Boss") — up to BOSS_RESERVE slots.
	  3. Nearest horde enemies to the camera — fill remaining slots.

	Every UPDATE_INTERVAL seconds the controller re-evaluates which enemies are
	in the active set and seamlessly swaps Highlights between models using Adornee.
	No Highlight is ever destroyed; only Adornee + Enabled are changed.

	──────────────────────────────────────────────────────────────────────────────
	DEPENDENCIES
	  • CollectionService tag "Enemy"  — all enemy root models must carry this tag.
	  • CollectionService tag "Boss"   — elite/boss variants carry this extra tag.
	  • Each tagged model must expose a primary part (HumanoidRootPart or "HRP"
	    named child) for distance sampling.

	HOW TO CUSTOMISE
	  OUTLINE_COLOR     — change the ink colour (default black).
	  PLAYER_COLOR      — separate colour for the local player outline (default white).
	  BOSS_COLOR        — outline colour for boss-tier enemies.
	  HORDE_RANGE       — enemies beyond this stud distance are never highlighted.
	  UPDATE_INTERVAL   — lower = smoother transfers, higher = cheaper.
]]

-- ── Services ───────────────────────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- ── Module ────────────────────────────────────────────────────────────────────

local OutlineController = {}
OutlineController.Name = "OutlineController"

-- ── Constants ─────────────────────────────────────────────────────────────────

-- Roblox renderer hard cap — never exceed this.
local POOL_SIZE: number = 31

-- Slots reserved for the local player character (always 1).
local PLAYER_RESERVE: number = 1

-- Maximum boss slots. Bosses always take priority over horde.
-- If more bosses exist than this, extras are handled as horde.
local BOSS_RESERVE: number = 5

-- Remaining slots go to the nearest horde enemies.
local HORDE_SLOTS: number = POOL_SIZE - PLAYER_RESERVE - BOSS_RESERVE -- 25

-- Enemies beyond this distance (studs) are never considered for outline.
-- Keeps highlights feeling local and avoids wasting slots on off-screen stragglers.
local HORDE_RANGE: number = 120

-- How often (seconds) the priority list is re-evaluated.
local UPDATE_INTERVAL: number = 0.2

-- Outline colours.
local OUTLINE_COLOR: Color3 = Color3.new(0, 0, 0)        -- horde ink
local PLAYER_COLOR: Color3 = Color3.new(1, 1, 1)         -- player white outline
local BOSS_COLOR: Color3 = Color3.fromRGB(220, 60, 60)   -- boss red outline
local FILL_TRANSPARENCY: number = 1                       -- fully transparent fill = silhouette only
local OUTLINE_TRANSPARENCY: number = 0

-- ── State ─────────────────────────────────────────────────────────────────────

-- All 31 pre-created Highlight instances.
local _pool: { Highlight } = {}

-- Map: Model → the Highlight currently adorning it (nil if unlit).
local _assigned: { [Model]: Highlight } = {}

-- Scratch table reused every update — avoids allocating a new table each cycle.
local _activeSet: { Model } = {}

local _accumulator: number = 0

-- ── Private Helpers ───────────────────────────────────────────────────────────

-- Returns the Vector3 world position of a model's primary part or HRP-ish child.
local function getModelPosition(model: Model): Vector3?
	local root: BasePart? = model.PrimaryPart
		or (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
		or (model:FindFirstChild("HRP") :: BasePart?)
	if root then
		return root.Position
	end
	return nil
end

-- Acquires a Highlight from the pool and assigns it to `model`.
local function acquire(model: Model, outlineColor: Color3)
	if _assigned[model] then
		-- Already assigned — just update colour in case priority changed.
		_assigned[model].OutlineColor = outlineColor
		return
	end
	if #_pool == 0 then
		return -- pool exhausted (should not happen if accounting is correct)
	end
	local h = table.remove(_pool) :: Highlight
	h.Adornee = model
	h.OutlineColor = outlineColor
	h.Enabled = true
	_assigned[model] = h
end

-- Returns the Highlight for `model` back to the free pool.
local function release(model: Model)
	local h = _assigned[model]
	if not h then
		return
	end
	h.Enabled = false
	h.Adornee = nil
	_assigned[model] = nil
	table.insert(_pool, h)
end

-- ── Core Update ───────────────────────────────────────────────────────────────

local function update()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position

	local LocalPlayer = Players.LocalPlayer

	-- ── 1. Determine the desired active set ───────────────────────────────

	-- Reuse scratch table.
	table.clear(_activeSet)

	-- Player character (slot 0 — always first).
	local playerModel: Model? = LocalPlayer.Character
	if playerModel then
		table.insert(_activeSet, playerModel)
	end

	-- Collect all tagged enemies, separating bosses from horde.
	local bosses: { Model } = {}
	local horde: { { model: Model, distSq: number } } = {}
	local rangeSq = HORDE_RANGE * HORDE_RANGE

	for _, instance in CollectionService:GetTagged("Enemy") do
		local model = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
		if not model then
			continue
		end
		local pos = getModelPosition(model)
		if not pos then
			continue
		end
		local distSq = (pos - camPos).Magnitude ^ 2
		if distSq > rangeSq then
			continue
		end
		if CollectionService:HasTag(model, "Boss") or CollectionService:HasTag(instance, "Boss") then
			table.insert(bosses, model)
		else
			table.insert(horde, { model = model, distSq = distSq })
		end
	end

	-- Add bosses (capped at BOSS_RESERVE slots).
	local bossCount = math.min(#bosses, BOSS_RESERVE)
	for i = 1, bossCount do
		table.insert(_activeSet, bosses[i])
	end

	-- Sort horde by distance ascending (nearest first).
	table.sort(horde, function(a, b)
		return a.distSq < b.distSq
	end)

	-- Fill remaining horde slots.
	local hordeAdded = 0
	for _, entry in horde do
		if hordeAdded >= HORDE_SLOTS then
			break
		end
		table.insert(_activeSet, entry.model)
		hordeAdded += 1
	end

	-- ── 2. Build a lookup set for O(1) membership checks ──────────────────

	local activeMap: { [Model]: true } = {}
	for _, model in _activeSet do
		activeMap[model] = true
	end

	-- ── 3. Release highlights for models that fell out of the active set ──

	for model in _assigned do
		if not activeMap[model] then
			release(model)
		end
	end

	-- ── 4. Acquire highlights for newly active models ─────────────────────

	local playerChar = LocalPlayer.Character
	for _, model in _activeSet do
		local color: Color3
		if model == playerChar then
			color = PLAYER_COLOR
		elseif CollectionService:HasTag(model, "Boss") then
			color = BOSS_COLOR
		else
			color = OUTLINE_COLOR
		end
		acquire(model, color)
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function OutlineController:Init()
	-- Pre-create the entire pool up front so there are zero allocations during play.
	-- All Highlights live in a ScreenGui parented to PlayerGui.
	-- (Highlights work by Adornee, not by parent location — ScreenGui is just a tidy holder.)
	local LocalPlayer = Players.LocalPlayer
	local holder = Instance.new("ScreenGui")
	holder.Name = "OutlineHolder"
	holder.ResetOnSpawn = false
	holder.IgnoreGuiInset = true
	holder.Parent = LocalPlayer:WaitForChild("PlayerGui")

	for _ = 1, POOL_SIZE do
		local h = Instance.new("Highlight")
		h.FillTransparency = FILL_TRANSPARENCY
		h.OutlineTransparency = OUTLINE_TRANSPARENCY
		h.OutlineColor = OUTLINE_COLOR
		h.Enabled = false
		h.Parent = holder
		table.insert(_pool, h)
	end
end

function OutlineController:Start()
	-- Stagger-update on Heartbeat using a simple accumulator so we don't
	-- re-sort every single frame (24-stud SpatialGrid cells also change ~once/1.2s
	-- so UPDATE_INTERVAL = 0.2 is more than frequent enough to feel seamless).
	RunService.Heartbeat:Connect(function(dt: number)
		_accumulator += dt
		if _accumulator < UPDATE_INTERVAL then
			return
		end
		_accumulator = 0
		update()
	end)

	-- Re-apply player highlight immediately when the character spawns or respawns
	-- so the white outline never lags behind a respawn.
	local LocalPlayer = Players.LocalPlayer
	local function onCharacterAdded(character: Model)
		-- Release the old character model if still assigned.
		for model in _assigned do
			if model ~= character and not CollectionService:HasTag(model, "Enemy") then
				release(model)
			end
		end
		-- The main update loop will pick up the new character within UPDATE_INTERVAL.
	end
	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return OutlineController
