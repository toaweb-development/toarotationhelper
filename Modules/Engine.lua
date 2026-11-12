-- Engine: decides what to show.
--
-- 1. Own rotation (Rotations/<Class>.lua + Tracker): works in WoW Forever, where Blizzard's Assisted Combat
--    is switched off (C_AssistedCombat.IsAvailable() = false, WRONG_WORLD_STATE_EXPRESSION, 0 rotation spells).
-- 2. Blizzard's Assisted Combat, for a class without an own rotation, if the client ever offers it.
-- GetNextCastSpell is `SecretArguments = "AllowedWhenUntainted"`: that limits passing *secret arguments*;
-- the addon passes a plain boolean, so the call itself is allowed.
local _, ns = ...

local Engine = {
	state = {
		source = "none", -- "own", "assisted" or "none"
		mode = nil, -- own rotation list in use ("smite", "shadow", ...)
		spellID = nil, -- main recommendation
		queue = {}, -- spell IDs after the main one
		available = false,
		reason = "",
		rotation = {}, -- spell IDs in the rotation (for /toarot status)
		cooldownSpells = {}, -- spell IDs for the cooldown row
	},
}
ns.Engine = Engine
table.insert(ns.modules, Engine)

local AVAILABILITY_INTERVAL = 1
local IGNORED_CASTS = {
	[6603] = true, -- Auto Attack
	[75] = true, -- Auto Shot
}

local ticker = CreateFrame("Frame")
ticker:Hide()
local untilTick, untilAvailability = 0, 0
local picks = {} -- reused by Rotation.Queue

-- Assisted Combat --------------------------------------------------------------------------

function Engine.HasAPI()
	return C_AssistedCombat ~= nil and C_AssistedCombat.GetNextCastSpell ~= nil
end

--- Returns available (bool) and a reason string for Blizzard's Assisted Combat. Never errors.
function Engine.IsAssistedAvailable()
	if not Engine.HasAPI() then
		return false, ns.L.API_MISSING
	end
	if not C_AssistedCombat.IsAvailable then
		return true, ""
	end
	local ok, available, reason = pcall(C_AssistedCombat.IsAvailable)
	if not ok then
		return false, tostring(available)
	end
	if not ns.IsPlain(available) then
		return true, ""
	end
	if not ns.IsPlain(reason) or type(reason) ~= "string" then
		reason = ""
	end
	return available and true or false, reason
end

local function assistedNext()
	local ok, result = pcall(C_AssistedCombat.GetNextCastSpell, false)
	return ok and result or nil
end

-- Own rotation -------------------------------------------------------------------------------

function Engine.HasOwnRotation()
	return ns.Tracker and ns.Tracker.data ~= nil
end

--- The rotation list for the chosen mode ("auto" picks by talents).
function Engine:OwnList()
	local rotation = ns.Tracker.rotation
	local mode = ns.db.settings.rotationMode
	if mode == "auto" or not rotation.lists[mode] then
		local level = UnitLevel and UnitLevel("player")
		mode = rotation.choose(ns.Tracker.spells, ns.Tracker.flags, ns.IsPlain(level) and level or nil)
	end
	self.state.mode = mode
	return rotation.lists[mode]
end

function Engine:RefreshRotation()
	local st = self.state
	wipe(st.rotation)
	if self.HasOwnRotation() then
		for _, entry in pairs(ns.Tracker.spells) do
			table.insert(st.rotation, entry.id)
		end
		ns.Tracker:CooldownSpells(st.cooldownSpells)
	else
		wipe(st.cooldownSpells)
		if C_AssistedCombat and C_AssistedCombat.GetRotationSpells then
			local ok, spells = pcall(C_AssistedCombat.GetRotationSpells)
			if ok and type(spells) == "table" and ns.IsPlain(spells) then
				for _, spellID in ipairs(spells) do
					if ns.IsPlain(spellID) then
						table.insert(st.rotation, spellID)
					end
				end
			end
		end
	end
	ns.Fire("ROTATION_UPDATED")
end

function Engine:RefreshAvailability()
	local st = self.state
	local source, available, reason
	if self.HasOwnRotation() then
		source, available, reason = "own", true, ""
	else
		available, reason = Engine.IsAssistedAvailable()
		source = available and "assisted" or "none"
		if not available then
			local _, className = UnitClass("player")
			reason = ns.L.NO_ROTATION:format(className or "?") .. (reason ~= "" and (" (" .. reason .. ")") or "")
		end
	end
	if source ~= st.source or available ~= st.available or reason ~= st.reason then
		st.source, st.available, st.reason = source, available, reason
		ns.Fire("AVAILABILITY_CHANGED", available, reason)
	end
end

-- Ticks -----------------------------------------------------------------------------------------

local function sameList(a, b, count)
	for i = 1, count do
		local x, y = a[i], b[i]
		if not (ns.IsPlain(x) and ns.IsPlain(y)) or x ~= y then
			return false
		end
	end
	return #a == count
end

local queueIDs = {}

function Engine:Tick()
	local st = self.state
	local spellID
	wipe(queueIDs)
	if st.source == "own" then
		local list = self:OwnList()
		local queueCount = ns.Util.Clamp(ns.db.settings.queueCount, 0, 3, 2)
		local _, found = ns.Rotation.Queue(list, ns.Tracker:Snapshot(), 1 + queueCount, picks)
		if found > 0 then
			spellID = picks[1].id
			for i = 2, found do
				queueIDs[i - 1] = picks[i].id
			end
		end
	elseif st.source == "assisted" then
		spellID = assistedNext()
	end

	local changed
	if ns.IsPlain(spellID) and ns.IsPlain(st.spellID) then
		changed = spellID ~= st.spellID
	else
		changed = true
	end
	st.spellID = spellID
	if changed then
		ns.Fire("RECOMMENDATION", spellID)
	end
	if not sameList(st.queue, queueIDs, #queueIDs) then
		wipe(st.queue)
		for i, id in ipairs(queueIDs) do
			st.queue[i] = id
		end
		ns.Fire("QUEUE", st.queue)
	end
	ns.Fire("TICK", spellID)
end

function Engine:RequestUpdate()
	untilTick = 0
end

function Engine:SetActive(active)
	if active then
		untilTick, untilAvailability = 0, 0
	end
	ticker:SetShown(active)
end

ticker:SetScript("OnUpdate", function(_, elapsed)
	untilAvailability = untilAvailability - elapsed
	if untilAvailability <= 0 then
		untilAvailability = AVAILABILITY_INTERVAL
		Engine:RefreshAvailability()
	end
	untilTick = untilTick - elapsed
	if untilTick <= 0 then
		untilTick = ns.Util.Clamp(ns.db.settings.updateRateMs, 50, 500, 100) / 1000
		Engine:Tick()
	end
end)

--- Cooldown for the display: the tracker's own numbers first (plain), nil when unknown.
function Engine:Cooldown(spellID)
	if self.HasOwnRotation() then
		return ns.Tracker:Cooldown(spellID)
	end
	return nil
end

-- Start-up ----------------------------------------------------------------------------------------

local function isHistoryCast(spellID)
	if not ns.IsPlain(spellID) then
		return true
	end
	if type(spellID) ~= "number" or IGNORED_CASTS[spellID] then
		return false
	end
	if ns.Tracker and ns.Tracker.index[spellID] then
		return true
	end
	if IsPlayerSpell then
		local ok, known = pcall(IsPlayerSpell, spellID)
		if ok and ns.IsPlain(known) then
			return known and true or false
		end
	end
	return true
end

function Engine:Init()
	ns.inCombat = InCombatLockdown() and true or false

	local function rotationChanged()
		self:RefreshAvailability()
		self:RefreshRotation()
		self:RequestUpdate()
	end
	ns.On("ROTATION_CHANGED", self, function()
		self:RefreshRotation()
		self:RequestUpdate()
	end)
	ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", rotationChanged)
	ns.RegisterEvent(self, "SPELLS_CHANGED", rotationChanged)
	ns.RegisterEvent(self, "PLAYER_REGEN_DISABLED", function()
		ns.inCombat = true
		ns.Fire("COMBAT_CHANGED", true)
		self:RequestUpdate()
	end)
	ns.RegisterEvent(self, "PLAYER_REGEN_ENABLED", function()
		ns.inCombat = false
		ns.Fire("COMBAT_CHANGED", false)
		self:RequestUpdate()
	end)
	ns.RegisterEvent(self, "PLAYER_TARGET_CHANGED", function()
		self:RequestUpdate()
	end)
	ns.RegisterEvent(self, "SPELL_UPDATE_COOLDOWN", function()
		ns.Fire("COOLDOWNS_CHANGED")
	end)
	ns.RegisterPlayerEvent(self, "UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
		if isHistoryCast(spellID) then
			ns.Fire("CAST", spellID)
		end
		ns.Fire("COOLDOWNS_CHANGED")
		self:RequestUpdate()
	end)
	for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_STOP",
		"UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
		ns.RegisterPlayerEvent(self, event, function()
			self:RequestUpdate()
		end)
	end

	rotationChanged()
end
