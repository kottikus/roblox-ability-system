--!nonstrict
local RunService = game:GetService("RunService")

local Manager = {}

local EPS = 1e-3
local MIN_INTERVAL = 0.1
local DEFAULT_INTERVAL = 1

-- known issue: baseSpeed is grabbed when the first effect lands. if sprint etc
-- writes WalkSpeed mid-buff it gets stomped, route it thru a speed effect instead
local active = {}
local activeCount = 0
local hbConn: RBXScriptConnection? = nil

local function recalcSpeed(state)
	local mult = 1
	for _, e in state.effects do
		if e.speedMult then
			mult *= e.speedMult
		end
	end
	state.hum.WalkSpeed = state.baseSpeed * mult
end

local function release(character: Model)
	local state = active[character]
	if not state then return end
	active[character] = nil
	activeCount -= 1

	for _, c in state.conns do
		c:Disconnect()
	end
	for id in state.effects do
		character:SetAttribute("Fx_" .. id, nil)
	end
	if state.hum.Parent then
		state.hum.WalkSpeed = state.baseSpeed
	end

	if activeCount <= 0 and hbConn then
		hbConn:Disconnect()
		hbConn = nil
	end
end

local function step()
	local now = os.clock()
	for character, state in active do
		local hum = state.hum
		if hum.Health <= 0 then
			release(character)
			continue
		end

		local speedDirty = false
		for id, e in state.effects do
			if e.amount then
				-- while, not if, so lag spikes dont eat ticks. clamped to expires so the
				-- last tick still lands
				local limit = math.min(now, e.expires) + EPS
				while e.nextTick <= limit do
					e.nextTick += e.interval
					if e.amount > 0 then
						hum:TakeDamage(e.amount)
					else
						hum.Health = math.min(hum.MaxHealth, hum.Health - e.amount)
					end
					if hum.Health <= 0 then break end
				end
			end

			if now >= e.expires then
				state.effects[id] = nil
				character:SetAttribute("Fx_" .. id, nil)
				if e.speedMult then speedDirty = true end
			end
		end

		if hum.Health <= 0 or next(state.effects) == nil then
			release(character)
		elseif speedDirty then
			recalcSpeed(state)
		end
	end
end

local function ensureState(character: Model)
	local state = active[character]
	if state then return state end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end

	state = {
		hum = hum,
		baseSpeed = hum.WalkSpeed,
		effects = {},
		conns = {},
	}
	table.insert(state.conns, hum.Died:Connect(function() release(character) end))
	table.insert(state.conns, character.Destroying:Connect(function() release(character) end))

	active[character] = state
	activeCount += 1
	if not hbConn then
		hbConn = RunService.Heartbeat:Connect(step)
	end
	return state
end

--- Applies (or refreshes) an effect on a character.
--- Params: `Duration`, `SpeedMult?`, `DotDamage?` (negative = heal), `Interval?`, `Source?`.
--- Same id twice just refreshes it, tick timer is kept on purpose.
function Manager.Apply(character: Model, id: string, params): boolean
	local state = ensureState(character)
	if not state then return false end

	local now = os.clock()
	local interval = math.max(MIN_INTERVAL, params.Interval or DEFAULT_INTERVAL)
	local e = state.effects[id]

	if e then
		e.expires = now + params.Duration
		e.speedMult = params.SpeedMult
		e.amount = params.DotDamage
		e.interval = interval
		e.source = params.Source
	else
		state.effects[id] = {
			expires = now + params.Duration,
			nextTick = now + interval,
			interval = interval,
			speedMult = params.SpeedMult,
			amount = params.DotDamage,
			source = params.Source,
		}
	end

	character:SetAttribute("Fx_" .. id, true)
	recalcSpeed(state)
	return true
end

--- True if the character currently has this effect.
function Manager.Has(character: Model, id: string): boolean
	local state = active[character]
	return state ~= nil and state.effects[id] ~= nil
end

--- Removes one effect early.
function Manager.Remove(character: Model, id: string)
	local state = active[character]
	if not state or not state.effects[id] then return end
	state.effects[id] = nil
	character:SetAttribute("Fx_" .. id, nil)
	if next(state.effects) == nil then
		release(character)
	else
		recalcSpeed(state)
	end
end

--- Wipes every effect on the character.
function Manager.ClearAll(character: Model)
	release(character)
end

return Manager