--[[
    Client Bootstrapper
    Initializes and starts all client controllers.
    
    Controllers are loaded in two phases:
    1. Init - Setup, can reference other controllers but not use them
    2. Start - All controllers ready, safe to use each other
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- Wait for essential services
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

print("[Client] Starting...")

-- Store all controllers
local controllers = {}

--[[
    Recursively load all controllers from a folder
]]
local function loadControllersFromFolder(folder: Instance, path: string)
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and child.Name:match("Controller$") then
			local success, result = pcall(function()
				return require(child)
			end)

			if success then
				local name = result.Name or child.Name
				controllers[name] = result
				print("[Client] Loaded controller:", name)
			else
				warn("[Client] Failed to load controller:", child.Name, result)
			end
		elseif child:IsA("Folder") then
			loadControllersFromFolder(child, path .. "/" .. child.Name)
		end
	end
end

-- Load Core controllers
local coreFolder = script:WaitForChild("Core")
loadControllersFromFolder(coreFolder, "Core")

-- Load Feature controllers
local featuresFolder = script:WaitForChild("Features")
loadControllersFromFolder(featuresFolder, "Features")

-- Load VFX controllers
local vfxFolder = script:WaitForChild("VFX")
loadControllersFromFolder(vfxFolder, "VFX")

-- Phase 1: Init all controllers
print("[Client] Initializing controllers...")
for name, controller in controllers do
	if controller.Init then
		local success, err = pcall(function()
			controller:Init()
		end)

		if not success then
			warn("[Client] Failed to init controller:", name, err)
		end
	end
end

-- Phase 2: Start all controllers
print("[Client] Starting controllers...")
for name, controller in controllers do
	if controller.Start then
		task.spawn(function()
			local success, err = pcall(function()
				controller:Start()
			end)

			if not success then
				warn("[Client] Failed to start controller:", name, err)
			end
		end)
	end
end

-- Store UI cleanup functions
local uiCleanupFunctions = {}
local uiInitialized = false

-- Class select screen reference
local classSelectScreen = nil

-- Initialize UI after controllers are ready
local function initializeUI()
	-- Only initialize once
	if uiInitialized then
		return
	end
	uiInitialized = true

	local InputController = controllers["InputController"]
	if not InputController then
		warn("[Client] InputController not found, skipping UI initialization")
		return
	end

	local StaminaController = controllers["StaminaController"]
	local ClassController = controllers["ClassController"]

	-- Create virtual joystick for mobile (left side - movement)
	local VirtualJoystick = require(script.UI.Controls.VirtualJoystick)
	local cleanupJoystick = VirtualJoystick.new(InputController)
	table.insert(uiCleanupFunctions, cleanupJoystick)

	-- Create mobile camera control (right side - camera rotation)
	local MobileCameraControl = require(script.UI.Controls.MobileCameraControl)
	local cleanupCamera = MobileCameraControl.new(InputController)
	table.insert(uiCleanupFunctions, cleanupCamera)

	-- Create mobile action buttons (Attack, Dash, Jump)
	local MobileActionButtons = require(script.UI.Controls.MobileActionButtons)
	local cleanupButtons = MobileActionButtons.new(InputController)
	table.insert(uiCleanupFunctions, cleanupButtons)

	-- Create stamina bar HUD (all platforms)
	if StaminaController then
		local StaminaBar = require(script.UI.HUD.StaminaBar)
		local cleanupStaminaBar = StaminaBar.new(StaminaController)
		table.insert(uiCleanupFunctions, cleanupStaminaBar)
	end
	
	-- Create Player Health Bar (Custom HUD)
	local PlayerHealthBar = require(script.UI.HUD.PlayerHealthBar)
	local cleanupHealthBar = PlayerHealthBar.new()
	table.insert(uiCleanupFunctions, cleanupHealthBar)
	
	-- Create Skill Bar (Cooldowns)
	local success, err = pcall(function()
		local SkillBar = require(script.UI.HUD.SkillBar)
		local cleanupSkillBar = SkillBar.new(ClassController)
		table.insert(uiCleanupFunctions, cleanupSkillBar)
	end)
	if not success then
		warn("[Client] Failed to init SkillBar:", err)
	end

	-- Create Interaction Prompt (Context Button)
	local InteractionPrompt = require(script.UI.HUD.InteractionPrompt)
	local cleanupInteraction = InteractionPrompt.new()
	table.insert(uiCleanupFunctions, cleanupInteraction)

	-- Initialize enemy health bars (world-space UI)
	local EnemyHealthBar = require(script.UI.HUD.EnemyHealthBar)
	EnemyHealthBar:Init()

	-- Initialize Item Controller
	local ItemController = controllers["ItemController"]
	if ItemController then
		-- Any special init for items
	end

	-- Create Difficulty Indicator (Director System)
	local StormController = controllers["StormController"]
	if StormController then
		local DifficultyIndicator = require(script.UI.HUD.DifficultyIndicator)
		local cleanupDifficulty = DifficultyIndicator.new(StormController)
		table.insert(uiCleanupFunctions, cleanupDifficulty)
	end

	-- Create class select screen (hidden by default)
	if ClassController then
		local ClassSelectScreen = require(script.UI.Screens.ClassSelectScreen)
		classSelectScreen = ClassSelectScreen.new(ClassController, InputController)
		table.insert(uiCleanupFunctions, classSelectScreen.destroy)
	end

	print("[Client] Mobile UI initialized")

	-- Safety: Listen to class selection to ensure input is always unblocked when a class is picked
	if ClassController then
		ClassController.OnClassSelected:Connect(function(className, classData)
			print("[Client] Class selected:", className, "- ensuring input is unlocked")
			if InputController then
				InputController:LockMouse()
			end
			-- Hide class select screen if it's still visible
			if classSelectScreen and classSelectScreen.isVisible() then
				classSelectScreen.hide()
			end
		end)
	end
end

-- Show class selection screen
local function showClassSelection()
	if classSelectScreen then
		classSelectScreen.show()
	end
end

-- Cleanup UI
local function cleanupUI()
	for _, cleanup in uiCleanupFunctions do
		cleanup()
	end
	table.clear(uiCleanupFunctions)
	uiInitialized = false
end

-- Wait for character then initialize UI
local function onCharacterAdded(character: Model)
	-- Wait for humanoid to be ready
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		warn("[Client] Humanoid not found")
		return
	end

	-- Small delay to ensure everything is loaded
	task.wait(0.1)

	-- Initialize UI
	initializeUI()

	-- Show class selection if no class is selected
	local ClassController = controllers["ClassController"]
	local InputController = controllers["InputController"]

	if ClassController and not ClassController:IsClassSelected() then
		-- Show class select and block input
		showClassSelection()
	else
		-- Player already has a class, lock mouse for gameplay
		if InputController then
			InputController:LockMouse()
		end
	end
end

-- Handle character
if LocalPlayer.Character then
	task.spawn(onCharacterAdded, LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

print("[Client] Bootstrap complete!")
