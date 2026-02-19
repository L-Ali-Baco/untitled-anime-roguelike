--[[
    GunslingerSkills.luau
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))
local EnemyLib = require(Shared:WaitForChild("Lib"):WaitForChild("EnemyLib"))
local CombatLib = require(Shared:WaitForChild("Lib"):WaitForChild("CombatLib"))

local GunslingerSkills = {}

--[[
    Buckshot Blast (M2)
    Shotgun spread
]]
function GunslingerSkills.BuckshotBlast(player: Player, skillData: any)
	print("[GunslingerSkills] Buckshot triggered")
	local character = player.Character
	if not character then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	local bulletCount = skillData.BulletCount or 5
	local spread = skillData.Spread or 25
	local damageMult = skillData.Damage or 0.6
	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local damagePerBullet = damageStat * damageMult

	local range = 40

	local origin = rootPart.Position + Vector3.new(0, 2, 0)
	local lookDir = rootPart.CFrame.LookVector

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	for i = 1, bulletCount do
		-- Random spread
		local spreadRad = math.rad(spread)
		local x = (math.random() - 0.5) * spreadRad
		local y = (math.random() - 0.5) * spreadRad
		local dir = (CFrame.new(Vector3.zero, lookDir) * CFrame.Angles(x, y, 0)).LookVector

		local result = workspace:Raycast(origin, dir * range, rayParams)
		if result and result.Instance then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			if model then
				-- Validate target is enemy
				if
					CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag)
					or CollectionService:HasTag(model, "TrainingDummy")
				then
					if EnemyLib:IsAlive(model) then
						print(" - Buckshot hit:", model.Name)
						EnemyLib:TakeDamage(model, damagePerBullet)
						-- Knockback
						local enemyRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
						if enemyRoot then
							enemyRoot.AssemblyLinearVelocity = dir * 30
						end
					end
				end
			end
		end
	end
end

--[[
    Tether Mine (E)
]]
function GunslingerSkills.TetherMine(player: Player, skillData: any)
	print("[GunslingerSkills] Tether Mine triggered")
	-- Spawn Mine Part
	local character = player.Character
	local rootPart = character.HumanoidRootPart

	local mine = Instance.new("Part")
	mine.Size = Vector3.new(2, 0.5, 2)
	mine.Position = rootPart.Position + rootPart.CFrame.LookVector * 5
	mine.Anchored = true
	mine.CanCollide = false
	mine.CanQuery = false -- Fix: Don't block raycasts
	mine.CanTouch = false -- Fix: Don't trigger touches
	mine.Color = Color3.fromRGB(255, 100, 0)
	mine.Material = Enum.Material.Neon
	mine.Parent = workspace

	-- Arm delay
	task.delay(1, function()
		if not mine.Parent then
			return
		end

		-- Explode/Pull
		local radius = skillData.Radius or 25
		local pullForce = skillData.PullForce or 50

		local center = mine.Position

		-- Find enemies
		local enemies = CombatLib.getEnemiesInRadius(center, radius, { character })

		for _, model in enemies do
			local eRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if EnemyLib:IsAlive(model) and eRoot then
				-- Pull logic
				local dir = (center - eRoot.Position).Unit
				eRoot.AssemblyLinearVelocity = dir * pullForce + Vector3.new(0, 10, 0)

				-- Damage
				local baseDamage = 10
				local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
				EnemyLib:TakeDamage(model, damageStat * skillData.Damage)
			end
		end

		mine:Destroy()
	end)
end

--[[
    Overclock (R)
]]
function GunslingerSkills.Overclock(player: Player, skillData: any)
	print("[GunslingerSkills] Overclock triggered")
	local character = player.Character
	if not character then
		return
	end

	character:SetAttribute("Buff_Overclock", true)

	task.delay(skillData.Duration, function()
		if character then
			character:SetAttribute("Buff_Overclock", nil)
		end
	end)
end

return GunslingerSkills
