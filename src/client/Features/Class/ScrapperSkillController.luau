--[[
    ScrapperSkillController.luau
    Handles client-side logic specific to the Scrapper class.
    - Kinetic Scrubber (Passive) heat tracking
    - Trip-Wire Spool (Skill 1) input handling and visual prediction
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local ClassConfig = require(Shared:WaitForChild("Config"):WaitForChild("ClassConfig"))
local SkillConfig = require(Shared:WaitForChild("Config"):WaitForChild("SkillConfig"))

local ScrapperSkillController = {}
ScrapperSkillController.Name = "ScrapperSkillController"

local LocalPlayer = Players.LocalPlayer
local connections = {}

-- References to other controllers (set in Init)
local InputController = nil

-- State: Kinetic Scrubber
local heatCharge = 0
local maxHeat = ClassConfig.Scrapper.Skills.KineticScrubber.MaxHeat
local heatVfxAttachment = nil
local isOverheating = false
local overheatEndTime = 0

-- State: Trip-Wire
local isSpooling = false
local spoolStartPos = nil
local spoolWireVisual = nil
local skill1CooldownEnd = 0

--[[
    Update Kinetic Scrubber Heat
]]
local function updateHeat(deltaTime: number, rootPart: BasePart)
	local config = ClassConfig.Scrapper.Skills.KineticScrubber
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	if isOverheating then
		-- Lock heat at max during the 5-second buff window
		heatCharge = maxHeat

		-- Check if the buff window has expired
		if tick() >= overheatEndTime then
			isOverheating = false
			heatCharge = 0
			LocalPlayer:SetAttribute("HeatCharge", 0)
			LocalPlayer:SetAttribute("HeatResetTime", tick() + 2.5)
		end
	else
		-- Check if we are in the post-shred reset cooldown period
		local resetTime = LocalPlayer:GetAttribute("HeatResetTime") or 0
		if tick() < resetTime then
			heatCharge = 0
			LocalPlayer:SetAttribute("HeatCharge", 0)
			return
		end

		-- Adjust to scale by seconds
		if horizontalSpeed > 5 then
			-- Moving: Build heat
			heatCharge = math.min(maxHeat, heatCharge + (config.HeatPerTick * deltaTime * 10))
		else
			-- Idle: Decay heat
			heatCharge = math.max(0, heatCharge - (config.DecayPerTick * deltaTime * 10))
		end

		-- Check if we just hit max heat
		if heatCharge >= maxHeat then
			isOverheating = true
			overheatEndTime = tick() + 5.0 -- 5 second duration
		end
	end

	-- Update attribute for CombatController and UI to read
	LocalPlayer:SetAttribute("HeatCharge", heatCharge)
end

--[[
    Creates or destroys the visual heat indicator on the character
]]
local function updateHeatVfx(rootPart: BasePart)
	if heatCharge >= maxHeat then
		if not heatVfxAttachment then
			heatVfxAttachment = Instance.new("Attachment")
			heatVfxAttachment.Name = "KineticHeatVfx"
			heatVfxAttachment.Parent = rootPart

			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 60, 20)
			light.Range = 12
			light.Brightness = 3
			light.Parent = heatVfxAttachment

			local sparks = Instance.new("ParticleEmitter")
			sparks.Color = ColorSequence.new(Color3.fromRGB(255, 60, 20), Color3.fromRGB(255, 100, 50))
			sparks.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(1, 0),
			})
			sparks.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			sparks.Speed = NumberRange.new(5, 15)
			sparks.Lifetime = NumberRange.new(0.3, 0.6)
			sparks.Rate = 25
			sparks.EmissionDirection = Enum.NormalId.Top
			sparks.Parent = heatVfxAttachment
		end
	else
		-- Heat is not max, destroy VFX if it exists
		if heatVfxAttachment then
			heatVfxAttachment:Destroy()
			heatVfxAttachment = nil
		end
	end
end

--[[
    Creates a temporary visual line for the trip-wire while spooling
]]
local function updateSpoolVisual(rootPart: BasePart)
	if not isSpooling or not spoolStartPos then
		if spoolWireVisual then
			spoolWireVisual:Destroy()
			spoolWireVisual = nil
		end
		return
	end

	-- Base position using a downward raycast from the character root
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { LocalPlayer.Character }

	local rayResult = Workspace:Raycast(rootPart.Position, Vector3.new(0, -100, 0), rayParams)
	local groundPos = rootPart.Position - Vector3.new(0, 2.5, 0)
	if rayResult then
		groundPos = rayResult.Position
	end

	-- Apply the exact same visual height offset (+1.8) as the final server mine cable
	local currentPos = groundPos + Vector3.new(0, 1.8, 0)
	local distance = (currentPos - spoolStartPos).Magnitude
	local maxWireLength = SkillConfig.Scrapper.Skill1.MaxWireLength

	if not spoolWireVisual then
		spoolWireVisual = Instance.new("Part")
		spoolWireVisual.Name = "SpoolVisualPreview"
		spoolWireVisual.Anchored = true
		spoolWireVisual.CanCollide = false
		spoolWireVisual.CanQuery = false
		spoolWireVisual.Material = Enum.Material.Neon
		spoolWireVisual.Color = Color3.fromRGB(255, 100, 100)
		spoolWireVisual.Transparency = 0.5
		spoolWireVisual.Parent = Workspace
	end

	-- Position the laser between start and current positions
	if distance > 0.1 then
		spoolWireVisual.Size = Vector3.new(0.1, 0.1, distance)
		spoolWireVisual.CFrame = CFrame.lookAt(spoolStartPos, currentPos) * CFrame.new(0, 0, -distance / 2)
	else
		spoolWireVisual.Size = Vector3.new(0.1, 0.1, 0.1)
		spoolWireVisual.CFrame = CFrame.new(currentPos)
	end

	-- Check auto-lock distance limit
	if distance >= maxWireLength then
		print("[ScrapperSkillController] Hit Max Length:", maxWireLength, ". Auto-ending.")
		ScrapperSkillController:EndTripWire(rootPart)
	end
end

--[[
    Handles Skill 1 Press (Trip-Wire)
]]
local function onSkill1Pressed()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	if not isSpooling then
		-- Check cooldown before allowing start
		if tick() < skill1CooldownEnd then
			return
		end

		-- Raycast to find the exact starting floor node position
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { character }

		local shootPos = rootPart.Position - Vector3.new(0, 2.5, 0)
		local rayResult = Workspace:Raycast(rootPart.Position, Vector3.new(0, -100, 0), rayParams)
		if rayResult then
			shootPos = rayResult.Position
		end

		-- Start Spooling
		isSpooling = true
		LocalPlayer:SetAttribute("TripWireSpooling", true)
		-- The server laser aims 1.8 studs OFF the exact ground hit, so we store this
		-- specifically as the starting CFrame calculation anchor
		spoolStartPos = shootPos + Vector3.new(0, 1.8, 0)

		-- Tell server to start (we send the raw ground impact position)
		local requestSkill = Remotes:GetEvent("RequestSkill")
		if requestSkill then
			-- Using slot 'Skill1'. Server will receive this and spawn the start node.
			requestSkill:FireServer("Skill1", nil, shootPos)
		end
	else
		-- End Spooling
		ScrapperSkillController:EndTripWire(rootPart)
	end
end

--[[
    Finalize the Trip-Wire placement
]]
function ScrapperSkillController:EndTripWire(rootPart: BasePart?)
	if not isSpooling then
		return
	end

	local endPos = spoolStartPos
	if rootPart then
		-- Raycast to find the exact ending floor node position
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { rootPart.Parent }

		local shootPos = rootPart.Position - Vector3.new(0, 2.5, 0)
		local rayResult = Workspace:Raycast(rootPart.Position, Vector3.new(0, -100, 0), rayParams)
		if rayResult then
			shootPos = rayResult.Position
		end
		endPos = shootPos
	end

	isSpooling = false
	LocalPlayer:SetAttribute("TripWireSpooling", false)

	if spoolWireVisual then
		spoolWireVisual:Destroy()
		spoolWireVisual = nil
	end

	print("[ScrapperSkillController] Ending Trip-Wire. Requesting server EndNode at:", endPos)
	-- Tell Server to finish spooling
	local requestSkill = Remotes:GetEvent("RequestSkill")
	if requestSkill then
		-- Re-fire Skill1, and the server's ScrapperSkills logic will know this is the "End" call
		requestSkill:FireServer("Skill1", nil, endPos)
	end
	spoolStartPos = nil
end

function ScrapperSkillController:Init()
	InputController = require(script.Parent.Parent.Parent.Core.InputController)
	print("[ScrapperSkillController] Initialized")
end

function ScrapperSkillController:Start()
	-- Only run if we are the Scrapper
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt)
			local character = LocalPlayer.Character
			if not character then
				return
			end

			-- Check current class
			local currentClass = LocalPlayer:GetAttribute("Class")
			if currentClass ~= "Scrapper" then
				return
			end

			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if rootPart then
				updateHeat(dt, rootPart)
				updateHeatVfx(rootPart)
				updateSpoolVisual(rootPart)
			end
		end)
	)

	table.insert(
		connections,
		InputController.OnSkill1Pressed:Connect(function()
			local currentClass = LocalPlayer:GetAttribute("Class")
			if currentClass == "Scrapper" then
				onSkill1Pressed()
			end
		end)
	)

	table.insert(
		connections,
		LocalPlayer.CharacterAdded:Connect(function()
			heatCharge = 0
			LocalPlayer:SetAttribute("HeatCharge", 0)
			isOverheating = false
			overheatEndTime = 0
			if heatVfxAttachment then
				heatVfxAttachment:Destroy()
				heatVfxAttachment = nil
			end
			isSpooling = false
			spoolStartPos = nil
			if spoolWireVisual then
				spoolWireVisual:Destroy()
				spoolWireVisual = nil
			end
		end)
	)

	-- Listen for bonus heat from abilities
	local addHeatRemote = Remotes:GetEvent("AddScrapperHeat")
	if addHeatRemote then
		table.insert(
			connections,
			addHeatRemote.OnClientEvent:Connect(function(amount: number)
				local currentClass = LocalPlayer:GetAttribute("Class")
				if currentClass == "Scrapper" and not isOverheating then
					-- Check if we are in cooldown
					local resetTime = LocalPlayer:GetAttribute("HeatResetTime") or 0
					if tick() >= resetTime then
						local maxHeat = ClassConfig.Scrapper.Skills.KineticScrubber.MaxHeat
						heatCharge = math.min(maxHeat, heatCharge + amount)
						if heatCharge >= maxHeat then
							isOverheating = true
							overheatEndTime = tick() + 5.0
						end
						LocalPlayer:SetAttribute("HeatCharge", heatCharge)
					end
				end
			end)
		)
	end

	-- Track Skill 1 Cooldown
	local usedRemote = Remotes:GetEvent("SkillUsed")
	if usedRemote then
		table.insert(
			connections,
			usedRemote.OnClientEvent:Connect(function(player, slot, data)
				if player == LocalPlayer and slot == "Skill1" then
					skill1CooldownEnd = tick() + data.Cooldown
				end
			end)
		)
	end

	local cdRemote = Remotes:GetEvent("SkillCooldown")
	if cdRemote then
		table.insert(
			connections,
			cdRemote.OnClientEvent:Connect(function(slot, remaining)
				if slot == "Skill1" then
					skill1CooldownEnd = tick() + remaining
				end
			end)
		)
	end

	print("[ScrapperSkillController] Started")
end

function ScrapperSkillController:Destroy()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	if spoolWireVisual then
		spoolWireVisual:Destroy()
	end
	if heatVfxAttachment then
		heatVfxAttachment:Destroy()
		heatVfxAttachment = nil
	end
end

return ScrapperSkillController
