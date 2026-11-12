--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Abilities")
local Config = require(Shared:WaitForChild("AbilityConfig"))
local StatusEffects = require(script.Parent:WaitForChild("StatusEffectManager"))

local LATENCY_LEEWAY = 0.12 -- client fires on ITS cd end, packet lands early/late
local BUCKET_MAX = 8
local BUCKET_REFILL = 4 -- per sec
local MIN_CAST_CD = 0.1
local REGEN_STEP = 0.2
local COVER_RAY_LIFT = 1.5 -- impacts usually on the floor
local FALLOFF_AT_EDGE = 0.5
local MAX_COORD = 1e6
local DASH_FORCE = 1e7
local MIN_AIM_DIST = 0.5
local MIN_PROJECTILE_TRAVEL = 0.05

local remotes = Shared:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = Shared
end

local function getRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end
local CastRequest = getRemote("CastRequest")
local CastResult = getRemote("CastResult")

local validSlot = {}
for _, k in Config.SlotKeys do
	validSlot[k] = true
end

-- [player] = { res, cooldowns, gcd, tokens, lastTok, owned, loadout }
local states = {}

local function publish(player, name, r)
	local v = math.floor(r.value + 0.5)
	if v ~= r.shown then -- dont spam attributes
		r.shown = v
		player:SetAttribute(name, v)
	end
end

local function getLive(player)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then return end
	return char, hum, root
end

local function reject(player, castId, reason, extra)
	CastResult:FireClient(player, castId, false, reason, extra)
end

local function canHurt(attacker: Player, victim: Model): boolean
	if victim:GetAttribute("Invulnerable") then return false end
	local vp = Players:GetPlayerFromCharacter(victim)
	if vp then
		if vp == attacker then return false end
		if attacker.Team and vp.Team == attacker.Team and not attacker.Neutral then return false end
	end
	return true
end

local function clampAim(from: Vector3, aim: Vector3, range: number): Vector3
	local off = aim - from
	if off.Magnitude > range then
		return from + off.Unit * range
	end
	return aim
end

local function explosionFx(center: Vector3, radius: number, color: Color3)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.3
	p.Size = Vector3.one * 2
	p.Position = center
	p.Parent = workspace
	TweenService:Create(p, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * radius * 2,
		Transparency = 1,
	}):Play()
	Debris:AddItem(p, 0.5)
end

local function explode(attacker: Player, srcChar: Model, def, center: Vector3)
	explosionFx(center, def.Radius, def.Color)
	if attacker.Parent ~= Players then return end -- left mid flight

	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = { srcChar }
	op.MaxParts = 200

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.RespectCanCollide = true

	local lifted = center + Vector3.yAxis * COVER_RAY_LIFT
	local seen = {}

	for _, part in workspace:GetPartBoundsInRadius(center, def.Radius, op) do
		local model = part:FindFirstAncestorOfClass("Model")
		if not model or seen[model] then continue end
		local hum = model:FindFirstChildOfClass("Humanoid")
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if not hum or not hrp or hum.Health <= 0 then continue end
		seen[model] = true
		if not canHurt(attacker, model) then continue end

		-- walls eat the blast
		rp.FilterDescendantsInstances = { srcChar, model }
		local toTarget = hrp.Position - lifted
		if workspace:Raycast(lifted, toTarget, rp) then continue end

		local falloff = 1 - FALLOFF_AT_EDGE * math.clamp(toTarget.Magnitude / def.Radius, 0, 1)
		hum:TakeDamage(def.Damage * falloff) -- todo kill credit if u add leaderboards

		if def.Burn then
			StatusEffects.Apply(model, "Burn", {
				Duration = def.Burn.Duration,
				DotDamage = def.Burn.Damage,
				Interval = def.Burn.Interval,
				Source = attacker,
			})
		end
	end
end

-- handlers return true, or false + reason (nothing charged on false)
local Handlers = {}

function Handlers.Dash(ctx)
	local root, def = ctx.root, ctx.def

	local flat = Vector3.new(ctx.aim.X - root.Position.X, 0, ctx.aim.Z - root.Position.Z)
	if flat.Magnitude < MIN_AIM_DIST then
		local look = root.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end

	local old = root:FindFirstChild("AbilityDash")
	if old then old:Destroy() end

	local att = Instance.new("Attachment")
	att.Name = "AbilityDash"
	att.Parent = root

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(DASH_FORCE, 0, DASH_FORCE) -- no Y so gravity still works
	lv.VectorVelocity = flat.Unit * (def.Distance / def.Duration)
	lv.Parent = att

	Debris:AddItem(att, def.Duration)
	return true
end

function Handlers.AOE(ctx)
	local def, root, char = ctx.def, ctx.root, ctx.char
	local head = char:FindFirstChild("Head")
	local origin = head and head.Position or (root.Position + Vector3.yAxis * COVER_RAY_LIFT)

	local target = clampAim(root.Position, ctx.aim, def.Range)
	local dir = target - origin
	if dir.Magnitude < 2 then
		dir = root.CFrame.LookVector * 4
	end

	-- something in the way? just pop it there, no reject
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	rp.RespectCanCollide = true
	local hit = workspace:Raycast(origin, dir, rp)
	local impact = hit and (hit.Position - dir.Unit * 0.5) or (origin + dir)

	local travel = math.max(MIN_PROJECTILE_TRAVEL, (impact - origin).Magnitude / def.ProjectileSpeed)

	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * 1.8
	ball.Material = Enum.Material.Neon
	ball.Color = def.Color
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Position = origin
	ball.Parent = workspace
	TweenService:Create(ball, TweenInfo.new(travel, Enum.EasingStyle.Linear), { Position = impact }):Play()
	Debris:AddItem(ball, travel + 0.1)

	local player = ctx.player
	task.delay(travel, function()
		ball:Destroy()
		explode(player, char, def, impact)
	end)
	return true
end

function Handlers.Heal(ctx)
	local hum, def = ctx.hum, ctx.def
	if hum.Health >= hum.MaxHealth then
		return false, "FullHealth"
	end
	hum.Health = math.min(hum.MaxHealth, hum.Health + def.Amount)
	if def.Regen then
		StatusEffects.Apply(ctx.char, "Regen", {
			Duration = def.Regen.Duration,
			DotDamage = -def.Regen.PerTick, -- negative = heal
			Source = ctx.player,
		})
	end
	return true
end

function Handlers.SpeedBuff(ctx)
	local def = ctx.def
	StatusEffects.Apply(ctx.char, "Haste", {
		Duration = def.Duration,
		SpeedMult = def.Multiplier,
		Source = ctx.player,
	})
	return true
end

local function onCast(player: Player, slotKey, aimPos, castId)
	-- exploiters can send anything, shape checks first
	if type(castId) ~= "number" or castId ~= castId then return end
	if type(slotKey) ~= "string" or not validSlot[slotKey] then return end
	if typeof(aimPos) ~= "Vector3" or not (aimPos.Magnitude < MAX_COORD) then -- nan/inf too
		return reject(player, castId, "BadInput")
	end

	local state = states[player]
	if not state then return end

	local now = os.clock()

	state.tokens = math.min(BUCKET_MAX, state.tokens + (now - state.lastTok) * BUCKET_REFILL)
	state.lastTok = now
	if state.tokens < 1 then return end -- drop silently, client times out
	state.tokens -= 1

	local abilityId = state.loadout[slotKey]
	local def = abilityId and Config.Abilities[abilityId]
	if not def or not state.owned[abilityId] then
		return reject(player, castId, "NotEquipped")
	end

	local char, hum, root = getLive(player)
	if not char then return reject(player, castId, "Dead") end
	if char:GetAttribute("Stunned") then return reject(player, castId, "Stunned") end

	if now < state.gcd - LATENCY_LEEWAY then
		return reject(player, castId, "Busy")
	end

	local expiry = state.cooldowns[abilityId]
	if expiry and now < expiry - LATENCY_LEEWAY then
		return reject(player, castId, "Cooldown", expiry - now)
	end

	local res = state.res[def.CostType]
	if not res or res.value < def.Cost then
		return reject(player, castId, "Resource")
	end

	local handler = def.OnCast or Handlers[def.Type]
	if not handler then
		warn("[Abilities] no handler for type", def.Type)
		return reject(player, castId, "Error")
	end

	local ctx = {
		player = player, char = char, hum = hum, root = root,
		def = def, abilityId = abilityId, aim = aimPos,
	}
	local ok, success, why = pcall(handler, ctx)
	if not ok then
		warn("[Abilities]", abilityId, "errored:", success)
		return reject(player, castId, "Error")
	end
	if not success then
		return reject(player, castId, why or "Failed")
	end

	-- only charge once it really went off
	res.value -= def.Cost
	publish(player, def.CostType, res)

	local cd = math.max(MIN_CAST_CD, def.Cooldown * (char:GetAttribute("CooldownMult") or 1))
	state.cooldowns[abilityId] = now + cd
	state.gcd = now + Config.GlobalCooldown

	CastResult:FireClient(player, castId, true, cd)
end

CastRequest.OnServerEvent:Connect(onCast)

local function equip(player, slotKey, abilityId)
	local state = states[player]
	if not state or not validSlot[slotKey] then return false end
	if abilityId ~= nil and (not Config.Abilities[abilityId] or not state.owned[abilityId]) then
		return false
	end
	state.loadout[slotKey] = abilityId
	player:SetAttribute("Slot_" .. slotKey, abilityId)
	return true
end

local function onPlayerAdded(player: Player)
	local state = {
		res = {},
		cooldowns = {},
		gcd = 0,
		tokens = BUCKET_MAX,
		lastTok = os.clock(),
		owned = {},
		loadout = {},
	}
	for name, r in Config.Resources do
		state.res[name] = { value = r.Max, max = r.Max, regen = r.Regen, shown = -1 }
		player:SetAttribute("Max" .. name, r.Max)
		publish(player, name, state.res[name])
	end
	states[player] = state

	-- todo: datastore for owned + loadout, everybody owns everything for now
	for id in Config.Abilities do
		state.owned[id] = true
	end
	equip(player, "Q", "Dash")
	equip(player, "E", "Fireball")
	equip(player, "R", "Haste")
	equip(player, "1", "Heal")

	player.CharacterAdded:Connect(function()
		for name, r in state.res do
			r.value = r.max
			publish(player, name, r)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p) -- studio can load us after people joined
end

Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < REGEN_STEP then return end
	local step = acc
	acc = 0
	for player, state in states do
		for name, r in state.res do
			if r.value < r.max then
				r.value = math.min(r.max, r.value + r.regen * step)
				publish(player, name, r)
			end
		end
	end
end)