--[[
    SkillService.luau
    Server-side handling for character skills.
    
    Responsibilities:
    - Validate skill requests (Cooldowns, Class checks)
    - Execute skill logic (Spawning projectiles, applying buffs)
    - Manage cooldown tracking
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SkillConfig = require(Shared:WaitForChild("Config"):WaitForChild("SkillConfig"))
local ClassService = require(script.Parent.ClassService)
-- Fix path: Skills is a sibling of Services folder, so go up to ServerScriptService
local SkillRegistry = require(script.Parent.Parent.Skills.SkillRegistry)

local SkillService = {
	Name = "SkillService",
}

-- Cooldown tracking: { [Player]: { [Slot]: tick() } }
local cooldowns = {}

--[[
    Get cooldown remaining for a skill
]]
local function getCooldownRemaining(player: Player, slot: string): number
	if not cooldowns[player] or not cooldowns[player][slot] then
		return 0
	end
	
	local className = ClassService:GetPlayerClass(player) or "Warrior"
	-- Map "Warrior" to "Vanguard" if config uses Vanguard
	if className == "Warrior" then className = "Vanguard" end
	if className == "Gunner" then className = "Gunslinger" end
	
	local classSkills = SkillConfig[className]
	if not classSkills or not classSkills[slot] then return 0 end
	
	local lastUse = cooldowns[player][slot]
	local cd = classSkills[slot].Cooldown
	local remaining = cd - (tick() - lastUse)
	
	return math.max(0, remaining)
end

--[[
    Execute the skill logic
]]
local function executeSkill(player: Player, className: string, slot: string, skillData: any, target: Model?, aimPos: Vector3?)
	print("[SkillService] Executing", skillData.Name, "for", player.Name)
	
	-- Auto-rotate removed per user request (Skills are directional)
	-- if aimPos and player.Character then ... end
	
	local handler = SkillRegistry[skillData.Name]
	if handler then
		-- Execute the specific skill logic
		task.spawn(function()
			handler(player, skillData, target, aimPos)
		end)
	else
		warn("No handler found for skill:", skillData.Name)
	end
end

--[[
    Handle skill request
]]
local function onRequestSkill(player: Player, slot: string, target: Model?, aimPos: Vector3?)
	print("[SkillService] Received request:", slot, "from", player.Name)
	-- Validate Class
	local className = ClassService:GetPlayerClass(player) or "Warrior"
	-- Map names to config
	local configName = className
	if className == "Warrior" then configName = "Vanguard" end
	if className == "Gunner" then configName = "Gunslinger" end
	
	print("[SkillService] Class:", className, "Mapped:", configName)
	
	local classSkills = SkillConfig[configName]
	if not classSkills or not classSkills[slot] then
		warn("Invalid skill slot:", slot, "for class:", configName)
		return
	end
	
	local skillData = classSkills[slot]
	
	-- Validate Cooldown
	local remaining = getCooldownRemaining(player, slot)
	if remaining > 0 then
		-- Tell client to sync cooldown
		local cdRemote = Remotes:GetEvent("SkillCooldown")
		if cdRemote then
			cdRemote:FireClient(player, slot, remaining)
		end
		return
	end
	
	-- Use Skill
	if not cooldowns[player] then cooldowns[player] = {} end
	cooldowns[player][slot] = tick()
	
	executeSkill(player, configName, slot, skillData, target, aimPos)
	
	-- Notify clients (for VFX)
	local usedRemote = Remotes:GetEvent("SkillUsed")
	if usedRemote then
		usedRemote:FireAllClients(player, slot, skillData)
	end
end

function SkillService:Init()
	Remotes:InitServer()
end

function SkillService:Start()
	local requestRemote = Remotes:GetEvent("RequestSkill")
	if requestRemote then
		requestRemote.OnServerEvent:Connect(onRequestSkill)
	end
	
	Players.PlayerRemoving:Connect(function(player)
		cooldowns[player] = nil
	end)
	
	print("[SkillService] Started")
end

return SkillService
