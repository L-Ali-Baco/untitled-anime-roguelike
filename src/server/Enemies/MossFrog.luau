--[[
	MossFrog.luau
	Nimble leaping melee enemy. Inherits from BaseEnemy.

	Custom behavior:
	  - Multi-attack system: Lunge, Slap, Slam, BogCharge (gap-closer)
	  - OnChaseOverride: triggers BogCharge when player is at mid-range
	    (reuses the same gap-closer pattern as Brute's Leap check)
	  - OnAttackEnter: picks weighted attack; delegates Charge type to _doChargeAttack

	Note: _doChargeAttack is defined in Brute.luau.
	MossFrog inherits it by pulling it up from Brute's prototype chain.
	If you want MossFrog to be fully standalone, copy Brute:_doChargeAttack here.
]]

local BaseEnemy = require(script.Parent.BaseEnemy)
local Brute = require(script.Parent.Brute) -- Inherits _doChargeAttack
local AIState = BaseEnemy.AIState

local MossFrog = setmetatable({}, { __index = Brute }) -- Brute → BaseEnemy chain
MossFrog.__index = MossFrog

function MossFrog.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "MossFrog", services)
	return setmetatable(self, MossFrog)
end

-- ── Weighted attack picker (local copy — same as Brute's) ──────────────

local function pickWeightedAttack(attacks: { any }, distance: number?): any?
	local eligible = {}
	for _, atk in attacks do
		local ok = true
		if distance then
			if atk.MinRange and distance < atk.MinRange then
				ok = false
			end
			if atk.MaxRange and distance > atk.MaxRange then
				ok = false
			end
		end
		if ok then
			table.insert(eligible, atk)
		end
	end
	if #eligible == 0 then
		eligible = attacks
	end

	local totalWeight = 0
	for _, atk in eligible do
		totalWeight += (atk.Weight or 1)
	end
	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, atk in eligible do
		cumulative += (atk.Weight or 1)
		if roll <= cumulative then
			return atk
		end
	end
	return eligible[1]
end

-- ── OnChaseOverride: BogCharge gap-closer ──────────────────────────────

function MossFrog:OnChaseOverride(targetPos: Vector3, distance: number): boolean
	local config = self.Config
	if not config.Attacks then
		return false
	end

	local now = os.clock()
	if now - self.LastAttackTime < (config.AttackCooldown or 3.0) then
		return false
	end

	for _, atk in config.Attacks do
		if atk.Type ~= "Charge" then
			continue
		end
		if not (atk.MinRange and atk.MaxRange) then
			continue
		end
		if distance < atk.MinRange or distance > atk.MaxRange then
			continue
		end

		local lastTime = self.LastSpecialTimes[atk.Name] or 0
		if now - lastTime < (atk.Cooldown or 16) then
			continue
		end

		if math.random() > (atk.Chance or 0.3) then
			self.LastSpecialTimes[atk.Name] = now - (atk.Cooldown or 16) + 1.0
			continue
		end

		self.State = AIState.Attack
		self.LastAttackTime = now
		self.LastSpecialTimes[atk.Name] = now
		self.AttackTriggered = false
		self.CurrentAttack = atk
		self:StopMovement()
		if self.WalkTrack and self.WalkTrack.IsPlaying then
			self.WalkTrack:Stop(0.15)
		end
		return true
	end

	return false
end

-- ── OnAttackEnter: pick weighted attack, dispatch by Type ──────────────

function MossFrog:OnAttackEnter()
	local config = self.Config
	local attackData = self.CurrentAttack

	if not attackData and config.Attacks then
		local targetPos = self:_getTargetPosition()
		local dist = if targetPos then (targetPos - self.RootPart.Position).Magnitude else nil
		attackData = pickWeightedAttack(config.Attacks, dist)
		self.CurrentAttack = attackData
	end

	if not attackData then
		self:_doStandardAttack(nil)
		return
	end

	if attackData.Type == "Charge" then
		self.State = AIState.ChargeAttack
		task.spawn(function()
			self:_doChargeAttack(attackData) -- inherited from Brute
		end)
	else
		self:_doStandardAttack(attackData)
	end
end

return MossFrog
