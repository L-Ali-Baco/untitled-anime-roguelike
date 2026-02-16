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
        Ground slam — heavy downward impact (Brute slam, boss stomp, etc.)
        Layers: Flash → Ground crack → Shockwave rings → Rock debris → Dust clouds → Screen shake
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
        Horizontal swing — weapon sweep arc (Brute hammer, boss sword, etc.)
        Layers: Trail ribbon arc → Wind particles → Ground dust → Small debris → Screen shake
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
}
