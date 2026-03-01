--[[
	InventoryGrid.luau
	Reactive item inventory grid for the player HUD.

	Architecture:
	  The ScreenGui container and panel are created declaratively with Fusion.
	  Individual item slots are managed imperatively (Instance.new), because Fusion's
	  ForPairs requires the full items list as reactive state — which means re-rendering
	  ALL slots on every GrantItem event. The imperative approach creates a slot ONCE
	  per unique itemKey and thereafter only updates the stack text label, keeping
	  per-frame work at an absolute minimum.

	Slot anatomy:
	  ItemSlot (Frame)
	  ├── ItemIcon   (ImageLabel)   — item icon from ItemRegistry
	  ├── RarityGlow (Frame)        — UIStroke coloured by rarity tier
	  └── StackText  (TextLabel)    — "×2", "×3", etc. Hidden at stack 1

	Public API:
	  grid:UpdateItem(itemKey: string, stackCount: number, rarity: string?)
	  grid:Destroy()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)

local scoped = Fusion.scoped
local Children = Fusion.Children

-- ── Visual constants ──────────────────────────────────────────────────────────
local SLOT_SIZE = 50 -- px, square
local SLOT_PADDING = 6 -- px gap between slots
local PANEL_COLUMNS = 8 -- how many columns before wrapping
local PANEL_MAX_ROWS = 3 -- panel grows up to this many rows

-- Rarity border colours — mirrors ChestVFXController and ItemRegistry.Rarities
-- ItemRegistry.Rarities uses Color3 values directly; we re-declare here to keep
-- the component self-contained and avoid a require-at-module-load edge case.
local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(200, 200, 200),
	Uncommon = Color3.fromRGB(100, 220, 100),
	Rare = Color3.fromRGB(80, 140, 220),
	Epic = Color3.fromRGB(160, 80, 220),
	Legendary = Color3.fromRGB(255, 190, 0),
}
local RARITY_DEFAULT = Color3.fromRGB(180, 180, 180)

-- ── Slot factory ──────────────────────────────────────────────────────────────

-- Creates a single item slot Frame and returns it together with the stack TextLabel
-- so UpdateItem can update the counter later without searching the hierarchy.
local function makeSlot(
	itemKey: string,
	stackCount: number,
	rarity: string,
	parent: Instance
): (Frame, TextLabel)
	local itemData = ItemRegistry.Pool[itemKey]
	local iconId = (itemData and itemData.Icon) or ""
	local borderColor = RARITY_COLORS[rarity] or RARITY_DEFAULT

	-- Root frame
	local slot = Instance.new("Frame")
	slot.Name = "Slot_" .. itemKey
	slot.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
	slot.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	slot.BackgroundTransparency = 0.2
	slot.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = slot

	-- Rarity-coloured border (UIStroke — shows through corner rounding)
	local stroke = Instance.new("UIStroke")
	stroke.Color = borderColor
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = slot

	-- Item icon
	local icon = Instance.new("ImageLabel")
	icon.Name = "ItemIcon"
	icon.Size = UDim2.fromScale(0.8, 0.8)
	icon.Position = UDim2.fromScale(0.1, 0.1)
	icon.BackgroundTransparency = 1
	icon.Image = iconId
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = slot

	-- Stack counter label (bottom-right corner)
	-- Hidden when stackCount == 1 so single-stack items look clean.
	local stackLabel = Instance.new("TextLabel")
	stackLabel.Name = "StackText"
	stackLabel.Size = UDim2.new(1, -4, 0, 18)
	stackLabel.Position = UDim2.new(0, 2, 1, -18)
	stackLabel.BackgroundTransparency = 1
	stackLabel.Text = if stackCount > 1 then ("×" .. stackCount) else ""
	stackLabel.TextColor3 = Color3.new(1, 1, 1)
	stackLabel.Font = Enum.Font.GothamBold
	stackLabel.TextSize = 13
	stackLabel.TextXAlignment = Enum.TextXAlignment.Right
	stackLabel.TextStrokeTransparency = 0
	stackLabel.ZIndex = 3
	stackLabel.Parent = slot

	slot.Parent = parent
	return slot, stackLabel
end

-- ── Component ─────────────────────────────────────────────────────────────────

local InventoryGrid = {}

function InventoryGrid.new(): { UpdateItem: (string, number, string?) -> (), Destroy: () -> () }
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	-- Internal slot registry: itemKey → { slot: Frame, stackLabel: TextLabel }
	-- Checked in UpdateItem to decide create-new vs update-existing.
	local slots: { [string]: { slot: Frame, stackLabel: TextLabel } } = {}

	-- The grid holder is created imperatively so we can hold a direct reference.
	-- Fusion builds the ScreenGui + outer panel around it; we reach inside to parent slots.
	local gridHolder: Frame = Instance.new("Frame")
	gridHolder.Name = "ItemGrid"
	gridHolder.Size = UDim2.fromScale(1, 1)
	gridHolder.BackgroundTransparency = 1

	-- UIGridLayout drives automatic slot positioning; no manual CFrame math needed.
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
	layout.CellPadding = UDim2.new(0, SLOT_PADDING, 0, SLOT_PADDING)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = gridHolder

	-- Panel dimensions — wide enough for PANEL_COLUMNS × PANEL_MAX_ROWS slots.
	local panelW = PANEL_COLUMNS * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	local panelH = PANEL_MAX_ROWS * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING

	-- Outer panel container with Fusion for the ScreenGui + background frame.
	-- We pass gridHolder as a pre-built child via [Children].
	scope:New("ScreenGui")({
		Name = "InventoryHUD",
		Parent = playerGui,
		ResetOnSpawn = false,
		DisplayOrder = 10,

		[Children] = {
			scope:New("Frame")({
				Name = "InventoryPanel",
				-- Top-right corner, 20 px margin
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -20, 0, 20),
				Size = UDim2.new(0, panelW, 0, panelH),
				BackgroundColor3 = Color3.fromRGB(15, 15, 15),
				BackgroundTransparency = 0.55,
				ClipsDescendants = true,

				[Children] = {
					scope:New("UICorner")({ CornerRadius = UDim.new(0, 8) }),
					scope:New("UIStroke")({
						Color = Color3.fromRGB(60, 60, 60),
						Thickness = 1,
					}),
					scope:New("UIPadding")({
						PaddingTop = UDim.new(0, 6),
						PaddingLeft = UDim.new(0, 6),
						PaddingBottom = UDim.new(0, 6),
						PaddingRight = UDim.new(0, 6),
					}),
					gridHolder, -- imperative holder injected here
				},
			}),
		},
	})

	-- ── Public API ─────────────────────────────────────────────────────────────

	--[[
		UpdateItem(itemKey, stackCount, rarity?)

		Called by HUDController when the GrantItem remote fires.
		  • First call for an itemKey: creates a new slot frame with icon + border.
		  • Subsequent calls: updates only the stack counter label — no new Instance.new.

		rarity is optional; if nil we look it up from ItemRegistry.Pool[itemKey].Rarity.
		If the item isn't in the registry the slot still renders with a placeholder icon.
	]]
	local function updateItem(itemKey: string, stackCount: number, rarity: string?)
		-- Resolve rarity from registry if not provided
		local resolvedRarity: string = rarity
			or (ItemRegistry.Pool[itemKey] and ItemRegistry.Pool[itemKey].Rarity)
			or "Common"

		local existing = slots[itemKey]
		if existing then
			-- ── Update existing slot ───────────────────────────────────────────
			-- Only the stack label changes; icon, border, position are all stable.
			existing.stackLabel.Text = if stackCount > 1 then ("×" .. stackCount) else ""
		else
			-- ── Create new slot ────────────────────────────────────────────────
			-- LayoutOrder = creation order so older items stay stable at the front.
			local slot, stackLabel = makeSlot(itemKey, stackCount, resolvedRarity, gridHolder)
			slot.LayoutOrder = #slots + 1
			slots[itemKey] = { slot = slot, stackLabel = stackLabel }
		end
	end

	return {
		UpdateItem = updateItem,
		Destroy = function()
			Fusion.doCleanup(scope)
		end,
	}
end

return InventoryGrid
