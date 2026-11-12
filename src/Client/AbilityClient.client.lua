--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Abilities")
local Config = require(Shared:WaitForChild("AbilityConfig"))
local Remotes = Shared:WaitForChild("Remotes")
local CastRequest = Remotes:WaitForChild("CastRequest")
local CastResult = Remotes:WaitForChild("CastResult")

local KEYCODES = {
	Q = Enum.KeyCode.Q, E = Enum.KeyCode.E, R = Enum.KeyCode.R,
	["1"] = Enum.KeyCode.One, ["2"] = Enum.KeyCode.Two, ["3"] = Enum.KeyCode.Three,
	["4"] = Enum.KeyCode.Four, ["5"] = Enum.KeyCode.Five, ["6"] = Enum.KeyCode.Six,
	["7"] = Enum.KeyCode.Seven, ["8"] = Enum.KeyCode.Eight, ["9"] = Enum.KeyCode.Nine,
}
local keyToSlot = {}
for slot, code in KEYCODES do
	keyToSlot[code] = slot
end

local IDLE_STROKE = Color3.fromRGB(90, 90, 100)
local READY_STROKE = Color3.fromRGB(255, 255, 255)
local FAIL_STROKE = Color3.fromRGB(255, 70, 70)

local SLOT_SIZE = 64
local IDLE_THICKNESS = 1.5
FLASH_THICKNESS = 3
local PENDING_TIMEOUT = 3
local TOAST_HOLD = 1.2
local TOAST_FADE = 0.4
local AIM_RAY_LENGTH = 500
local DEFAULT_AIM_RANGE = 30
local BAR_SMOOTHING = 12

local REASONS = {
	Cooldown = "Still on cooldown",
	Busy = "Hold on...",
	NotEquipped = "Ability not equipped",
	Dead = "You're dead",
	Stunned = "Stunned",
	FullHealth = "Already at full health",
}

local cooldowns = {} -- [id] = { start, duration }
local pending = {}   -- [castId] = { abilityId, prevCd, cancelFx }
local localGcd = 0
local castCounter = 0
local animTracks = {}

local gui = Instance.new("ScreenGui")
gui.Name = "AbilityHotbar"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local bar = Instance.new("Frame")
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.new(0.5, 0, 1, -24)
bar.AutomaticSize = Enum.AutomaticSize.XY
bar.BackgroundTransparency = 1
bar.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = bar

local function corner(parent, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function label(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextColor3 = Color3.new(1, 1, 1)
	for k, v in props do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local slots = {}
for i, key in Config.SlotKeys do
	local btn = Instance.new("TextButton")
	btn.Name = "Slot_" .. key
	btn.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	btn.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.LayoutOrder = i
	btn.Visible = false
	btn.Parent = bar
	corner(btn, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = IDLE_STROKE
	stroke.Thickness = IDLE_THICKNESS
	stroke.Parent = btn

	local nameLbl = label(btn, {
		Size = UDim2.new(1, -6, 0, 20), Position = UDim2.new(0, 3, 0.5, -10),
		TextSize = 12,
	})
	label(btn, {
		Size = UDim2.fromOffset(18, 14), Position = UDim2.fromOffset(4, 3),
		TextSize = 11, Text = key, TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = 0.25,
	})
	local costLbl = label(btn, {
		Size = UDim2.fromOffset(30, 14), Position = UDim2.new(1, -33, 1, -17),
		TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- cd fill, drains downward
	local overlay = Instance.new("Frame")
	overlay.AnchorPoint = Vector2.new(0, 1)
	overlay.Position = UDim2.fromScale(0, 1)
	overlay.Size = UDim2.fromScale(1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 2
	overlay.Visible = false
	overlay.Parent = btn
	corner(overlay, 10)

	local timer = label(btn, {
		Size = UDim2.fromScale(1, 1), TextSize = 18, ZIndex = 3, Text = "",
	})

	slots[key] = {
		button = btn, stroke = stroke, name = nameLbl, cost = costLbl,
		overlay = overlay, timer = timer, abilityId = nil,
	}
end

local barsFrame = Instance.new("Frame")
barsFrame.AnchorPoint = Vector2.new(0.5, 1)
barsFrame.Position = UDim2.new(0.5, 0, 1, -100)
barsFrame.Size = UDim2.fromOffset(280, 0)
barsFrame.AutomaticSize = Enum.AutomaticSize.Y
barsFrame.BackgroundTransparency = 1
barsFrame.Parent = gui
local barsLayout = Instance.new("UIListLayout")
barsLayout.Padding = UDim.new(0, 4)
barsLayout.Parent = barsFrame

local resBars = {}
for name, r in Config.Resources do
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 0, 14)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BorderSizePixel = 0
	back.Parent = barsFrame
	corner(back, 5)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = r.Color
	fill.BorderSizePixel = 0
	fill.Parent = back
	corner(fill, 5)

	local txt = label(back, { Size = UDim2.fromScale(1, 1), TextSize = 10, ZIndex = 2 })
	resBars[name] = { fill = fill, text = txt, shown = player:GetAttribute(name) or r.Max }
end

local toast = label(gui, {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -140),
	Size = UDim2.fromOffset(300, 22), TextSize = 15, TextTransparency = 1,
	TextStrokeTransparency = 1,
})
local toastToken = 0
local function showToast(msg)
	toastToken += 1
	local mine = toastToken
	toast.Text = msg
	toast.TextTransparency = 0
	toast.TextStrokeTransparency = 0.5
	task.delay(TOAST_HOLD, function()
		if mine ~= toastToken then return end -- newer one took over
		TweenService:Create(toast, TweenInfo.new(TOAST_FADE), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
end

local function flashSlot(slot, color)
	slot.stroke.Color = color
	slot.stroke.Thickness = FLASH_THICKNESS
	TweenService:Create(slot.stroke, TweenInfo.new(0.3), { Color = IDLE_STROKE, Thickness = IDLE_THICKNESS }):Play()
end

local function refreshSlot(key)
	local slot = slots[key]
	local id = player:GetAttribute("Slot_" .. key)
	local def = id and Config.Abilities[id]
	slot.abilityId = def and id or nil
	slot.button.Visible = def ~= nil
	if def then
		slot.name.Text = def.DisplayName
		slot.cost.Text = tostring(def.Cost)
		local res = Config.Resources[def.CostType]
		slot.cost.TextColor3 = res and res.Color or Color3.new(1, 1, 1)
	end
end

for _, key in Config.SlotKeys do
	refreshSlot(key)
	player:GetAttributeChangedSignal("Slot_" .. key):Connect(function()
		refreshSlot(key)
	end)
end

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude

local function getAim(def, root)
	if not def.NeedsAim then return root.Position end
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		-- phones: no cursor, just go forward
		return root.Position + root.CFrame.LookVector * (def.Range or DEFAULT_AIM_RANGE)
	end
	local cam = workspace.CurrentCamera
	local loc = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(loc.X, loc.Y)
	aimParams.FilterDescendantsInstances = { player.Character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RAY_LENGTH, aimParams)
	return hit and hit.Position or (ray.Origin + ray.Direction * AIM_RAY_LENGTH)
end

local function playAnim(char, def, id)
	if not def.AnimationId or def.AnimationId == "" then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then return nil end

	local track = animTracks[id]
	if not track then
		local anim = Instance.new("Animation")
		anim.AnimationId = def.AnimationId
		track = animator:LoadAnimation(anim)
		animTracks[id] = track
	end
	track:Play(0.05)
	return function()
		track:Stop(0.1)
	end
end

local function playLocalFx(char, root, def, id, aim)
	local cancels = {}
	local stopAnim = playAnim(char, def, id)
	if stopAnim then table.insert(cancels, stopAnim) end
	if def.ClientFX then
		local ok, c = pcall(def.ClientFX, { character = char, root = root, aimPos = aim })
		if ok and c then table.insert(cancels, c) end
	end
	return function()
		for _, f in cancels do
			pcall(f)
		end
	end
end

local function tryCast(key)
	local slot = slots[key]
	local id = slot and slot.abilityId
	local def = id and Config.Abilities[id]
	if not def then return end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return end

	local now = os.clock()
	if cooldowns[id] then
		flashSlot(slot, FAIL_STROKE)
		return
	end
	if now < localGcd then return end

	if (player:GetAttribute(def.CostType) or 0) < def.Cost then
		flashSlot(slot, FAIL_STROKE)
		showToast("Not enough " .. def.CostType)
		return
	end

	local aim = getAim(def, root)
	castCounter += 1
	local castId = castCounter

	-- predict it, server hasnt heard yet
	pending[castId] = {
		abilityId = id,
		prevCd = cooldowns[id],
		cancelFx = playLocalFx(char, root, def, id, aim),
	}
	cooldowns[id] = { start = os.clock(), duration = def.Cooldown }
	localGcd = now + Config.GlobalCooldown

	CastRequest:FireServer(key, aim, castId)

	-- no answer (rate limited?) = forget it
	task.delay(PENDING_TIMEOUT, function()
		pending[castId] = nil
	end)
end

CastResult.OnClientEvent:Connect(function(castId, ok, a, b)
	local p = pending[castId]
	if not p then return end
	pending[castId] = nil

	local def = Config.Abilities[p.abilityId]
	if not def then return end

	if ok then
		-- server cd can differ from config (cdr), a = real duration
		local cd = cooldowns[p.abilityId]
		if cd and type(a) == "number" then
			cd.duration = a
		end
		return
	end

	local reason, remaining = a, b
	if p.cancelFx then p.cancelFx() end

	if reason == "Cooldown" and type(remaining) == "number" then
		-- out of sync, trust the server clock
		cooldowns[p.abilityId] = { start = os.clock() - (def.Cooldown - remaining), duration = def.Cooldown }
	else
		cooldowns[p.abilityId] = p.prevCd
		localGcd = 0
	end

	for _, slot in slots do
		if slot.abilityId == p.abilityId then
			flashSlot(slot, FAIL_STROKE)
		end
	end
	if reason == "Resource" then
		showToast("Not enough " .. def.CostType)
	else
		showToast(REASONS[reason] or "Can't cast that")
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local key = keyToSlot[input.KeyCode]
	if key then
		tryCast(key)
	end
end)

for key, slot in slots do
	slot.button.Activated:Connect(function()
		tryCast(key)
	end)
end

player.CharacterAdded:Connect(function()
	table.clear(animTracks) -- old animator took them along
	for _, p in pending do
		if p.cancelFx then p.cancelFx() end
	end
	table.clear(pending)
end)

RunService.RenderStepped:Connect(function(dt)
	local now = os.clock()

	for _, slot in slots do
		local id = slot.abilityId
		local cd = id and cooldowns[id]
		if cd then
			local remaining = cd.start + cd.duration - now
			if remaining > 0 then
				slot.overlay.Visible = true
				slot.overlay.Size = UDim2.fromScale(1, remaining / cd.duration)
				local txt = if remaining >= 10 then string.format("%d", math.ceil(remaining))
					else string.format("%.1f", remaining)
				if slot.timer.Text ~= txt then
					slot.timer.Text = txt
				end
			else
				cooldowns[id] = nil
				slot.overlay.Visible = false
				slot.timer.Text = ""
				flashSlot(slot, READY_STROKE)
			end
		elseif slot.overlay.Visible then
			slot.overlay.Visible = false
			slot.timer.Text = ""
		end
	end

	local alpha = math.min(1, dt * BAR_SMOOTHING)
	for name, b in resBars do
		local target = player:GetAttribute(name) or 0
		local max = player:GetAttribute("Max" .. name) or 100
		b.shown += (target - b.shown) * alpha
		b.fill.Size = UDim2.fromScale(math.clamp(b.shown / max, 0, 1), 1)
		local txt = string.format("%s %d / %d", name, target, max)
		if b.text.Text ~= txt then
			b.text.Text = txt
		end
	end
end)