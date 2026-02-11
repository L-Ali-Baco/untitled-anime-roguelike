--[[
    ItemConfig.luau
    Definitions for all roguelike items and their stats.
]]

export type ItemEffect = {
	Stat: string, -- "WalkSpeed", "JumpPower", "Damage", "AttackRate", "AirJumps", "StaminaRegen", "CritChance"
	Value: number, -- Flat value or multiplier
	Type: "Additive" | "Multiplier",
}

export type ItemProc = {
	Type: "OnHit" | "OnKill" | "OnCrit" | "OnDash" | "OnJump",
	Chance: number, -- 0-1
	Damage: number, -- % of base damage
	Radius: number?,
	Duration: number?,
	Id: string, -- Unique ID for logic handler (e.g., "ChainLightning")
}

export type Item = {
	Name: string,
	Description: string,
	Rarity: "Common" | "Rare" | "Epic" | "Legendary",
	Icon: string,
	Effects: { ItemEffect }?,
	Procs: { ItemProc }?,
	Tags: { string }?, -- "Cursed", "Unique", etc.
}

local ItemRegistry = {
	Rarities = {
		Common = Color3.fromRGB(200, 200, 200),
		Rare = Color3.fromRGB(80, 180, 255),
		Epic = Color3.fromRGB(180, 80, 255),
		Legendary = Color3.fromRGB(255, 200, 50),
	},

	Pool = {
		-- ==========================================
		-- PROC TIER (Combat Satisfaction)
		-- ==========================================
		StaticFilament = {
			Name = "Static Filament",
			Description = "15% Chance on hit to zap nearby enemies for 40% DMG.",
			Rarity = "Common",
			Icon = "rbxassetid://6031097903", -- Placeholder: Lightning
			Procs = {
				{ Type = "OnHit", Id = "ChainLightning", Chance = 0.15, Damage = 0.4, Radius = 20 }
			}
		},
		EchoBlade = {
			Name = "Echo Blade",
			Description = "Every 4th attack triggers a ghost swing.",
			Rarity = "Rare",
			Icon = "rbxassetid://6031097903", -- Placeholder: Sword
			-- Logic handled by CombatService counting attacks
			Tags = {"PassiveAttackCount"}, 
		},
		VolatileCasing = {
			Name = "Volatile Casing",
			Description = "Enemies explode on death for 150% DMG.",
			Rarity = "Common",
			Icon = "rbxassetid://6031097903", -- Placeholder: Bomb
			Procs = {
				{ Type = "OnKill", Id = "Explosion", Chance = 1.0, Damage = 1.5, Radius = 15 }
			}
		},
		VoidMagnet = {
			Name = "Void Magnet",
			Description = "Critical hits pull enemies in.",
			Rarity = "Rare",
			Icon = "rbxassetid://6031097903", -- Placeholder: Magnet
			Procs = {
				{ Type = "OnCrit", Id = "Vacuum", Chance = 1.0, Radius = 25 }
			}
		},

		-- ==========================================
		-- MOVEMENT TIER (Speed & Flow)
		-- ==========================================
		AfterimageCloak = {
			Name = "Afterimage Cloak",
			Description = "Dash leaves an explosive decoy.",
			Rarity = "Rare",
			Icon = "rbxassetid://6034287594",
			Procs = {
				{ Type = "OnDash", Id = "Decoy", Chance = 1.0, Damage = 2.0, Duration = 1.5 }
			}
		},
		JetstreamSandals = {
			Name = "Jetstream Sandals",
			Description = "Double jumping stuns enemies below you.",
			Rarity = "Epic",
			Icon = "rbxassetid://6034509993",
			Procs = {
				{ Type = "OnJump", Id = "GroundSlam", Chance = 1.0, Damage = 1.0, Radius = 20 }
			}
		},
		MomentumBattery = {
			Name = "Momentum Battery",
			Description = "Hits grant stacking movement speed.",
			Rarity = "Common",
			Icon = "rbxassetid://6031289529",
			-- Logic handled by CombatService adding buffs
			Tags = {"OnHitBuff"}, 
		},

		-- ==========================================
		-- GAME CHANGER TIER (Legendary)
		-- ==========================================
		GlassCannon = {
			Name = "Glass Cannon",
			Description = "Deal +200% Damage, but -90% Max Health.",
			Rarity = "Legendary",
			Icon = "rbxassetid://6031071053",
			Tags = {"Cursed"},
			Effects = {
				{ Stat = "Damage", Value = 2.0, Type = "Multiplier" }, -- +200% (3x total)
				{ Stat = "MaxHealth", Value = -0.9, Type = "Multiplier" }, -- -90% (0.1x total)
			}
		},
		HiveMind = {
			Name = "The Hive-Mind",
			Description = "Damage is delayed but dealt in a massive burst after 3s.",
			Rarity = "Legendary",
			Icon = "rbxassetid://6031097903",
			Tags = {"ReplaceDamageLogic"},
		},
		AuraOfTheTyrant = {
			Name = "Aura of the Tyrant",
			Description = "Replaces attacks with a giant autonomous spectral sword.",
			Rarity = "Legendary",
			Icon = "rbxassetid://6031097903",
			Tags = {"ReplaceM1"},
		},

		-- ==========================================
		-- STANDARD STATS
		-- ==========================================
		SwiftBoots = {
			Name = "Swift Boots",
			Description = "+15% Movement Speed",
			Rarity = "Common",
			Icon = "rbxassetid://6031289529",
			Effects = {
				{ Stat = "WalkSpeed", Value = 0.15, Type = "Multiplier" },
			},
		},
		WindWalker = {
			Name = "Wind Walker",
			Description = "+1 Extra Air Jump",
			Rarity = "Common",
			Icon = "rbxassetid://6034509993",
			Effects = {
				{ Stat = "AirJumps", Value = 1, Type = "Additive" },
			},
		},
		SharpWhetstone = {
			Name = "Sharp Whetstone",
			Description = "+10% Attack Damage",
			Rarity = "Common",
			Icon = "rbxassetid://6031071053",
			Effects = {
				{ Stat = "Damage", Value = 0.1, Type = "Multiplier" },
			},
		},
		LensMakersGlasses = {
			Name = "Lens Maker's Glasses",
			Description = "+10% Critical Strike Chance",
			Rarity = "Common",
			Icon = "rbxassetid://6031071053",
			Effects = {
				{ Stat = "CritChance", Value = 0.1, Type = "Additive" },
			},
		},
	},
}

--[[
    Get item definition by key
]]
function ItemRegistry.GetItem(key: string): Item?
	return ItemRegistry.Pool[key]
end

--[[
    Get all items of a specific rarity
]]
function ItemRegistry.GetItemsByRarity(rarity: string): { Item }
	local items = {}
	for _, item in pairs(ItemRegistry.Pool) do
		if item.Rarity == rarity then
			table.insert(items, item)
		end
	end
	return items
end

--[[
    Get random item key from weighted pool (placeholder logic)
]]
function ItemRegistry.GetRandomItemKey(): string
	local keys = {}
	for key, _ in pairs(ItemRegistry.Pool) do
		table.insert(keys, key)
	end
	return keys[math.random(#keys)]
end

return ItemRegistry
