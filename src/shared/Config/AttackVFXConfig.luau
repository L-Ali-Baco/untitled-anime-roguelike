--[[
    AttackVFXConfig.luau
    Data-driven VFX definitions for attack effects.
    
    To add VFX for a new attack type, add a new entry to this table.
    The AttackVFXPlayer module reads these configs to play effects.
    
    Each config defines the layers of VFX that compose the full effect.
    Placed in shared/Config so both client and server can reference type names.
]]

return {
	--[[
        Ground slam -- heavy downward impact (Brute slam, boss stomp, etc.)
        Layers: Flash, Ground crack, Shockwave rings, Rock debris, Dust clouds, Screen shake
    ]]
	Slam = {
		Radius = 18,

		-- Bright hemisphere flash at impact point
		ImpactFlash = {
			Shape = Enum.PartType.Ball,
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 180, 80),
			Transparency = 0.1,
			StartSize = Vector3.new(4, 4, 4),
			TweenTo = { Size = Vector3.new(10, 6, 10), Transparency = 1 },
			TweenDuration = 0.15,
			Lifetime = 0.2,
		},

		-- Dark flat disc on the ground (persists briefly)
		GroundCrack = {
			Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(30, 25, 20),
			Transparency = 0.3,
			StartSize = Vector3.new(0.15, 1, 1),
			ExpandDuration = 0.1,
			HoldTime = 0.8,
			FadeDuration = 1.0,
		},

		-- Expanding ring(s) flush with ground
		ShockwaveRings = {
			{
				Color = Color3.fromRGB(255, 120, 40),
				StartSize = Vector3.new(1.5, 3, 3),
				HeightOffset = 0.2,
				Duration = 0.35,
				Lifetime = 0.4,
				Delay = 0,
			},
			{
				Color = Color3.fromRGB(255, 200, 100),
				StartSize = Vector3.new(1, 2, 2),
				HeightOffset = 0.1,
				Duration = 0.4,
				Lifetime = 0.45,
				Delay = 0.05,
				Transparency = 0.3,
				RadiusMultiplier = 0.8,
			},
		},

		-- Physics rocks erupting from ground
		RockDebris = {
			Count = 8,
			SizeRange = { 1.5, 3.5 },
			ColorRange = { 45, 75, 40, 65, 35, 55 },
			LaunchUp = { 40, 70 },
			LaunchOut = { 15, 35 },
			SpawnRadius = { 1, 4 },
			FadeDelay = 0.8,
			FadeDuration = 0.4,
		},

		-- Dust particle bursts
		Dust = {
			-- Upward burst
			Up = {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 160, 130)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 110, 100)),
				}),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 3),
					NumberSequenceKeypoint.new(0.3, 6),
					NumberSequenceKeypoint.new(1, 8),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.2),
					NumberSequenceKeypoint.new(0.4, 0.5),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Lifetime = NumberRange.new(0.6, 1.2),
				Speed = NumberRange.new(15, 35),
				SpreadAngle = Vector2.new(30, 30),
				Drag = 4,
				RotSpeed = NumberRange.new(-60, 60),
				EmitCount = 25,
			},
			-- Ground-spreading
			Ground = {
				Color = ColorSequence.new(Color3.fromRGB(140, 130, 110)),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 2),
					NumberSequenceKeypoint.new(0.5, 5),
					NumberSequenceKeypoint.new(1, 7),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.3),
					NumberSequenceKeypoint.new(0.6, 0.6),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Lifetime = NumberRange.new(0.8, 1.5),
				Speed = NumberRange.new(10, 25),
				SpreadAngle = Vector2.new(180, 10),
				Drag = 6,
				RotSpeed = NumberRange.new(-30, 30),
				EmitCount = 20,
			},
			AttachmentLifetime = 2,
		},

		ScreenShake = {
			MaxDist = 50,
			MaxIntensity = 0.8,
			Duration = 0.25,
		},
	},

	--[[
        Horizontal swing -- weapon sweep arc (Brute hammer, boss sword, etc.)
        Layers: Trail ribbon arc, Wind particles, Ground dust, Small debris, Screen shake
    ]]
	Swing = {
		-- Trail arc parameters
		Trail = {
			Radius = 26,
			Duration = 0.25,
			StartAngle = -90, -- degrees, enemy's left
			EndAngle = 60, -- degrees, enemy's right
			PivotOffset = Vector3.new(0, -5, 0), -- below root part
			AttachmentSpacing = 2,
			Lifetime = 0.4,
			LightEmission = 0.8,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 150)),
				ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 180, 60)),
				ColorSequenceKeypoint.new(0.7, Color3.fromRGB(230, 100, 20)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 50, 10)),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.2),
				NumberSequenceKeypoint.new(0.8, 0.6),
				NumberSequenceKeypoint.new(1, 1),
			}),
			WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 1.2),
				NumberSequenceKeypoint.new(1, 0.3),
			}),
		},

		-- Swing center offset from enemy root
		CenterOffset = { Forward = 15, Down = 5 },

		-- Wind particle burst
		WindParticles = {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 120)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 140, 60)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 100, 40)),
			}),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.5),
				NumberSequenceKeypoint.new(0.3, 2.5),
				NumberSequenceKeypoint.new(1, 4),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(0.4, 0.4),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Lifetime = NumberRange.new(0.2, 0.6),
			Speed = NumberRange.new(15, 40),
			SpreadAngle = Vector2.new(60, 30),
			Drag = 4,
			RotSpeed = NumberRange.new(-80, 80),
			EmitCount = 20,
			AttachmentLifetime = 1,
		},

		-- Ground dust
		GroundDust = {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 160, 130)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 110, 95)),
			}),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 2),
				NumberSequenceKeypoint.new(0.4, 4),
				NumberSequenceKeypoint.new(1, 6),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(0.5, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Lifetime = NumberRange.new(0.4, 1.0),
			Speed = NumberRange.new(8, 25),
			SpreadAngle = Vector2.new(160, 15),
			Drag = 5,
			RotSpeed = NumberRange.new(-50, 50),
			EmitCount = 16,
			SecondPointOffset = 5, -- offset along swing direction for 2nd dust source
			SecondEmitCount = 10,
			AttachmentLifetime = 1.5,
		},

		-- Small pebbles
		SmallDebris = {
			Count = 3,
			SizeRange = { 0.5, 1.2 },
			ColorRange = { 50, 80, 45, 70, 40, 60 },
			LaunchUp = { 25, 45 },
			LaunchOut = { 10, 25 },
			SpawnRadius = { 1, 3 },
			FadeDelay = 0.7,
			FadeDuration = 0.3,
		},

		ScreenShake = {
			MaxDist = 45,
			MaxIntensity = 0.6,
			Duration = 0.18,
		},
	},

	--[[
        Leap wind-up -- dust swirling inward as Brute crouches to jump
    ]]
	LeapStart = {
		-- Dust sucked inward toward the enemy's feet (power gathering effect)
		Dust = {
			Up = {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(160, 140, 110)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 90, 75)),
				}),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 4),
					NumberSequenceKeypoint.new(0.5, 2),
					NumberSequenceKeypoint.new(1, 0.5),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.4),
					NumberSequenceKeypoint.new(0.6, 0.6),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Lifetime = NumberRange.new(0.8, 1.4),
				Speed = NumberRange.new(3, 8),
				SpreadAngle = Vector2.new(180, 30),
				Drag = 2,
				RotSpeed = NumberRange.new(-40, 40),
				EmitCount = 15,
			},
			AttachmentLifetime = 2,
		},

		-- Small ground crack from crouch force
		GroundCrack = {
			Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(40, 35, 30),
			Transparency = 0.4,
			StartSize = Vector3.new(0.1, 0.5, 0.5),
			ExpandDuration = 0.3,
			HoldTime = 1.5,
			FadeDuration = 0.8,
		},

		Radius = 8, -- Smaller radius for wind-up

		ScreenShake = {
			MaxDist = 30,
			MaxIntensity = 0.3,
			Duration = 0.4,
		},
	},

	--[[
        Leap slam landing -- enhanced slam (bigger and stronger than normal slam)
        The Brute crashes down from height, creating a massive impact
    ]]
	LeapSlam = {
		Radius = 24, -- Bigger than normal slam (18)

		ImpactFlash = {
			Shape = Enum.PartType.Ball,
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 200, 100),
			Transparency = 0,
			StartSize = Vector3.new(6, 6, 6),
			TweenTo = { Size = Vector3.new(16, 10, 16), Transparency = 1 },
			TweenDuration = 0.2,
			Lifetime = 0.25,
		},

		GroundCrack = {
			Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(25, 20, 15),
			Transparency = 0.2,
			StartSize = Vector3.new(0.2, 1, 1),
			ExpandDuration = 0.12,
			HoldTime = 1.2,
			FadeDuration = 1.5,
		},

		ShockwaveRings = {
			{
				Color = Color3.fromRGB(255, 140, 50),
				StartSize = Vector3.new(2, 4, 4),
				HeightOffset = 0.3,
				Duration = 0.4,
				Lifetime = 0.5,
				Delay = 0,
			},
			{
				Color = Color3.fromRGB(255, 220, 120),
				StartSize = Vector3.new(1.5, 3, 3),
				HeightOffset = 0.15,
				Duration = 0.5,
				Lifetime = 0.55,
				Delay = 0.08,
				Transparency = 0.2,
				RadiusMultiplier = 0.7,
			},
			{
				Color = Color3.fromRGB(200, 100, 30),
				StartSize = Vector3.new(1, 2, 2),
				HeightOffset = 0.1,
				Duration = 0.6,
				Lifetime = 0.65,
				Delay = 0.15,
				Transparency = 0.4,
				RadiusMultiplier = 0.5,
			},
		},

		RockDebris = {
			Count = 12, -- More rocks than normal slam
			SizeRange = { 2, 5 }, -- Bigger rocks
			ColorRange = { 40, 70, 35, 60, 30, 50 },
			LaunchUp = { 50, 90 }, -- Higher launch
			LaunchOut = { 20, 45 }, -- Further spread
			SpawnRadius = { 1, 5 },
			FadeDelay = 1.0,
			FadeDuration = 0.5,
		},

		Dust = {
			Up = {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 180, 150)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(130, 120, 105)),
				}),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 4),
					NumberSequenceKeypoint.new(0.3, 8),
					NumberSequenceKeypoint.new(1, 12),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.1),
					NumberSequenceKeypoint.new(0.3, 0.4),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Lifetime = NumberRange.new(0.8, 1.5),
				Speed = NumberRange.new(20, 45),
				SpreadAngle = Vector2.new(40, 40),
				Drag = 3,
				RotSpeed = NumberRange.new(-80, 80),
				EmitCount = 35,
			},
			Ground = {
				Color = ColorSequence.new(Color3.fromRGB(150, 140, 120)),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 3),
					NumberSequenceKeypoint.new(0.5, 7),
					NumberSequenceKeypoint.new(1, 10),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.2),
					NumberSequenceKeypoint.new(0.5, 0.5),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Lifetime = NumberRange.new(1.0, 2.0),
				Speed = NumberRange.new(15, 35),
				SpreadAngle = Vector2.new(180, 15),
				Drag = 5,
				RotSpeed = NumberRange.new(-40, 40),
				EmitCount = 30,
			},
			AttachmentLifetime = 3,
		},

		ScreenShake = {
			MaxDist = 60, -- Bigger shake range
			MaxIntensity = 1.0, -- Stronger shake
			Duration = 0.35,
		},
	},
}
