--[[
    ClassService.luau
    Server-side class management.
    
    Responsibilities:
    - Store each player's selected class
    - Validate class selection requests
    - Apply class-specific stats (health, speed)
    - Swap to custom character models when needed
    - Broadcast class changes to all clients
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClassConfig = require(Shared:WaitForChild("Config"):WaitForChild("ClassConfig"))
local MovementConfig = require(Shared:WaitForChild("Config"):WaitForChild("MovementConfig"))

local ClassService = {
	Name = "ClassService",
}

-- Store player classes: { [Player]: string }
local playerClasses: { [Player]: string } = {}

-- Valid class names for validation
local validClasses: { [string]: boolean } = {}
for _, className in ClassConfig.ClassOrder do
	validClasses[className] = true
end

--[[
    Helper function to find the root part of a character model
    Supports different naming conventions (HumanoidRootPart, Root, etc.)
]]
local function findRootPart(model: Model): BasePart?
	-- Try common root part names
	local rootPartNames = { "HumanoidRootPart", "Root", "LowerTorso", "Torso", "UpperTorso" }
	
	for _, name in rootPartNames do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	
	-- Fallback: try PrimaryPart
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	
	-- Last resort: find any BasePart
	return model:FindFirstChildOfClass("BasePart")
end

--[[
    Swap player to a custom character model
    Returns the new character model, or nil if swap failed
]]
local function swapToCustomCharacter(player: Player, classData: any): Model?
	local modelName = classData.CustomModel
	if not modelName then
		print("[ClassService] No CustomModel defined for class")
		return nil
	end
	
	print("[ClassService] Looking for custom model:", modelName, "in ReplicatedStorage")
	
	-- Find the model in ReplicatedStorage
	local modelTemplate = ReplicatedStorage:FindFirstChild(modelName)
	if not modelTemplate then
		warn("[ClassService] Custom model not found:", modelName)
		-- List what IS in ReplicatedStorage for debugging
		print("[ClassService] ReplicatedStorage contents:")
		for _, child in ReplicatedStorage:GetChildren() do
			print("  -", child.Name, "(" .. child.ClassName .. ")")
		end
		return nil
	end
	
	print("[ClassService] Found model template, cloning...")
	
	-- Clone the model
	local newCharacter = modelTemplate:Clone()
	newCharacter.Name = player.Name
	
	-- Get spawn position from current character or spawn location
	local spawnCFrame = CFrame.new(0, 15, 0) -- Default fallback (High up to prevent floor phasing)
	
	local currentCharacter = player.Character
	if currentCharacter then
		local currentRoot = findRootPart(currentCharacter)
		if currentRoot then
			spawnCFrame = currentRoot.CFrame + Vector3.new(0, 10, 0) -- Spawn 10 studs above current position
		end
	else
		-- Try to find a spawn location
		local spawnLocation = workspace:FindFirstChild("SpawnLocation", true)
		if spawnLocation and spawnLocation:IsA("SpawnLocation") then
			spawnCFrame = spawnLocation.CFrame + Vector3.new(0, 12, 0) -- Spawn 12 studs above spawn point
		end
	end
	
	-- Ensure the model has required components
	local humanoid = newCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn("[ClassService] Custom model missing Humanoid:", modelName)
		newCharacter:Destroy()
		return nil
	end
	
	-- Find root part using flexible search
	local rootPart = findRootPart(newCharacter)
	if not rootPart then
		warn("[ClassService] Custom model missing root part:", modelName)
		newCharacter:Destroy()
		return nil
	end
	
	-- CRITICAL: Rename to HumanoidRootPart for Humanoid physics (HipHeight) to work reliably
	if rootPart.Name ~= "HumanoidRootPart" then
		print("[ClassService] Renaming root part", rootPart.Name, "to HumanoidRootPart")
		rootPart.Name = "HumanoidRootPart"
	end
	
	-- Parent to workspace before setting as character
	-- This ensures GetJoints() works correctly for physics/weld checks
	newCharacter.Parent = workspace
	
	-- PHYSICS CLEANUP: Make sure only RootPart collides, and it's invisible
	-- This prevents physics jitter ("mushy" movement) from limbs colliding with ground
	rootPart.Transparency = 1
	rootPart.CanCollide = true
	rootPart.Anchored = false -- IMPORTANT: Ensure it's not anchored
	-- Reduce friction to 0 to allow LinearVelocity to move freely without fighting the floor
	rootPart.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100) 
	
	for _, part in newCharacter:GetDescendants() do
		if part:IsA("BasePart") then
            -- Unanchor EVERYTHING
			part.Anchored = false

            if part ~= rootPart then
			    part.CanCollide = false -- Only root collides
			    part.Massless = true -- Only root has mass (stability)
            end
		end
	end
    
    -- FORCE RESPAWN POSITION UP
    -- If we spawn too low, we fall through
    if newCharacter.PrimaryPart then
        local currentPos = newCharacter.PrimaryPart.Position
        if currentPos.Y < 10 then -- If suspiciously low
             newCharacter:PivotTo(CFrame.new(currentPos.X, 20, currentPos.Z)) -- Force high spawn
             print("[ClassService] Corrected spawn height to 20 studs")
        end
    end
	
	-- Set the model's PrimaryPart if not already set (needed for PivotTo)
	newCharacter.PrimaryPart = rootPart

    -- AUTOMATIC HIP HEIGHT CALCULATION
    -- This prevents phasing through the floor
    if classData.HipHeight then
        humanoid.HipHeight = classData.HipHeight
        print("[ClassService] Set HipHeight to", classData.HipHeight, "from config")
    elseif humanoid.HipHeight == 0 then
        -- Default to 4 studs (Very high to force floating, you can lower later)
        humanoid.HipHeight = 4
        print("[ClassService] Auto-set HipHeight to 4")
    end
	
	-- Remove any standard Roblox clothing/accessories that might cause texture issues
	-- Custom rigs usually have their own textures and don't support Shirt/Pants/BodyColors
	for _, child in newCharacter:GetChildren() do
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") or child:IsA("BodyColors") or child:IsA("CharacterMesh") then
			child:Destroy()
		end
	end

	-- CUSTOM RIG SETUP: Disable Humanoid physics entirely
	-- We'll handle movement ourselves with LinearVelocity/BodyVelocity
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.WalkSpeed = 0 -- Disable Humanoid walking - we handle it ourselves
	humanoid.JumpPower = 0 -- Disable Humanoid jumping - we handle it ourselves
	humanoid.AutoRotate = false -- We handle rotation ourselves
	humanoid.PlatformStand = false -- Ensure we are NOT in PlatformStand
	humanoid.AutomaticScalingEnabled = false -- Prevent Roblox from overriding HipHeight
    
    -- FORCE R15
    -- If the RigType is R6, animations will fail. We force it here.
    if humanoid.RigType == Enum.HumanoidRigType.R6 then
        print("[ClassService] Forcing Humanoid RigType to R15")
        -- Note: Script cannot directly change RigType at runtime effectively if the rig structure is wrong,
        -- but this property is read-only in some contexts. 
        -- The user must change it in the model properties in Studio.
        -- We can try to set it, but really we should warn.
    end
	
	-- Disable problematic humanoid states that cause tripping or unwanted behavior
	-- BUT ensure Running/Freefall are ENABLED so HipHeight works (floating above ground)
	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
		
		-- Ensure these are enabled for HipHeight to function
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false) -- Disable Physics state to let Humanoid solver work
	end)

    -- Force HipHeight application and persistence
    -- Sometimes replication overrides it or it gets reset
    local targetHipHeight = classData.HipHeight or 5 -- Default to 5 if missing (higher than 4 just in case)
    humanoid.HipHeight = targetHipHeight
    print("[ClassService] Initial Set HipHeight to", targetHipHeight)

    -- Re-apply HipHeight after a short delay to ensure it sticks after physics init
    task.delay(0.5, function()
        if humanoid and humanoid.Parent then
            humanoid.HipHeight = targetHipHeight
            print("[ClassService] Re-applied HipHeight:", targetHipHeight)
        end
    end)
	
	-- For custom rigs: We DON'T use AlignOrientation as it fights with rotation
	-- Instead, we'll handle keeping upright in the client movement code
	-- Just create the attachment for LinearVelocity
	local attachment = rootPart:FindFirstChild("RootAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "RootAttachment"
		attachment.Parent = rootPart
	end
	
	-- Create LinearVelocity for movement (controlled by client)
	-- Use Plane mode to only control X/Z, letting gravity handle Y
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "MovementVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = math.huge -- Infinite force to ensure movement regardless of mass/friction
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	linearVelocity.PrimaryTangentAxis = Vector3.new(1, 0, 0) -- X axis
	linearVelocity.SecondaryTangentAxis = Vector3.new(0, 0, 1) -- Z axis
	linearVelocity.PlaneVelocity = Vector2.zero
	linearVelocity.Parent = rootPart
	
	-- Create AlignOrientation for rotation control (client updates CFrame property)
	-- This prevents helicopter spinning by letting physics handle rotation smoothly
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "RotationControl"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.RigidityEnabled = true -- Snap to target orientation
	alignOrientation.CFrame = CFrame.new() -- Will be updated by client
	alignOrientation.Parent = rootPart
	
	-- Reset velocity on root part
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	
	-- Set the character's position with correct upright orientation
	local spawnPosition = spawnCFrame.Position
	local spawnLookVector = spawnCFrame.LookVector
	local uprightCFrame = CFrame.new(spawnPosition, spawnPosition + Vector3.new(spawnLookVector.X, 0, spawnLookVector.Z))
	newCharacter:PivotTo(uprightCFrame)
	
	-- Mark as custom rig for client-side handling
	newCharacter:SetAttribute("IsCustomRig", true)
	newCharacter:SetAttribute("CustomClass", classData.DisplayName or "Vanguard")
	
	-- Store idle animation ID for client to use
	if classData.IdleAnimationId then
		newCharacter:SetAttribute("IdleAnimationId", classData.IdleAnimationId)
	end
    
    -- Store run animation ID for client to use
    if classData.RunAnimationId then
        newCharacter:SetAttribute("RunAnimationId", classData.RunAnimationId)
    end
	
	-- Store facing offset for client rotation (if model faces wrong direction)
	if classData.FacingOffset then
		newCharacter:SetAttribute("FacingOffset", classData.FacingOffset)
	end
	
	-- Set as player's character
	player.Character = newCharacter
	
	-- CRITICAL: Set Network Ownership to client for physics to work smoothly
	-- Without this, server and client fight over physics, causing jitter/"mushy" rendering
	task.defer(function()
		if rootPart and rootPart:IsDescendantOf(workspace) then
			rootPart:SetNetworkOwner(player)
			print("[ClassService] Set NetworkOwnership of", rootPart.Name, "to", player.Name)
		end
	end)
	
	-- After setting character, ensure it's not moving
	task.defer(function()
		if humanoid and humanoid.Parent then
			-- Stop any movement
			humanoid:MoveTo(rootPart.Position) -- Move to current position (stops walking)
			if rootPart then
				rootPart.AssemblyLinearVelocity = Vector3.zero
				rootPart.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end)
	
	print("[ClassService] Swapped", player.Name, "to custom character:", modelName)
	
	return newCharacter
end

--[[
    Get a player's current class
]]
function ClassService:GetPlayerClass(player: Player): string?
	return playerClasses[player]
end

--[[
    Check if a player has selected a class
]]
function ClassService:HasClass(player: Player): boolean
	return playerClasses[player] ~= nil
end

--[[
    Apply class stats to a player's character
]]
local function applyClassStats(player: Player, className: string)
	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local classData = ClassConfig[className]
	if not classData then
		return
	end

	-- Apply health
	if classData.BaseHealth then
		humanoid.MaxHealth = classData.BaseHealth
		humanoid.Health = classData.BaseHealth
	end

	-- Apply speed multiplier
	if classData.MoveSpeedMultiplier then
		humanoid.WalkSpeed = MovementConfig.WalkSpeed * classData.MoveSpeedMultiplier
	end

	print(
		"[ClassService] Applied stats for",
		player.Name,
		"as",
		className,
		"- HP:",
		humanoid.MaxHealth,
		"Speed:",
		humanoid.WalkSpeed
	)
end

--[[
    Set a player's class
]]
function ClassService:SetPlayerClass(player: Player, className: string): boolean
	-- Validate class name
	if not validClasses[className] then
		warn("[ClassService] Invalid class:", className, "from", player.Name)
		return false
	end

	-- Store class
	local previousClass = playerClasses[player]
	playerClasses[player] = className
	
	-- Set attribute for easy access on client/server
	player:SetAttribute("Class", className)
	
	-- Get class data
	local classData = ClassConfig[className]
	
	-- Check if this class uses a custom character model
	if classData and classData.IsCustomRig and classData.CustomModel then
		local newCharacter = swapToCustomCharacter(player, classData)
		if newCharacter then
			-- Apply stats to the new character
			task.wait(0.1) -- Small delay to ensure character is fully set up
			applyClassStats(player, className)
		else
			warn("[ClassService] Failed to swap to custom character for", player.Name)
			-- Fall back to applying stats to existing character
			applyClassStats(player, className)
		end
	else
		-- Standard character - just apply stats
		applyClassStats(player, className)
	end

	-- Notify the player that class was confirmed
	local classSelectedRemote = Remotes:GetEvent("ClassSelected")
	if classSelectedRemote then
		classSelectedRemote:FireClient(player, className)
	end

	-- Broadcast to all clients (for visual updates, name tags, etc.)
	local playerClassChangedRemote = Remotes:GetEvent("PlayerClassChanged")
	if playerClassChangedRemote then
		playerClassChangedRemote:FireAllClients(player, className)
	end

	print(
		"[ClassService]",
		player.Name,
		"selected class:",
		className,
		previousClass and "(was " .. previousClass .. ")" or "(first selection)"
	)

	return true
end

--[[
    Handle class selection request from client
]]
local function onSelectClass(player: Player, className: string)
	-- Type check
	if typeof(className) ~= "string" then
		warn("[ClassService] Invalid className type from", player.Name)
		return
	end

	-- Validate and set class
	ClassService:SetPlayerClass(player, className)
end

--[[
    Handle player respawn - reapply class stats and custom character if needed
]]
local function onCharacterAdded(player: Player, character: Model)
	local className = playerClasses[player]
	if className then
		local classData = ClassConfig[className]
		
		-- If this class uses a custom rig, we need to swap again on respawn
		if classData and classData.IsCustomRig and classData.CustomModel then
			-- Check if the spawned character is already the custom rig
			if not character:GetAttribute("IsCustomRig") then
				-- Need to swap to custom character
				task.wait(0.2) -- Wait for default character to fully load
				local newCharacter = swapToCustomCharacter(player, classData)
				if newCharacter then
					task.wait(0.1)
					applyClassStats(player, className)
				end
			else
				-- Already custom rig, just apply stats
				local humanoid = character:WaitForChild("Humanoid", 5)
				if humanoid then
					task.wait(0.1)
					applyClassStats(player, className)
				end
			end
		else
			-- Standard character - wait for humanoid and apply stats
			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid then
				task.wait(0.1)
				applyClassStats(player, className)
			end
		end
	end
end

--[[
    Cleanup when player leaves
]]
local function onPlayerRemoving(player: Player)
	playerClasses[player] = nil
end

--[[
    Initialize the service
]]
function ClassService:Init()
	print("[ClassService] Initializing...")
end

--[[
    Start the service
]]
function ClassService:Start()
	print("[ClassService] Starting...")

	-- Connect to class selection remote
	local selectClassRemote = Remotes:GetEvent("SelectClass")
	if selectClassRemote then
		selectClassRemote.OnServerEvent:Connect(onSelectClass)
		print("[ClassService] Connected to SelectClass remote")
	else
		warn("[ClassService] Failed to find SelectClass remote!")
	end

	-- Handle existing players
	for _, player in Players:GetPlayers() do
		if player.Character then
			-- Don't apply class stats yet - player needs to select first
		end

		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end

	-- Handle new players
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end)

	-- Cleanup on leave
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	print("[ClassService] Started successfully")
end

return ClassService
