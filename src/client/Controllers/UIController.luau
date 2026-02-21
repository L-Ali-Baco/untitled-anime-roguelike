--[[
    UIController.luau
    Manages UI initialization and cleanup.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = require(ReplicatedStorage.Shared.Framework)

local UIController = Framework.CreateController({
	Name = "UIController",
})

local uiCleanupFunctions = {}
local uiInitialized = false

-- Class select screen reference
local classSelectScreen = nil

function UIController:Init()
	print("[UIController] Initializing...")
	-- Nothing specific in Init for now
end

function UIController:Start()
	print("[UIController] Starting...")

	local LocalPlayer = Players.LocalPlayer
	if LocalPlayer.Character then
		task.spawn(function()
			self:OnCharacterAdded(LocalPlayer.Character)
		end)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:OnCharacterAdded(character)
	end)
end

function UIController:OnCharacterAdded(character)
	-- Wait for humanoid to be ready
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		warn("[UIController] Humanoid not found")
		return
	end

	-- Small delay to ensure everything is loaded
	task.wait(0.1)

	-- Initialize UI
	self:InitializeUI()

	-- Show class selection if no class is selected
	local ClassController = Framework.GetController("ClassController")
	local InputController = Framework.GetController("InputController")

	if ClassController and not ClassController:IsClassSelected() then
		-- Show class select and block input
		self:ShowClassSelection()
	else
		-- Player already has a class, lock mouse for gameplay
		if InputController then
			InputController:LockMouse()
		end
	end
end

function UIController:InitializeUI()
	if uiInitialized then
		return
	end
	uiInitialized = true

	local InputController = Framework.GetController("InputController")
	if not InputController then
		warn("[UIController] InputController not found, skipping UI initialization")
		return
	end

	local StaminaController = Framework.GetController("StaminaController")
	local ClassController = Framework.GetController("ClassController")
	local StormController = Framework.GetController("StormController")
	local ItemController = Framework.GetController("ItemController")

	-- We need to require UI modules relative to the script location
	-- Wait, the script is in `src/client/Controllers`.
	-- The original script was in `src/client`.
	-- The UI folder is in `src/client/UI`.
	-- So `script.Parent.Parent.UI` works.
	local clientFolder = script.Parent.Parent
	local UI = clientFolder:WaitForChild("UI")

	-- Create virtual joystick for mobile (left side - movement)
	local VirtualJoystick = require(UI.Controls.VirtualJoystick)
	local cleanupJoystick = VirtualJoystick.new(InputController)
	table.insert(uiCleanupFunctions, cleanupJoystick)

	-- Create mobile camera control (right side - camera rotation)
	local MobileCameraControl = require(UI.Controls.MobileCameraControl)
	local cleanupCamera = MobileCameraControl.new(InputController)
	table.insert(uiCleanupFunctions, cleanupCamera)

	-- Create mobile action buttons (Attack, Dash, Jump)
	local MobileActionButtons = require(UI.Controls.MobileActionButtons)
	local cleanupButtons = MobileActionButtons.new(InputController)
	table.insert(uiCleanupFunctions, cleanupButtons)

	-- Create stamina bar HUD (all platforms)
	if StaminaController then
		local StaminaBar = require(UI.HUD.StaminaBar)
		local cleanupStaminaBar = StaminaBar.new(StaminaController)
		table.insert(uiCleanupFunctions, cleanupStaminaBar)
	end

	-- Create Heat Meter HUD (Scrapper only)
	local HeatMeter = require(UI.HUD.HeatMeter)
	local cleanupHeatMeter = HeatMeter.new()
	table.insert(uiCleanupFunctions, cleanupHeatMeter)

	-- Create Player Health Bar (Custom HUD)
	local PlayerHealthBar = require(UI.HUD.PlayerHealthBar)
	local cleanupHealthBar = PlayerHealthBar.new()
	table.insert(uiCleanupFunctions, cleanupHealthBar)

	-- Create Skill Bar (Cooldowns)
	local success, err = pcall(function()
		local SkillBar = require(UI.HUD.SkillBar)
		local cleanupSkillBar = SkillBar.new(ClassController)
		table.insert(uiCleanupFunctions, cleanupSkillBar)
	end)
	if not success then
		warn("[UIController] Failed to init SkillBar:", err)
	end

	-- Create Interaction Prompt (Context Button)
	local InteractionPrompt = require(UI.HUD.InteractionPrompt)
	local cleanupInteraction = InteractionPrompt.new()
	table.insert(uiCleanupFunctions, cleanupInteraction)

	-- Initialize enemy health bars (world-space UI)
	local EnemyHealthBar = require(UI.HUD.EnemyHealthBar)
	EnemyHealthBar:Init()

	-- Create Difficulty Indicator (Director System)
	if StormController then
		local DifficultyIndicator = require(UI.HUD.DifficultyIndicator)
		local cleanupDifficulty = DifficultyIndicator.new(StormController)
		table.insert(uiCleanupFunctions, cleanupDifficulty)
	end

	-- Create class select screen (hidden by default)
	if ClassController then
		local ClassSelectScreen = require(UI.Screens.ClassSelectScreen)
		classSelectScreen = ClassSelectScreen.new(ClassController, InputController)
		table.insert(uiCleanupFunctions, classSelectScreen.destroy)

		-- Safety: Listen to class selection to ensure input is always unblocked when a class is picked
		ClassController.OnClassSelected:Connect(function(className, classData)
			print("[UIController] Class selected:", className, "- ensuring input is unlocked")
			if InputController then
				InputController:LockMouse()
			end
			-- Hide class select screen if it's still visible
			if classSelectScreen and classSelectScreen.isVisible() then
				classSelectScreen.hide()
			end
		end)
	end

	print("[UIController] Mobile UI initialized")
end

function UIController:ShowClassSelection()
	if classSelectScreen then
		classSelectScreen.show()
	end
end

function UIController:CleanupUI()
	for _, cleanup in uiCleanupFunctions do
		cleanup()
	end
	table.clear(uiCleanupFunctions)
	uiInitialized = false
end

return UIController
