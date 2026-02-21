--[[
    ScrapperSkills.luau
    Trip-Wire Spool logic
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkillConfig = require(Shared:WaitForChild("Config"):WaitForChild("SkillConfig"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))

local CombatService = require(script.Parent.Parent.Services.CombatService)

local ScrapperSkills = {}

-- State tracking for Trip-Wires
local activeTripWires = {}

function ScrapperSkills.IsSpooling(player: Player): boolean
	return activeTripWires[player] ~= nil
end

local function spawnMineNode(pos: Vector3, name: string): Instance
	local template = ReplicatedStorage:FindFirstChild("ScrapperMine", true)
	local node
	if template then
		node = template:Clone()
		node.Name = name
		if node:IsA("Model") then
			-- Plant the mine slightly into the floor so it doesn't float
			node:PivotTo(CFrame.new(pos - Vector3.new(0, 0.4, 0)))
			for _, child in ipairs(node:GetDescendants()) do
				if child:IsA("BasePart") then
					child.Anchored = true
					child.CanCollide = false
				end
			end
		elseif node:IsA("BasePart") then
			node.CFrame = CFrame.new(pos - Vector3.new(0, 0.4, 0))
			node.Anchored = true
			node.CanCollide = false
		end
		node.Parent = Workspace
		return node
	else
		node = Instance.new("Part")
		node.Size = Vector3.new(1.5, 0.4, 1.5)
		node.Anchored = true
		node.CanCollide = false
		node.Material = Enum.Material.Metal
		node.Color = Color3.fromRGB(50, 50, 50)
		node.CFrame = CFrame.new(pos)
		node.Name = name
		node.Parent = Workspace
		return node
	end
end

function ScrapperSkills.TripWireSpool(player: Player, skillData: any, target: Model?, aimPos: Vector3?)
	local twState = activeTripWires[player]

	if not twState then
		-- Start spooling
		if not aimPos then
			return
		end

		-- Raycast straight down from the aim position to ensure it snaps to the floor
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { player.Character }

		-- Start the ray slightly above the aimPos in case they aimed exactly at the floor
		local rayResult = Workspace:Raycast(aimPos + Vector3.new(0, 2, 0), Vector3.new(0, -100, 0), rayParams)
		if rayResult then
			aimPos = rayResult.Position
		end

		local startNode = spawnMineNode(aimPos, "TripWireStartNode")

		activeTripWires[player] = {
			StartNode = startNode,
			StartPos = aimPos,
			StartTime = tick(),
		}
	else
		-- End spooling
		print("[ScrapperSkills] Received end spool request for", player.Name)
		if not aimPos then
			warn("[ScrapperSkills] aimPos is nil, dropping request")
			return
		end
		activeTripWires[player] = nil

		-- Raycast straight down from the aim position to ensure it snaps to the floor
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { player.Character }

		-- Start the ray slightly above the aimPos in case they aimed exactly at the floor
		local rayResult = Workspace:Raycast(aimPos + Vector3.new(0, 2, 0), Vector3.new(0, -100, 0), rayParams)
		if rayResult then
			aimPos = rayResult.Position
		end

		local startPos = twState.StartPos
		local distance = (aimPos - startPos).Magnitude

		-- Safety check on distance
		if distance > SkillConfig.Scrapper.Skill1.MaxWireLength + 5 then
			warn(
				"[ScrapperSkills] Trip-wire spool failed: Distance ("
					.. distance
					.. ") exceeded MaxWireLength ("
					.. SkillConfig.Scrapper.Skill1.MaxWireLength
					.. " + 5)"
			)
			twState.StartNode:Destroy()
			return
		end

		local endNode = spawnMineNode(aimPos, "TripWireEndNode")

		-- Raise the wire off the ground so it connects to the middle of the mine
		local wireStart = startPos + Vector3.new(0, 1.8, 0)
		local wireEnd = aimPos + Vector3.new(0, 1.8, 0)

		-- Make the wire look like the thick red/pink cables wrapped around the mine
		local wireVisual = Instance.new("Part")
		wireVisual.Shape = Enum.PartType.Cylinder
		wireVisual.Size = Vector3.new(distance, 0.15, 0.15) -- Cylinder dimensions are Length, Radius, Radius along X axis

		-- Cylinder's length is along the X axis, so we need to look at the target and then rotate 90 degrees on Y
		wireVisual.CFrame = CFrame.lookAt(wireStart, wireEnd)
			* CFrame.new(0, 0, -distance / 2)
			* CFrame.Angles(0, math.rad(90), 0)

		wireVisual.Anchored = true
		wireVisual.CanCollide = false
		wireVisual.Material = Enum.Material.Fabric -- To give it a matte, cable-like texture
		wireVisual.Color = Color3.fromRGB(200, 60, 60) -- Desaturated rusty red to match the mine's wire color
		wireVisual.Name = "TripWireLaser"
		wireVisual.Parent = Workspace

		-- Setup overlap params
		local wireParams = OverlapParams.new()
		wireParams.FilterType = Enum.RaycastFilterType.Exclude

		-- Heartbeat connection to check for enemies
		local connection
		connection = RunService.Heartbeat:Connect(function()
			-- Exclude players
			local ignoreList = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Character then
					table.insert(ignoreList, p.Character)
				end
			end
			wireParams.FilterDescendantsInstances = ignoreList

			-- Detect intersections
			local hitParts = workspace:GetPartBoundsInBox(wireVisual.CFrame, wireVisual.Size, wireParams)
			for _, part in ipairs(hitParts) do
				local hitModel = part:FindFirstAncestorOfClass("Model")
				if hitModel and EnemyLib:IsAlive(hitModel) then
					-- TRIP IT!
					connection:Disconnect()

					-- Trigger Explosion at the wire center
					local explosionPos = wireVisual.Position

					-- Trip Wire Detonation VFX
					local Debris = game:GetService("Debris")
					local TweenService = game:GetService("TweenService")

					local vfxPart = Instance.new("Part")
					vfxPart.Name = "TripWireExplosionVFX"
					vfxPart.Size = Vector3.new(1, 1, 1)
					vfxPart.Anchored = true
					vfxPart.CanCollide = false
					vfxPart.CanQuery = false
					vfxPart.CanTouch = false
					vfxPart.Transparency = 1
					vfxPart.Position = explosionPos
					vfxPart.Parent = Workspace

					-- Flash sphere (snappy neon pop)
					local flashSphere = Instance.new("Part")
					flashSphere.Shape = Enum.PartType.Ball
					flashSphere.Size = Vector3.new(2, 2, 2)
					flashSphere.Position = explosionPos
					flashSphere.Anchored = true
					flashSphere.CanCollide = false
					flashSphere.CanQuery = false
					flashSphere.Material = Enum.Material.Neon
					flashSphere.Color = Color3.fromRGB(255, 255, 220)
					flashSphere.Transparency = 0
					flashSphere.Parent = Workspace
					TweenService
						:Create(flashSphere, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
							Size = Vector3.new(14, 14, 14),
							Transparency = 1,
						})
						:Play()
					Debris:AddItem(flashSphere, 0.1)

					-- Shrapnel (the main visual - fast hot sparks that scatter and die)
					local shrapnel = Instance.new("ParticleEmitter")
					shrapnel.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					shrapnel.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 160)),
						ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 130, 30)),
						ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 40, 10)),
					})
					shrapnel.Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.6),
						NumberSequenceKeypoint.new(1, 0),
					})
					shrapnel.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.8, 0.3),
						NumberSequenceKeypoint.new(1, 1),
					})
					shrapnel.Lifetime = NumberRange.new(0.15, 0.35)
					shrapnel.Speed = NumberRange.new(60, 120)
					shrapnel.SpreadAngle = Vector2.new(360, 360)
					shrapnel.Acceleration = Vector3.new(0, -80, 0)
					shrapnel.LightEmission = 1
					shrapnel.RotSpeed = NumberRange.new(-400, 400)
					shrapnel.Parent = vfxPart
					shrapnel:Emit(50)

					-- Smoke puff (small, fades fast)
					local smoke = Instance.new("ParticleEmitter")
					smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
					smoke.Color = ColorSequence.new(Color3.fromRGB(50, 45, 40))
					smoke.Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 4),
						NumberSequenceKeypoint.new(1, 8),
					})
					smoke.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.5),
						NumberSequenceKeypoint.new(1, 1),
					})
					smoke.Lifetime = NumberRange.new(0.3, 0.5)
					smoke.Speed = NumberRange.new(8, 20)
					smoke.SpreadAngle = Vector2.new(360, 360)
					smoke.Drag = 8
					smoke.Rotation = NumberRange.new(0, 360)
					smoke.Parent = vfxPart
					smoke:Emit(10)

					-- Light flash
					local flash = Instance.new("PointLight")
					flash.Color = Color3.fromRGB(255, 200, 100)
					flash.Range = 35
					flash.Brightness = 25
					flash.Parent = vfxPart
					TweenService:Create(flash, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Brightness = 0,
					}):Play()

					Debris:AddItem(vfxPart, 1)

					-- Remove trap
					twState.StartNode:Destroy()
					endNode:Destroy()
					wireVisual:Destroy()

					-- AOE Damage
					local hitRadius = SkillConfig.Scrapper.Skill1.Radius
					local blastParams = OverlapParams.new()
					blastParams.FilterDescendantsInstances = ignoreList
					local blastParts = workspace:GetPartBoundsInRadius(explosionPos, hitRadius, blastParams)

					local hitEnemies = {}
					local enemiesStruck = 0

					for _, bPart in ipairs(blastParts) do
						local bModel = bPart:FindFirstAncestorOfClass("Model")
						if bModel and EnemyLib:IsAlive(bModel) and not hitEnemies[bModel] then
							hitEnemies[bModel] = true
							enemiesStruck += 1
							CombatService.ApplyDamage(
								player,
								bModel,
								"TripWire_" .. tostring(tick()),
								SkillConfig.Scrapper.Skill1.Damage,
								SkillConfig.Scrapper.Skill1.Knockback,
								false
							)

							local showDamageRemote =
								require(game:GetService("ReplicatedStorage").Shared.Remotes):GetEvent(
									"ShowDamageNumber"
								)
							if showDamageRemote then
								showDamageRemote:FireAllClients(bModel, SkillConfig.Scrapper.Skill1.Damage, "Skill")
							end
						end
					end

					if enemiesStruck > 0 then
						local addHeatEvent =
							require(game:GetService("ReplicatedStorage").Shared.Remotes):GetEvent("AddScrapperHeat")
						if addHeatEvent then
							addHeatEvent:FireClient(player, 50)
						end
					end

					break
				end
			end
		end)

		-- Auto destroy after 30 seconds
		task.delay(30, function()
			if connection.Connected then
				connection:Disconnect()
				twState.StartNode:Destroy()
				endNode:Destroy()
				wireVisual:Destroy()
			end
		end)
	end
end

-- Handled by DashController / CombatService
function ScrapperSkills.ScavengersSlide(player: Player) end

-- Passive handling
function ScrapperSkills.KineticScrubber(player: Player) end

return ScrapperSkills
