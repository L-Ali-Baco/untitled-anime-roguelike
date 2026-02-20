--[[
    Remotes.luau
    Centralized RemoteEvent and RemoteFunction definitions.
    Creates remotes on server, provides references on client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

-- Cache for folder and remotes
local folderCache: Folder? = nil
local eventCache: { [string]: RemoteEvent } = {}
local functionCache: { [string]: RemoteFunction } = {}

-- Remote names
local REMOTE_EVENTS = {
	-- Combat (Melee)
	"RequestAttack", -- Client -> Server: Request to deal melee damage
	"HitConfirmed", -- Server -> Client: Confirm hit for VFX
	"EnemyDied", -- Server -> Clients: Enemy was killed

	-- Combat (Ranged)
	"RequestRangedHit", -- Client -> Server: Request ranged damage (hitscan)
	"RangedHitConfirmed", -- Server -> Client: Confirm ranged hit for VFX

	-- Skill System
	"RequestSkill", -- Client -> Server: Request to use a skill (Slot: "Secondary", "Skill1", "Skill2")
	"SkillUsed", -- Server -> Clients: Skill successfully used (for VFX/Cooldowns)
	"SkillCooldown", -- Server -> Client: Skill failed/cooldown sync

	-- Enemy AI
	"EnemyAttack", -- Server -> Clients: Enemy attacked a player (for VFX)
	"EnemySpawned", -- Server -> Clients: New enemy spawned
	"EnemyStateChanged", -- Server -> Clients: Enemy state changed (for animations)

	-- Player State
	"IFrameStateChanged", -- Client -> Server: Player I-frame state changed (for dodge)
	"DamageBlocked", -- Server -> Client: Damage was blocked by I-frames (for VFX)

	-- World Objectives
	"BeaconStateChanged", -- Server -> All Clients: Beacon changed state (Active, Charging, Completed)
	"BeaconProgressUpdated", -- Server -> All Clients: Current charge percentage

	-- Loot System
	"GrantItem", -- Server -> Client: Notifies player of item gained
	"RequestOpenChest", -- Client -> Server: Request to open a loot chest
	"ChestSpawned", -- Server -> All Clients: Visual for chest appearing

	-- Class System
	"SelectClass", -- Client -> Server: Player selected a class
	"ClassSelected", -- Server -> Client: Confirm class selection
	"PlayerClassChanged", -- Server -> All Clients: Broadcast player's class (for visuals)

	-- Debug
	"DebugMessage", -- Server -> Client: Send debug message to display

	-- Director System ("The Storm")
	"DirectorDifficultyUpdate", -- Server -> Client: Difficulty sync
	"DirectorEventTriggered", -- Server -> Client: Event notification
	"DirectorHordeWarning", -- Server -> Client: Warning of incoming horde
}

local REMOTE_FUNCTIONS = {
	-- None yet, but structure is ready
}

--[[
    Initialize remotes (call from server)
]]
function Remotes:InitServer()
	-- Check for existing folder to ensure idempotency
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder then
		folderCache = folder
		return folder
	end

	-- Create Remotes folder
	folder = Instance.new("Folder")
	folder.Name = "Remotes"

	-- Create RemoteEvents
	for _, name in REMOTE_EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end

	-- Create RemoteFunctions
	for _, name in REMOTE_FUNCTIONS do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
	end

	folder.Parent = ReplicatedStorage
	folderCache = folder

	print("[Remotes] Server initialized")
	return folder
end

--[[
    Get remotes folder (wait for it on client)
]]
function Remotes:GetFolder()
	if folderCache then
		return folderCache
	end

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("Remotes")
		if not folder then
			return self:InitServer()
		end
		folderCache = folder
		return folder
	else
		local folder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if folder then
			folderCache = folder
		end
		return folder
	end
end

--[[
    Get a specific remote event
]]
function Remotes:GetEvent(name: string): RemoteEvent?
	local cached = eventCache[name]
	if cached then
		return cached
	end

	local folder = self:GetFolder()
	if folder then
		local remote = folder:FindFirstChild(name)
		if remote and remote:IsA("RemoteEvent") then
			eventCache[name] = remote
			return remote
		end
	end
	return nil
end

--[[
    Get a specific remote function
]]
function Remotes:GetFunction(name: string): RemoteFunction?
	local cached = functionCache[name]
	if cached then
		return cached
	end

	local folder = self:GetFolder()
	if folder then
		local remote = folder:FindFirstChild(name)
		if remote and remote:IsA("RemoteFunction") then
			functionCache[name] = remote
			return remote
		end
	end
	return nil
end

return Remotes
