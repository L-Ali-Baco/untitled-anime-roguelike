--[[
	GoldDisplay.luau
	Animated Gold counter HUD component.

	When gold is earned the displayed number ticks upward from the previous value to the
	new total rather than snapping instantly — the same satisfying "coin counter" effect
	used in games like Hades and Risk of Rain 2.

	Animation math:
	  Each Heartbeat the displayed value steps toward the target at a speed of:
	    speed = max(diff × ANIM_SPEED_MULT, ANIM_SPEED_MIN)
	  Because speed scales with the difference, the animation always takes approximately
	  the same wall-clock time (≈ 1 / ANIM_SPEED_MULT seconds) regardless of how much
	  gold was earned. At the default ANIM_SPEED_MULT = 8 that's ~0.125 s — fast and
	  punchy, clearly visible but never feels sluggish.

	Data sources (in priority order):
	  1. GoldChanged remote — fired by EconomyService when gold changes; triggers animation.
	  2. Player "Gold" attribute signal — fallback sync for cases where the remote fires
	     before the client remote listener is set up, or during rejoin.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local Value = Fusion.Value

local peek = Fusion.peek
	or function(state)
		if typeof(state) == "table" and state.get then
			return state:get(false)
		end
		return state
	end

-- ── Animation tuning ──────────────────────────────────────────────────────────
-- speed = max(diff × MULT, MIN)
-- MULT = 8  → animation finishes in ~1/8 s (0.125 s) regardless of gold amount
-- MIN  = 20 → even a 1-gold pickup ticks for a brief visible moment
local ANIM_SPEED_MULT = 8
local ANIM_SPEED_MIN = 20

local GoldDisplay = {}

function GoldDisplay.new(): () -> ()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer

	-- goldTarget: the real gold total, set when the remote fires or attribute changes.
	-- goldDisplayed: the animated number shown in the label; steps toward goldTarget.
	local goldTarget = scope:Value(0)
	local goldDisplayed = scope:Value(0)

	-- Initialise both from the attribute so the display is immediately correct
	-- when the controller starts (e.g. reconnecting mid-session).
	local function syncInitial()
		local v = LocalPlayer:GetAttribute("Gold") or 0
		goldTarget:set(v)
		goldDisplayed:set(v) -- Snap on initial load — no count-up animation
	end
	syncInitial()

	-- ── Remote listener ────────────────────────────────────────────────────────
	-- GoldChanged fires with the new total. Setting only goldTarget (not goldDisplayed)
	-- starts the count-up animation; goldDisplayed will catch up via the Heartbeat.
	local remote = Remotes:GetEvent("GoldChanged")
	if remote then
		table.insert(
			scope,
			remote.OnClientEvent:Connect(function(newTotal: number)
				goldTarget:set(newTotal)
			end)
		)
	end

	-- ── Attribute fallback ─────────────────────────────────────────────────────
	-- Covers cases where the remote fires before this listener is connected,
	-- or where another system directly sets the attribute without firing the remote.
	table.insert(
		scope,
		LocalPlayer:GetAttributeChangedSignal("Gold"):Connect(function()
			local v = LocalPlayer:GetAttribute("Gold") or 0
			-- Only update target if it's ahead of current target (prevents jitter if both
			-- the remote and the attribute signal fire for the same change).
			if v > peek(goldTarget) then
				goldTarget:set(v)
			end
		end)
	)

	-- ── Heartbeat tick-up ──────────────────────────────────────────────────────
	-- Steps goldDisplayed toward goldTarget each frame.
	-- Uses proportional speed so the animation duration is always ~0.125 s,
	-- not a fixed rate that would be imperceptibly fast for large gains or
	-- annoyingly slow for tiny pickups.
	table.insert(
		scope,
		RunService.Heartbeat:Connect(function(dt: number)
			local target = peek(goldTarget)
			local current = peek(goldDisplayed)
			if current == target then
				return -- Already at target; nothing to animate
			end

			local diff = math.abs(target - current)
			-- speed scales with the gap: fast for large gains, min-capped for tiny ones
			local speed = math.max(diff * ANIM_SPEED_MULT, ANIM_SPEED_MIN)
			local step = speed * dt

			if step >= diff then
				-- Close enough: snap to avoid floating-point micro-oscillation
				goldDisplayed:set(target)
			else
				local dir = target > current and 1 or -1
				goldDisplayed:set(math.round(current + step * dir))
			end
		end)
	)

	-- ── Build UI ───────────────────────────────────────────────────────────────
	-- Positioned bottom-left, above the Scrap counter (Scrap is bottom-right).
	-- Size: 160 × 40 px — matches ScrapDisplay dimensions for visual consistency.
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	scope:New("ScreenGui")({
		Name = "GoldHUD",
		Parent = playerGui,
		ResetOnSpawn = false,
		DisplayOrder = 10,

		[Children] = {
			scope:New("Frame")({
				Name = "GoldContainer",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 20, 1, -20), -- Bottom-left, 20px margin
				Size = UDim2.new(0, 160, 0, 40),
				BackgroundColor3 = Color3.fromRGB(30, 30, 30),
				BackgroundTransparency = 0.4,

				[Children] = {
					scope:New("UICorner")({ CornerRadius = UDim.new(0, 6) }),
					-- Gold-tinted border; matches the orb neon colour from EconomyService
					scope:New("UIStroke")({
						Color = Color3.fromRGB(140, 100, 0),
						Thickness = 2,
					}),

					-- Coin glyph (filled circle in gold — uses a text label as a lightweight icon)
					scope:New("TextLabel")({
						Name = "GoldIcon",
						Size = UDim2.new(0, 30, 1, 0),
						Position = UDim2.new(0, 8, 0, 0),
						BackgroundTransparency = 1,
						Text = "●",
						TextColor3 = Color3.fromRGB(255, 200, 0),
						Font = Enum.Font.GothamBold,
						TextSize = 20,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),

					-- Animated counter. Text is derived from goldDisplayed (the animated value)
					-- so the Fusion Computed re-fires every frame only while animating,
					-- and goes quiet once the counter reaches its target.
					scope:New("TextLabel")({
						Name = "GoldText",
						Size = UDim2.new(1, -44, 1, 0),
						Position = UDim2.new(0, 38, 0, 0),
						BackgroundTransparency = 1,
						Text = Computed(scope, function(use)
							return "$" .. tostring(use(goldDisplayed))
						end),
						TextColor3 = Color3.fromRGB(255, 215, 50),
						Font = Enum.Font.GothamBold,
						TextSize = 20,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextStrokeTransparency = 0.5,
					}),
				},
			}),
		},
	})

	-- Return Fusion cleanup; disconnects all connections and destroys ScreenGui
	return function()
		Fusion.doCleanup(scope)
	end
end

return GoldDisplay
