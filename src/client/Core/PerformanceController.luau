--!strict
--[[
	PerformanceController.luau
	==========================
	Detects hardware capabilities at module-load time and exposes boolean flags
	that any controller can require() to gate expensive rendering features.

	── WHY MODULE-LOAD TIME, NOT Init() ────────────────────────────────────────

	UserInputService properties are available the moment the client VM starts —
	they reflect the hardware, not a runtime state. Reading them at load time
	means any module that require()s this file gets the correct IsMobile value
	immediately, even if it runs before PerformanceController:Init() is called
	by the framework. This avoids a class of ordering-dependent bugs.

	── DETECTION HEURISTIC ─────────────────────────────────────────────────────

	  TouchEnabled    = true   → the device HAS a touchscreen (phones, tablets,
	                             but ALSO Windows laptops with touchscreens)
	  KeyboardEnabled = false  → no physical keyboard attached
	  GamepadEnabled  = false  → no gamepad connected

	Using all three eliminates the most common false positives:
	  • Surface Pro / touchscreen laptop: TouchEnabled=true, KeyboardEnabled=true
	    → correctly identified as desktop.
	  • Phone with Bluetooth keyboard: TouchEnabled=true, KeyboardEnabled=true
	    → correctly identified as desktop (keyboard present → full quality).
	  • Tablet with no peripherals: TouchEnabled=true, KeyboardEnabled=false,
	    GamepadEnabled=false → correctly identified as mobile.

	The heuristic is intentionally conservative: it only downgrades to mobile
	quality when it is very confident the device is a phone or bare tablet.
	A false negative (phone treated as desktop) causes lag. A false positive
	(desktop treated as phone) silently removes visual features the player
	expected. Lag is worse, so the heuristic errs toward the desktop path.
]]

local UserInputService = game:GetService("UserInputService")

-- ── Module ────────────────────────────────────────────────────────────────────

local PerformanceController = {}
PerformanceController.Name = "PerformanceController"

-- ── Hardware Detection ────────────────────────────────────────────────────────

-- True when the player is on a phone or bare tablet.
-- Set once at load time; never changes during the session.
local isMobile: boolean = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
	and not UserInputService.GamepadEnabled

--- Publicly readable flag. Other modules require() this file and read IsMobile
--- directly — no framework dependency, no ordering concern.
PerformanceController.IsMobile = isMobile

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function PerformanceController:Init()
	if isMobile then
		print("[PerformanceController] Mobile device detected — reduced quality tier active.")
		print("  ComicShaderController: texture injection DISABLED")
		print("  VFXPool: pool sizes HALVED")
	else
		print("[PerformanceController] Desktop/console detected — full quality tier active.")
	end
end

function PerformanceController:Start() end

return PerformanceController
