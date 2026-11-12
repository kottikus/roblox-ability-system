--!nonstrict
local Debris = game:GetService("Debris")

local AbilityConfig = {}

AbilityConfig.GlobalCooldown = 0.2 -- sec

-- slot ids are also the labels on the hotbar
AbilityConfig.SlotKeys = { "Q", "E", "R", "1", "2", "3", "4", "5", "6", "7", "8", "9" }

AbilityConfig.Resources = {
	Mana    = { Max = 100, Regen = 6,  Color = Color3.fromRGB(60, 130, 255) }, -- regen per sec
	Stamina = { Max = 100, Regen = 14, Color = Color3.fromRGB(80, 210, 110) },
}

-- fields: Type (Dash/AOE/Heal/SpeedBuff), Cooldown (sec), Cost + CostType (must exist in Resources),
-- NeedsAim, ClientFX (cosmetic only, return a cleanup fn)
-- OnCast = server override for one-offs. clients can read it tho, its replicatedstorage

local BURST_LIFETIME = Vector2.new(0.3, 0.7)
local BURST_CLEANUP = 1.2

local function burst(root: BasePart, color: Color3, count: number, speed: number?)
	local base = speed or 8
	local att = Instance.new("Attachment")
	att.Parent = root
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(color)
	pe.Lifetime = NumberRange.new(BURST_LIFETIME.X, BURST_LIFETIME.Y)
	pe.Speed = NumberRange.new(base, base * 1.8)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new(0.8, 0)
	pe.LightEmission = 1
	pe.Rate = 0
	pe.Parent = att
	pe:Emit(count)
	Debris:AddItem(att, BURST_CLEANUP)
	return function()
		att:Destroy()
	end
end

AbilityConfig.Abilities = {
	Dash = {
		DisplayName = "Dash",
		Type = "Dash",
		Cooldown = 4,
		Cost = 20,
		CostType = "Stamina",
		NeedsAim = true,
		Distance = 28, -- studs
		Duration = 0.22,
		Color = Color3.fromRGB(230, 230, 255),
		AnimationId = "", -- rbxassetid goes here
		ClientFX = function(ctx)
			return burst(ctx.root, Color3.fromRGB(220, 220, 255), 14, 14)
		end,
	},

	Fireball = {
		DisplayName = "Fireball",
		Type = "AOE",
		Cooldown = 6,
		Cost = 30,
		CostType = "Mana",
		NeedsAim = true,
		Range = 70,           -- studs
		Radius = 12,          -- studs
		Damage = 35,
		ProjectileSpeed = 90, -- studs/sec
		Burn = { Duration = 4, Damage = 5, Interval = 1 },
		Color = Color3.fromRGB(255, 120, 40),
		AnimationId = "",
		ClientFX = function(ctx)
			return burst(ctx.root, Color3.fromRGB(255, 130, 40), 20, 10)
		end,
	},

	Heal = {
		DisplayName = "Mend",
		Type = "Heal",
		Cooldown = 12,
		Cost = 40,
		CostType = "Mana",
		Amount = 30,
		Regen = { Duration = 5, PerTick = 4 },
		Color = Color3.fromRGB(90, 255, 140),
		AnimationId = "",
		ClientFX = function(ctx)
			return burst(ctx.root, Color3.fromRGB(110, 255, 150), 18, 5)
		end,
	},

	Haste = {
		DisplayName = "Haste",
		Type = "SpeedBuff",
		Cooldown = 15,
		Cost = 25,
		CostType = "Stamina",
		Duration = 6,
		Multiplier = 1.6,
		Color = Color3.fromRGB(255, 225, 80),
		AnimationId = "",
		ClientFX = function(ctx)
			return burst(ctx.root, Color3.fromRGB(255, 230, 90), 16, 6)
		end,
	},
}

return AbilityConfig