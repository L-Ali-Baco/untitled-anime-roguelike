--[[
	HUDController.luau
	Central orchestrator for the Player HUD.

	Responsibilities:
	  • Boot all HUD components in Start() after the Framework is fully loaded.
	  • Connect the GrantItem remote and route it to InventoryGrid.
	  • Connect the HealthChanged remote (server-authoritative sync fallback — the health
	    bar already reacts to Humanoid.HealthChanged locally, but the server fires
	    HealthChanged when it wants the client to re-sync during unusual state changes
	    like class switch or instant-kill effects).
	  • Expose TriggerCooldownUI(parentFrame, duration) as a reusable utility for any
	    frame-based cooldown overlay (chests, item lockouts, environmental hazards, etc.)
	    This is SEPARATE from SkillBar.luau's reactive cooldown system — both coexist.

	HUD component map:
	  ┌─────────────────────────────────────────────────────────────┐
	  │  Component              File                    Position    │
	  │  ─────────────────────  ──────────────────────  ─────────  │
	  │  PlayerHealthBar        UI/HUD/PlayerHealthBar  Bot-Centre  │
	  │  StaminaBar             UI/HUD/StaminaBar        ↑ above    │
	  │  SkillBar               UI/HUD/SkillBar          ↑ above    │
	  │  GoldDisplay   (NEW)    UI/HUD/GoldDisplay       Bot-Left   │
	  │  ScrapDisplay           UI/HUD/ScrapDisplay      Bot-Right  │
	  │  InventoryGrid (NEW)    UI/HUD/InventoryGrid     Top-Right  │
	  └─────────────────────────────────────────────────────────────┘

	NOTE: Each component creates its own ScreenGui. There is no manually-built
	StarterGui hierarchy — everything is programmatic via Fusion. When playtesting
	in Studio, open Explorer → LocalPlayer → PlayerGui to inspect the live hierarchy.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

-- Lazy-loaded HUD component modules (required in Start, not at module load time,
-- so HUDController can be safely required by other modules without triggering all
-- component loads at once).
local PlayerHealthBar = nil
local GoldDisplay = nil
local InventoryGrid = nil
local SkillBar = nil
local ScrapDisplay = nil
local StaminaBar = nil

-- ── Controller ────────────────────────────────────────────────────────────────

local HUDController = {
	Name = "HUDController",
}

-- Live component handles (populated in Start)
local _healthBarCleanup: (() -> ())? = nil
local _goldDisplayCleanup: (() -> ())? = nil
local _inventoryGrid: { UpdateItem: (string, number, string?) -> (), Destroy: () -> () }? = nil
local _skillBarCleanup: (() -> ())? = nil
local _scrapDisplayCleanup: (() -> ())? = nil

-- ── TriggerCooldownUI (Task 4) ─────────────────────────────────────────────────────
--[[
	Overlays a semi-transparent dark frame on `parentFrame` and shrinks it from full
	height to zero height over `duration` seconds using TweenService, visually
	revealing the parent content as the timer elapses — identical to how SkillBar
	renders individual skill cooldowns, but usable on any arbitrary Frame.

	The overlay Frame (named "CooldownOverlay") is created on first call and reused
	on subsequent calls, so this is safe to call repeatedly (e.g., every time a
	player interacts with a chest or uses a consumable).

	Overlay geometry:
	  AnchorPoint = (0, 1)  — bottom-left corner is the anchor
	  Position    = scale(0, 1) — bottom edge aligns with parent's bottom edge
	  Size.Y      = 1 → 0  — top edge descends toward the anchor (curtain-drops down)
	  Net effect  = the dark overlay shrinks downward, revealing the icon from the top.

	A countdown TextLabel inside the overlay shows the remaining time to 1 decimal.
	It is hidden once the cooldown finishes.
]]
function HUDController:TriggerCooldownUI(parentFrame: Frame, duration: number)
	if not parentFrame or not parentFrame:IsA("Frame") then
		warn("[HUDController] TriggerCooldownUI: parentFrame must be a Frame instance")
		return
	end
	if duration <= 0 then
		return
	end

	-- ── Find or create the overlay ──────────────────────────────────────────
	local overlay = parentFrame:FindFirstChild("CooldownOverlay") :: Frame?
	if not overlay then
		overlay = Instance.new("Frame")
		overlay.Name = "CooldownOverlay"
		-- Anchor at bottom-left so the overlay shrinks downward as Y → 0
		overlay.AnchorPoint = Vector2.new(0, 1)
		overlay.Position = UDim2.fromScale(0, 1)
		overlay.BackgroundColor3 = Color3.new(0, 0, 0)
		overlay.BackgroundTransparency = 0.45
		overlay.BorderSizePixel = 0
		overlay.ZIndex = (parentFrame.ZIndex or 1) + 1
		overlay.Parent = parentFrame

		local timerLabel = Instance.new("TextLabel")
		timerLabel.Name = "CooldownTimer"
		timerLabel.Size = UDim2.fromScale(1, 1)
		timerLabel.BackgroundTransparency = 1
		timerLabel.TextColor3 = Color3.new(1, 1, 1)
		timerLabel.Font = Enum.Font.GothamBold
		timerLabel.TextSize = 16
		timerLabel.TextStrokeTransparency = 0
		timerLabel.ZIndex = overlay.ZIndex + 1
		timerLabel.Parent = overlay
	end

	-- ── Reset overlay to full height ────────────────────────────────────────
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Visible = true

	-- ── Tween: shrink Y from 1 → 0 over `duration` seconds ─────────────────
	-- Linear easing keeps the visual progress proportional to remaining time,
	-- which is the most readable for a "timer draining" effect.
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	local tween = TweenService:Create(overlay, tweenInfo, {
		Size = UDim2.fromScale(1, 0),
	})
	tween:Play()
	tween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			overlay.Visible = false
		end
	end)

	-- ── Countdown text ──────────────────────────────────────────────────────
	-- Runs on a separate Heartbeat so the label stays accurate even if the tween
	-- stutters under heavy frame time (the Tween and the label are independent).
	local timerLabel = overlay:FindFirstChild("CooldownTimer") :: TextLabel?
	if timerLabel then
		local startTime = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.Heartbeat:Connect(function()
			local remaining = duration - (os.clock() - startTime)
			if remaining <= 0 then
				timerLabel.Text = ""
				conn:Disconnect()
			else
				timerLabel.Text = string.format("%.1f", remaining)
			end
		end)
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function HUDController:Init()
	print("[HUDController] Initializing...")
end

function HUDController:Start()
	print("[HUDController] Starting HUD components...")

	-- Require all component modules now that the Framework is fully loaded.
	-- pcall each require so one broken component doesn't prevent the others from loading.
	local function safeRequire(path: ModuleScript, name: string): any?
		local ok, result = pcall(require, path)
		if not ok then
			warn(("[HUDController] Failed to require %s: %s"):format(name, result))
			return nil
		end
		return result
	end

	local hudFolder = script.Parent.Parent.UI.HUD

	PlayerHealthBar = safeRequire(hudFolder.PlayerHealthBar, "PlayerHealthBar")
	GoldDisplay = safeRequire(hudFolder.GoldDisplay, "GoldDisplay")
	InventoryGrid = safeRequire(hudFolder.InventoryGrid, "InventoryGrid")
	SkillBar = safeRequire(hudFolder.SkillBar, "SkillBar")
	ScrapDisplay = safeRequire(hudFolder.ScrapDisplay, "ScrapDisplay")
	StaminaBar = safeRequire(hudFolder.StaminaBar, "StaminaBar")

	-- ── Boot components ─────────────────────────────────────────────────────

	if PlayerHealthBar then
		_healthBarCleanup = PlayerHealthBar.new()
		print("[HUDController] HealthBar started")
	end

	if GoldDisplay then
		_goldDisplayCleanup = GoldDisplay.new()
		print("[HUDController] GoldDisplay started")
	end

	if InventoryGrid then
		_inventoryGrid = InventoryGrid.new()
		print("[HUDController] InventoryGrid started")
	end

	-- SkillBar takes an optional classController reference so it can react to class changes.
	-- We look it up from the Framework's controller registry. If it isn't registered yet
	-- (e.g. class selection hasn't happened), SkillBar defaults gracefully to Vanguard.
	if SkillBar then
		local ok, Framework = pcall(require, ReplicatedStorage.Shared.Framework)
		local classController = ok and Framework.Controllers and Framework.Controllers["ClassController"]
		_skillBarCleanup = SkillBar.new(classController)
		print("[HUDController] SkillBar started")
	end

	if ScrapDisplay then
		_scrapDisplayCleanup = ScrapDisplay.new()
		print("[HUDController] ScrapDisplay started")
	end

	-- StaminaBar requires a StaminaController reference.
	-- Look it up the same way as ClassController.
	if StaminaBar then
		local ok, Framework = pcall(require, ReplicatedStorage.Shared.Framework)
		local staminaController = ok and Framework.Controllers and Framework.Controllers["StaminaController"]
		if staminaController then
			StaminaBar.new(staminaController)
			print("[HUDController] StaminaBar started")
		else
			warn("[HUDController] StaminaController not found — StaminaBar skipped")
		end
	end

	-- ── Remote connections ─────────────────────────────────────────────────

	-- GrantItem: routes item data to the inventory grid.
	-- Payload: (itemKey: string, stackCount: number)
	-- The server fires this from ItemService:GrantItem after updating inventory state.
	-- Rarity is looked up from ItemRegistry client-side to keep the payload lean.
	local grantRemote = Remotes:GetEvent("GrantItem")
	if grantRemote and _inventoryGrid then
		local grid = _inventoryGrid -- local capture so the closure is safe post-Destroy
		grantRemote.OnClientEvent:Connect(function(itemKey: string, stackCount: number)
			if typeof(itemKey) ~= "string" or itemKey == "" then
				return -- Malformed payload guard
			end
			grid.UpdateItem(itemKey, stackCount or 1)
		end)
	end

	-- HealthChanged: server-authoritative health sync.
	-- The health bar already reacts to Humanoid.HealthChanged locally (zero-latency),
	-- but the server fires HealthChanged when it needs to force a specific display value
	-- (e.g., instant-kill, class-switch health reset, or debug override).
	-- Payload: { CurrentHealth: number, MaxHealth: number, Shield: number }
	-- NOTE: CombatService must call Remotes:GetEvent("HealthChanged"):FireClient(player, payload)
	-- for this to have any effect. The health bar works without it via Humanoid.HealthChanged.
	local healthRemote = Remotes:GetEvent("HealthChanged")
	if healthRemote then
		local LocalPlayer = Players.LocalPlayer
		healthRemote.OnClientEvent:Connect(function(payload: { [string]: number })
			local char = LocalPlayer.Character
			if not char then
				return
			end
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and payload.MaxHealth and payload.MaxHealth > 0 then
				-- Force the Humanoid health to match the server's authoritative value.
				-- PlayerHealthBar's Humanoid.HealthChanged listener will pick this up
				-- automatically and animate to the new value.
				hum.MaxHealth = payload.MaxHealth
				hum.Health = math.clamp(payload.CurrentHealth or hum.Health, 0, payload.MaxHealth)
			end
			if payload.Shield ~= nil then
				char:SetAttribute("Shield", payload.Shield)
			end
		end)
	end

	print("[HUDController] All HUD components started")
end

return HUDController
