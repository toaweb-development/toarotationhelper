-- Display: Hekili-style icon strip.
--
--   [hist2][hist1] [ MAIN ][next][next]    main = what to press now, keybind top-right, swipe = GCD/cooldown
--                  [cd][cd][cd]            cooldown row = the rotation's long cooldowns
--
-- Ordinary (non-secure) frames only, so they may be shown, hidden and moved in combat. Secret values are
-- only passed to display calls (SetTexture, Cooldown), never compared (§wow-addon/principles).
local _, ns = ...

local Display = {
	cooldownSupport = nil, -- Blizzard duration objects: nil = not tried, true = works, false = refused
}
ns.Display = Display
table.insert(ns.modules, Display)

local L = ns.L
local MAIN_SIZE = 56
local SMALL_SIZE = 26 -- history and cooldown row
local QUEUE_SIZE = 44
local GAP = 6
local PAD = 8
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local WAND_SPELL = 5019
local MAX_HISTORY = 6
local MAX_QUEUE = 3
local MAX_COOLDOWN_ICONS = 6
local QUESTION_MARK = 134400 -- Interface\Icons\INV_Misc_QuestionMark

local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local root, main
local historyIcons, queueIcons, cooldownIcons = {}, {}, {}
local history = {} -- spell IDs, newest first (may hold secret IDs: only moved and displayed)

-- Helpers ----------------------------------------------------------------------

local function spellTexture(spellID)
	if spellID == nil or not (C_Spell and C_Spell.GetSpellTexture) then
		return nil
	end
	local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
	if ok then
		return texture
	end
	return nil
end

local function createIcon(parent, size)
	local icon = CreateFrame("Frame", nil, parent)
	icon:SetSize(size, size)

	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	icon.texture:SetAllPoints()
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	icon.border = icon:CreateTexture(nil, "BACKGROUND")
	icon.border:SetPoint("TOPLEFT", -2, 2)
	icon.border:SetPoint("BOTTOMRIGHT", 2, -2)
	icon.border:SetColorTexture(0, 0, 0, 1)

	icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
	icon.cooldown:SetAllPoints()
	icon.cooldown:SetDrawEdge(false)

	-- Text sits on its own frame above the cooldown swipe, so the swipe never darkens it.
	icon.overlay = CreateFrame("Frame", nil, icon)
	icon.overlay:SetAllPoints()
	icon.overlay:SetFrameLevel((icon.cooldown:GetFrameLevel() or icon:GetFrameLevel() or 1) + 2)

	icon.rank = icon.overlay:CreateFontString(nil, "OVERLAY")
	icon.rank:SetFont(FONT, math.max(9, math.floor(size * 0.24)), "OUTLINE")
	icon.rank:SetPoint("BOTTOMLEFT", 2, 2)
	icon.rank:SetTextColor(0.6, 0.85, 1)

	icon.keybind = icon.overlay:CreateFontString(nil, "OVERLAY")
	icon.keybind:SetFont(FONT, math.max(10, math.floor(size * 0.3)), "OUTLINE")
	icon.keybind:SetPoint("TOPRIGHT", -2, -3)
	return icon
end

--- "R2" when spellID is not the best rank the player knows (a mana-saving rank), else "".
local function rankLabel(spellID)
	local tracker = ns.Tracker
	if not (tracker and ns.IsPlain(spellID)) then
		return ""
	end
	local info = tracker.index[spellID]
	local best = info and tracker.spells[info.family]
	if info and best and best.id ~= spellID and info.rank > 0 then
		return "R" .. info.rank
	end
	return ""
end

--- Blizzard's cooldown as a duration object (may hold secret values; only the widget reads them).
local function applyBlizzardCooldown(cooldown, spellID)
	if Display.cooldownSupport == false or not C_Spell then
		cooldown:Clear()
		return
	end
	local ok = pcall(function()
		if C_Spell.GetSpellCooldownDuration and cooldown.SetCooldownFromDurationObject then
			local duration = C_Spell.GetSpellCooldownDuration(spellID, false)
			if duration then
				cooldown:SetCooldownFromDurationObject(duration, true)
			else
				cooldown:Clear()
			end
		else
			local info = C_Spell.GetSpellCooldown(spellID)
			if info and ns.IsPlain(info.startTime) and ns.IsPlain(info.duration) and info.duration > 0 then
				cooldown:SetCooldown(info.startTime, info.duration)
			else
				cooldown:Clear()
			end
		end
	end)
	if ok then
		Display.cooldownSupport = true
	else
		Display.cooldownSupport = false
		cooldown:Clear()
	end
end

--- Swipe for spellID: the tracker's own cooldown (plain numbers), else the GCD, else Blizzard's value.
local function applyCooldown(cooldown, spellID, withGCD)
	if spellID == nil then
		cooldown:Clear()
		return
	end
	local start, duration = ns.Engine:Cooldown(spellID)
	if not start and withGCD and ns.Tracker and ns.Tracker.data then
		start, duration = ns.Tracker:GCD()
	end
	if start then
		cooldown:SetCooldown(start, duration)
	elseif ns.Tracker and ns.Tracker.data then
		cooldown:Clear()
	else
		applyBlizzardCooldown(cooldown, spellID)
	end
end

-- Layout -----------------------------------------------------------------------

local function savePosition()
	local s = ns.db.settings
	local point, _, relativePoint, x, y = root:GetPoint(1)
	if point and ns.IsPlain(x) and ns.IsPlain(y) then
		s.point, s.relativePoint, s.x, s.y = point, relativePoint, math.floor(x + 0.5), math.floor(y + 0.5)
	end
end

local function applyPosition()
	local s = ns.db.settings
	root:ClearAllPoints()
	root:SetPoint(s.point or "CENTER", UIParent, s.relativePoint or s.point or "CENTER", s.x or 0, s.y or 0)
end

function Display:Layout()
	local s = ns.db.settings
	local historyCount = ns.Util.Clamp(s.historyCount, 0, MAX_HISTORY, 0)
	local queueCount = ns.Util.Clamp(s.queueCount, 0, MAX_QUEUE, 2)
	local cooldownCount = s.showCooldowns and math.min(#ns.Engine.state.cooldownSpells, MAX_COOLDOWN_ICONS) or 0

	local historyWidth = historyCount * (SMALL_SIZE + GAP)
	local queueWidth = queueCount * (QUEUE_SIZE + GAP)
	local rowWidth = cooldownCount > 0 and cooldownCount * (SMALL_SIZE + GAP) - GAP or 0
	local width = PAD * 2 + historyWidth + math.max(MAIN_SIZE + queueWidth, rowWidth)
	local height = PAD * 2 + MAIN_SIZE + (cooldownCount > 0 and (GAP + SMALL_SIZE) or 0) + 14
	root:SetSize(width, height)
	root:SetScale(ns.Util.Clamp(s.scale, 0.5, 2, 1))

	main:ClearAllPoints()
	main:SetPoint("TOPLEFT", root, "TOPLEFT", PAD + historyWidth, -PAD)

	for i = 1, MAX_HISTORY do
		local icon = historyIcons[i]
		icon:ClearAllPoints()
		if i == 1 then
			icon:SetPoint("RIGHT", main, "LEFT", -GAP, 0)
		else
			icon:SetPoint("RIGHT", historyIcons[i - 1], "LEFT", -GAP, 0)
		end
		icon:SetAlpha(0.75 - (i - 1) * 0.12)
	end

	for i = 1, MAX_QUEUE do
		local icon = queueIcons[i]
		icon:ClearAllPoints()
		if i == 1 then
			icon:SetPoint("LEFT", main, "RIGHT", GAP, 0)
		else
			icon:SetPoint("LEFT", queueIcons[i - 1], "RIGHT", GAP, 0)
		end
	end

	for i = 1, MAX_COOLDOWN_ICONS do
		local icon = cooldownIcons[i]
		icon:ClearAllPoints()
		if i == 1 then
			icon:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 0, -GAP)
		else
			icon:SetPoint("LEFT", cooldownIcons[i - 1], "RIGHT", GAP, 0)
		end
	end

	self:UpdateHistory()
	self:UpdateQueue(ns.Engine.state.queue)
	self:UpdateCooldownRow()
	self:UpdateLock()
	self:UpdateVisibility()
end

-- Drawing ----------------------------------------------------------------------

function Display:UpdateLock()
	local locked = ns.db.settings.locked
	root:EnableMouse(not locked)
	root:SetBackdropColor(0.045, 0.075, 0.12, locked and 0 or 0.85)
	root:SetBackdropBorderColor(0.24, 0.39, 0.56, locked and 0 or 0.95)
	root.hint:SetShown(not locked)
end

function Display:UpdateVisibility()
	local s = ns.db.settings
	local show = s.shown and (not s.combatOnly or ns.inCombat or not s.locked)
	root:SetShown(show and true or false)
	ns.Engine:SetActive(show and true or false)
end

function Display:UpdateMain(spellID)
	local state = ns.Engine.state
	local texture = spellTexture(spellID)
	if texture ~= nil then
		main.texture:SetTexture(texture)
		main.texture:SetDesaturated(false)
		main:SetAlpha(1)
		root.status:SetText("")
	else
		main.texture:SetTexture(QUESTION_MARK)
		main.texture:SetDesaturated(true)
		main:SetAlpha(0.45)
		if not state.available then
			root.status:SetText(state.reason ~= "" and state.reason or L.NOT_AVAILABLE)
		else
			root.status:SetText(ns.inCombat and "" or L.NO_RECOMMENDATION)
		end
	end

	local key = ns.db.settings.showKeybind and ns.Keybinds:Get(spellID) or nil
	main.keybind:SetText(key or "")
	main.rank:SetText(rankLabel(spellID))
	applyCooldown(main.cooldown, spellID, true)
	self:UpdateCombatLook()
end

--- Gold frame on the main icon in combat; "AUTO" when the recommended wand is already shooting.
function Display:UpdateCombatLook()
	if ns.inCombat then
		main.border:SetColorTexture(1, 0.78, 0.1, 1)
	else
		main.border:SetColorTexture(0, 0, 0, 1)
	end
	local spellID = ns.Engine.state.spellID
	local shooting = false
	if spellID == WAND_SPELL and IsAutoRepeatSpell then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(WAND_SPELL)
		local ok, active = pcall(IsAutoRepeatSpell, info and info.name or "Shoot")
		shooting = ok and ns.IsPlain(active) and active and true or false
	end
	main.auto:SetText(shooting and "AUTO" or "")
end

--- Colours the main icon: red = out of range, blue = not enough mana, grey = not usable.
function Display:UpdateTint(spellID)
	local r, g, b = 1, 1, 1
	if ns.db.settings.showRangeTint and spellID ~= nil and C_Spell then
		local okUsable, usable, noMana = pcall(C_Spell.IsSpellUsable, spellID)
		if okUsable and ns.IsPlain(usable) and ns.IsPlain(noMana) then
			if noMana then
				r, g, b = 0.4, 0.45, 1
			elseif not usable then
				r, g, b = 0.45, 0.45, 0.45
			end
		end
		if r == 1 then
			local okRange, inRange = pcall(C_Spell.IsSpellInRange, spellID, "target")
			if okRange and ns.IsPlain(inRange) and inRange == false then
				r, g, b = 1, 0.25, 0.25
			end
		end
	end
	main.texture:SetVertexColor(r, g, b)
end

function Display:UpdateQueue(queue)
	local count = ns.Util.Clamp(ns.db.settings.queueCount, 0, MAX_QUEUE, 2)
	for i = 1, MAX_QUEUE do
		local icon = queueIcons[i]
		local spellID = i <= count and queue and queue[i] or nil
		local texture = spellTexture(spellID)
		if texture ~= nil then
			icon.texture:SetTexture(texture)
			icon.keybind:SetText(ns.db.settings.showKeybind and ns.Keybinds:Get(spellID) or "")
			icon.rank:SetText(rankLabel(spellID))
			icon:Show()
		else
			icon:Hide()
		end
	end
end

function Display:UpdateHistory()
	local count = ns.Util.Clamp(ns.db.settings.historyCount, 0, MAX_HISTORY, 0)
	for i = 1, MAX_HISTORY do
		local icon = historyIcons[i]
		local texture = i <= count and spellTexture(history[i]) or nil
		if texture ~= nil then
			icon.texture:SetTexture(texture)
			icon:Show()
		else
			icon:Hide()
		end
	end
end

function Display:UpdateCooldownRow()
	local spells = ns.Engine.state.cooldownSpells
	local show = ns.db.settings.showCooldowns
	for i, icon in ipairs(cooldownIcons) do
		local spellID = show and spells[i] or nil
		if spellID then
			icon.texture:SetTexture(spellTexture(spellID) or QUESTION_MARK)
			applyCooldown(icon.cooldown, spellID, false)
			icon:Show()
		else
			icon.cooldown:Clear()
			icon:Hide()
		end
	end
end

-- Start-up -----------------------------------------------------------------------

function Display:Init()
	root = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	root:SetFrameStrata("MEDIUM")
	root:SetClampedToScreen(true)
	root:SetMovable(true)
	root:SetBackdrop(BACKDROP)
	root:RegisterForDrag("LeftButton")
	root:SetScript("OnDragStart", function(f)
		if not ns.db.settings.locked then
			f:StartMoving()
		end
	end)
	root:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		savePosition()
	end)

	main = createIcon(root, MAIN_SIZE)
	main.auto = main.overlay:CreateFontString(nil, "OVERLAY")
	main.auto:SetFont(FONT, 11, "OUTLINE")
	main.auto:SetPoint("BOTTOM", 0, 3)
	main.auto:SetTextColor(0.4, 1, 0.4)

	for i = 1, MAX_HISTORY do
		historyIcons[i] = createIcon(root, SMALL_SIZE)
		historyIcons[i].cooldown:Hide()
	end
	for i = 1, MAX_QUEUE do
		local icon = createIcon(root, QUEUE_SIZE)
		icon.cooldown:Hide()
		icon:SetAlpha(1 - i * 0.12)
		queueIcons[i] = icon
	end
	for i = 1, MAX_COOLDOWN_ICONS do
		cooldownIcons[i] = createIcon(root, SMALL_SIZE)
	end

	root.status = root:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	root.status:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", PAD, PAD - 2)
	root.status:SetJustifyH("LEFT")

	root.hint = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	root.hint:SetPoint("BOTTOMLEFT", root, "TOPLEFT", 2, 2)
	root.hint:SetText(L.DRAG_HINT)

	applyPosition()

	ns.On("RECOMMENDATION", self, function(spellID)
		self:UpdateMain(spellID)
	end)
	ns.On("QUEUE", self, function(queue)
		self:UpdateQueue(queue)
	end)
	ns.On("TICK", self, function(spellID)
		self:UpdateTint(spellID)
		self:UpdateCombatLook()
	end)
	ns.On("CAST", self, function(spellID)
		ns.Util.PushFront(history, spellID, MAX_HISTORY)
		self:UpdateHistory()
	end)
	ns.On("COOLDOWNS_CHANGED", self, function()
		applyCooldown(main.cooldown, ns.Engine.state.spellID, true)
		self:UpdateCooldownRow()
	end)
	ns.On("KEYBINDS_CHANGED", self, function()
		self:UpdateMain(ns.Engine.state.spellID)
		self:UpdateQueue(ns.Engine.state.queue)
	end)
	ns.On("AVAILABILITY_CHANGED", self, function()
		self:UpdateMain(ns.Engine.state.spellID)
	end)
	ns.On("ROTATION_UPDATED", self, function()
		self:Layout()
	end)
	ns.On("COMBAT_CHANGED", self, function(inCombat)
		if not inCombat then
			wipe(history)
			self:UpdateHistory()
		end
		self:UpdateVisibility()
		self:UpdateMain(ns.Engine.state.spellID)
	end)
	ns.On("SETTINGS_CHANGED", self, function()
		self:Layout()
		self:UpdateMain(ns.Engine.state.spellID)
		ns.Engine:RequestUpdate()
	end)
	ns.On("POSITION_RESET", self, function()
		applyPosition()
	end)

	self:Layout()
	self:UpdateMain(nil)
end
