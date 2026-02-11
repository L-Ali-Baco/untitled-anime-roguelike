--[[
    VanguardSkills.luau
    Implementation of Vanguard class skills.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local StatLib = require(Shared:WaitForChild("Lib"):WaitForChild("StatLib"))

local VanguardSkills = {}

-- Helper to find enemies
local function getEnemiesInRadius(position: Vector3, radius: number): { Model }
	local enemies = {}
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {} -- Exclude nothing initially (we filter later)
	
	local parts = workspace:GetPartBoundsInRadius(position, radius, overlapParams)
	local checked = {}
	
	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not checked[model] then
			checked[model] = true
			if CollectionService:HasTag(model, CombatConfig.Targeting.TargetTag) or CollectionService:HasTag(model, "TrainingDummy") then
				local hum = model:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					table.insert(enemies, model)
				end
			end
		end
	end
	
	return enemies
end

--[[
    Iron Will (M2)
    Gain Shield + Damage Buff
]]
function VanguardSkills.IronWill(player: Player, skillData: any)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	
	local shieldAmount = humanoid.MaxHealth * skillData.ShieldPercent
	local currentShield = character:GetAttribute("Shield") or 0
	character:SetAttribute("Shield", currentShield + shieldAmount)
	character:SetAttribute("MaxShield", humanoid.MaxHealth)
	
	-- Apply Damage Buff attribute
	character:SetAttribute("Buff_IronWill", true)
	
	-- Decay Logic
	task.delay(skillData.Duration, function()
		if character then
			character:SetAttribute("Shield", 0)
			character:SetAttribute("Buff_IronWill", nil)
		end
	end)
end

--[[
    Seismic Slam (E)
    AoE Knockup + Damage
]]
function VanguardSkills.SeismicSlam(player: Player, skillData: any)
	print("[VanguardSkills] Seismic Slam triggered by", player.Name)
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end
	
	local radius = skillData.Radius or 15
	local damageMult = skillData.Damage or 2.5
	local knockupForce = skillData.KnockupForce or 60
	
	-- Apply 50% Damage Resistance during jump
	character:SetAttribute("DamageResistance", 0.5)
	task.delay(1.5, function()
		if character then character:SetAttribute("DamageResistance", nil) end
	end)
	
	-- Determine Base Damage with StatLib scaling
	local baseDamage = 10 
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local totalDamage = damageStat * damageMult
	
	local enemies = getEnemiesInRadius(rootPart.Position, radius)
	print("[VanguardSkills] Seismic Slam found", #enemies, "enemies")
	
	for _, enemy in enemies do
		local hum = enemy:FindFirstChildOfClass("Humanoid")
		local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")
		
		if hum and enemyRoot then
			print(" - Hitting", enemy.Name, "for", totalDamage)
			-- Deal Damage
			hum:TakeDamage(totalDamage)
			
			-- Apply Knockup (Direct Velocity)
			local velocity = Vector3.new(0, knockupForce, 0)
			enemyRoot.AssemblyLinearVelocity = velocity
		end
	end
end

--[[
    Blade Storm (R)
    Rapid cone attacks with forward momentum
]]
function VanguardSkills.BladeStorm(player: Player, skillData: any)
	print("[VanguardSkills] Blade Storm triggered")
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	
	local duration = skillData.Duration or 1.5
	local hitCount = skillData.HitCount or 6
	local damageMult = skillData.Damage or 0.8
	local baseDamage = 10
	local damageStat = StatLib:GetStat(player, "Damage", baseDamage)
	local damagePerHit = damageStat * damageMult
	
	local interval = duration / hitCount
	
	-- Apply 30% Damage Resistance during spin
	character:SetAttribute("DamageResistance", 0.3)
	task.delay(duration, function()
		if character then character:SetAttribute("DamageResistance", nil) end
	end)
	
	-- Apply forward momentum (BodyVelocity)
	local bv = Instance.new("BodyVelocity")
	bv.Name = "SkillMomentum"
	bv.MaxForce = Vector3.new(10000, 0, 10000)
	bv.Velocity = rootPart.CFrame.LookVector * 16 -- Move at run speed
	bv.Parent = rootPart
	game.Debris:AddItem(bv, duration)
	
	-- Spawn a thread to perform hits
	task.spawn(function()
		for i = 1, hitCount do
			if not character or not character.Parent then break end
			
			-- Update momentum direction (if player turns)
			bv.Velocity = rootPart.CFrame.LookVector * 16
			
			-- Cone Check
			local forward = rootPart.CFrame.LookVector
			local enemies = getEnemiesInRadius(rootPart.Position, 20) -- Increased Range (was 15)
			
			for _, enemy in enemies do
				local enemyPos = enemy:GetPivot().Position
				local dir = (enemyPos - rootPart.Position).Unit
				local angle = math.acos(math.clamp(forward:Dot(dir), -1, 1)) 
				
				if angle < math.rad(80) then -- Increased Cone (was 60, now 80 degrees - very wide)
					local hum = enemy:FindFirstChildOfClass("Humanoid")
					if hum then
						hum:TakeDamage(damagePerHit)
						-- Small knockback
						local enemyRoot = enemy:FindFirstChild("HumanoidRootPart")
						if enemyRoot then
							enemyRoot.AssemblyLinearVelocity = dir * 15 + Vector3.new(0,5,0)
						end
					end
				end
			end
			
			task.wait(interval)
		end
	end)
end

return VanguardSkills
