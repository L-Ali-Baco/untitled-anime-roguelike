--[[
    SkillController.luau
    Client-side skill input handling and feedback.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SkillConfig = require(Shared:WaitForChild("Config"):WaitForChild("SkillConfig"))

local SkillController = {
	Name = "SkillController",
}

-- References
local InputController = nil
local ClassController = nil
local SkillVFX = nil
local TargetingController = nil

-- Connections
local connections = {}

-- Local Cooldown Tracking (Prediction)
-- { [Slot]: endTime }
local localCooldowns = {}

--[[
    Play skill animation/VFX locally
]]
local function playLocalFeedback(slot)
	-- Find skill data
	local className = "Vanguard"
	if ClassController and ClassController:IsClassSelected() then
		local cls = ClassController:GetCurrentClass()
		if cls == "Warrior" then
			className = "Vanguard"
		else
			-- Use class name directly (BikerKing, etc.)
			className = cls
		end
	end

	local skills = SkillConfig[className]
	if not skills or not skills[slot] then
		return
	end
	local skillData = skills[slot]

	if SkillVFX then
		SkillVFX:PlaySkillEffect(Players.LocalPlayer, skillData)
	end
end

--[[
    Attempt to use a skill
]]
local function tryUseSkill(slot: string)
	if not ClassController then
		warn("SkillController: ClassController missing")
		return
	end

	if not ClassController:IsClassSelected() then
		warn("SkillController: No class selected")
		return
	end

	-- Check local cooldown
	local now = tick()
	local cdEnd = localCooldowns[slot] or 0
	if now < cdEnd then
		return
	end

	-- Send request (Target info removed/ignored as per directional change)
	local remote = Remotes:GetEvent("RequestSkill")
	if remote then
		remote:FireServer(slot)
	end

	-- PREDICT: Assume success for VFX feel
	playLocalFeedback(slot)
end

--[[
    Handle successful skill usage (from server)
]]
local function onSkillUsed(player, slot, skillData)
	if player == Players.LocalPlayer then
		-- Ensure local cooldown is synced
		localCooldowns[slot] = tick() + skillData.Cooldown

		-- VFX already played via prediction, or played by SkillVFX listening to remote
		-- We don't need to do anything else here for local player
	else
		-- Other player used skill
		-- SkillVFX handles this automatically
	end
end

--[[
    Handle cooldown sync (server rejected request)
]]
local function onSkillCooldown(slot, remaining)
	localCooldowns[slot] = tick() + remaining
end

function SkillController:Init()
	InputController = require(script.Parent.InputController)
	ClassController = require(script.Parent.Parent.Features.Class.ClassController)

	-- Try require optional modules
	pcall(function()
		TargetingController = require(script.Parent.Parent.Features.Combat.TargetingController)
	end)

	-- Try require VFX
	local success, result = pcall(function()
		return require(script.Parent.Parent.VFX.SkillVFX)
	end)
	if success then
		SkillVFX = result
	end

	print("[SkillController] Initialized")
end

function SkillController:Start()
	-- Input Listeners
	table.insert(
		connections,
		InputController.OnSecondaryPressed:Connect(function()
			tryUseSkill("Secondary")
		end)
	)

	table.insert(
		connections,
		InputController.OnSkill1Pressed:Connect(function()
			tryUseSkill("Skill1")
		end)
	)

	table.insert(
		connections,
		InputController.OnSkill2Pressed:Connect(function()
			tryUseSkill("Skill2")
		end)
	)

	-- Network Listeners
	local usedRemote = Remotes:GetEvent("SkillUsed")
	if usedRemote then
		table.insert(connections, usedRemote.OnClientEvent:Connect(onSkillUsed))
	end

	local cdRemote = Remotes:GetEvent("SkillCooldown")
	if cdRemote then
		table.insert(connections, cdRemote.OnClientEvent:Connect(onSkillCooldown))
	end

	print("[SkillController] Started")
end

return SkillController
