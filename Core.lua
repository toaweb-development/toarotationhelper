-- TOA Rotation Helper core: namespace, events, saved data, slash command
-- (§wow-addon/structure, §wow-addon/events, §wow-addon/savedvariables).
local addonName, ns = ...

ns.name = addonName
ns.version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

local L = ns.L

-- Saved data -----------------------------------------------------------------

local SCHEMA_VERSION = 3 -- account data (TOARotationHelperDB)

local DEFAULTS = {
	schemaVersion = SCHEMA_VERSION,
	settings = {
		shown = true,
		locked = false,
		combatOnly = false,
		showKeybind = true,
		showRangeTint = true,
		showCooldowns = false,
		historyCount = 0,
		queueCount = 2,
		rotationMode = "auto",
		saveManaPct = 20,
		scale = 1,
		updateRateMs = 100,
		point = "CENTER",
		relativePoint = "CENTER",
		x = 0,
		y = -180,
	},
}

-- MIGRATIONS[n] lifts data from version n to n + 1.
local MIGRATIONS = {
	-- 0.3 -> 0.4: one row of three spells (main + 2 ahead); recent casts off, they read as a fourth spell.
	[1] = function(db)
		if type(db.settings) == "table" then
			db.settings.historyCount = 0
			db.settings.queueCount = 2
		end
	end,
	-- 0.5 -> 0.6: only the row of three spells by default; the cooldown row is opt-in.
	[2] = function(db)
		if type(db.settings) == "table" then
			db.settings.showCooldowns = false
		end
	end,
}

-- Events ---------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {} -- handlers[event][owner] = function(event, ...)

--- Registers handler(event, ...) for event on behalf of owner (a module table or a string).
function ns.RegisterEvent(owner, event, handler)
	if not handlers[event] then
		handlers[event] = {}
		frame:RegisterEvent(event)
	end
	handlers[event][owner] = handler
end

function ns.UnregisterEvent(owner, event)
	local byOwner = handlers[event]
	if not byOwner then
		return
	end
	byOwner[owner] = nil
	if next(byOwner) == nil then
		handlers[event] = nil
		frame:UnregisterEvent(event)
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	local byOwner = handlers[event]
	if not byOwner then
		return
	end
	for _, handler in pairs(byOwner) do
		handler(event, ...)
	end
end)

-- Player-only unit events on their own frame, so the client filters other units for us.
local playerFrame = CreateFrame("Frame")
local playerHandlers = {}

function ns.RegisterPlayerEvent(owner, event, handler)
	if not playerHandlers[event] then
		playerHandlers[event] = {}
		playerFrame:RegisterUnitEvent(event, "player")
	end
	playerHandlers[event][owner] = handler
end

playerFrame:SetScript("OnEvent", function(_, event, ...)
	local byOwner = playerHandlers[event]
	if not byOwner then
		return
	end
	for _, handler in pairs(byOwner) do
		handler(event, ...)
	end
end)

-- Tiny internal message bus between modules (Engine -> Display).
local listeners = {}

function ns.On(message, owner, fn)
	listeners[message] = listeners[message] or {}
	listeners[message][owner] = fn
end

function ns.Fire(message, ...)
	local byOwner = listeners[message]
	if not byOwner then
		return
	end
	for _, fn in pairs(byOwner) do
		fn(...)
	end
end

--- True when v may be used in logic (compared, used as key). Secret values may only be displayed.
function ns.IsPlain(v)
	return not (issecretvalue and issecretvalue(v))
end

function ns.Print(...)
	print("|cff77c5ff" .. L.ADDON_TITLE .. "|r", ...)
end

-- Start-up ---------------------------------------------------------------------

ns.modules = {}

ns.RegisterEvent(ns, "ADDON_LOADED", function(_, loaded)
	if loaded ~= addonName then
		return
	end
	ns.UnregisterEvent(ns, "ADDON_LOADED")
	TOARotationHelperDB = TOARotationHelperDB or {}
	ns.Util.Migrate(TOARotationHelperDB, SCHEMA_VERSION, MIGRATIONS)
	ns.db = ns.Util.ApplyDefaults(TOARotationHelperDB, DEFAULTS)
	ns.defaults = DEFAULTS.settings
end)

ns.RegisterEvent(ns, "PLAYER_LOGIN", function()
	ns.UnregisterEvent(ns, "PLAYER_LOGIN")
	for _, module in ipairs(ns.modules) do
		module:Init()
	end
	ns.Print(L.LOADED)
end)

--- Called by every place that changes a setting, so the display redraws once.
function ns.SettingsChanged()
	ns.Fire("SETTINGS_CHANGED")
end

-- Access -----------------------------------------------------------------------

function TOARotationHelper_OnAddonCompartmentClick()
	if ns.Options then
		ns.Options:Open()
	end
end

local function spellLabel(spellID)
	if spellID == nil then
		return "-"
	end
	if not ns.IsPlain(spellID) then
		return L.SECRET_VALUE
	end
	local info = C_Spell and C_Spell.GetSpellInfo(spellID)
	return ("%s (%d)"):format(info and info.name or "?", spellID)
end

local function printStatus()
	local Engine, Tracker = ns.Engine, ns.Tracker
	local st = Engine.state
	ns.Print(L.STATUS_SOURCE:format(st.source, st.mode or "-"))
	if Engine.HasAPI() then
		local available, reason = Engine.IsAssistedAvailable()
		ns.Print(L.STATUS_AVAILABLE:format(available and L.YES or L.NO) .. (reason ~= "" and (" - " .. reason) or ""))
	end
	if st.reason ~= "" then
		ns.Print(L.STATUS_REASON:format(st.reason))
	end
	local queue = {}
	for _, id in ipairs(st.queue) do
		table.insert(queue, spellLabel(id))
	end
	ns.Print(L.STATUS_NEXT:format(spellLabel(st.spellID)) .. (#queue > 0 and (" -> " .. table.concat(queue, ", ")) or ""))
	ns.Print(L.STATUS_ROTATION:format(#st.rotation))
	if Tracker and Tracker.data then
		local mana = Tracker.mana and Tracker.manaMax
			and ("%d / %d%s"):format(Tracker.mana, Tracker.manaMax, Tracker.manaIsEstimate and " (estimate)" or "")
			or "?"
		ns.Print(L.STATUS_MANA:format(mana))
		ns.Print(L.STATUS_CASTS:format(#Tracker.lastCasts > 0 and table.concat(Tracker.lastCasts, ", ") or "-"))
	end
end

SLASH_TOAROTATIONHELPER1 = "/toarot"
SLASH_TOAROTATIONHELPER2 = "/toarh"
SlashCmdList.TOAROTATIONHELPER = function(msg)
	if not ns.db then
		return
	end
	local settings = ns.db.settings
	msg = strtrim((msg or ""):lower())
	if msg == "" or msg == "config" or msg == "options" then
		TOARotationHelper_OnAddonCompartmentClick()
	elseif msg == "show" then
		settings.shown = true
		ns.SettingsChanged()
	elseif msg == "hide" then
		settings.shown = false
		ns.SettingsChanged()
	elseif msg == "lock" then
		settings.locked = not settings.locked
		ns.Print(settings.locked and L.LOCKED or L.UNLOCKED)
		ns.SettingsChanged()
	elseif msg == "reset" then
		settings.point, settings.relativePoint = "CENTER", "CENTER"
		settings.x, settings.y = DEFAULTS.settings.x, DEFAULTS.settings.y
		ns.Print(L.POSITION_RESET)
		ns.Fire("POSITION_RESET")
	elseif msg == "status" then
		printStatus()
	elseif msg == "export" then
		ns.Export:Run()
	elseif msg == "talents" then
		local tracker = ns.Tracker
		if not (tracker and tracker.data) then
			ns.Print(L.NO_ROTATION:format(select(2, UnitClass("player")) or "?"))
			return
		end
		if not ns.inCombat then
			tracker:ReadTalents()
			tracker:RefreshKnowledge()
		end
		ns.Print(L.TALENTS_HEADER:format(tracker.talentMethod))
		for key, talent in pairs(tracker.data.talents) do
			print(("  %s: %d/%d"):format(talent.name, tracker.talentRanks[key] or 0, talent.maxRank))
		end
		if tracker.rotation.wandLevel then
			ns.Print(L.TALENTS_WAND_LEVEL:format(tracker.rotation.wandLevel(tracker.flags)))
		end
	elseif msg:match("^mode") then
		local mode = msg:match("^mode%s+(%S+)")
		local valid = mode == "auto" or (ns.Tracker and ns.Tracker.rotation and ns.Tracker.rotation.lists[mode])
		if valid then
			settings.rotationMode = mode
			ns.Print(L.MODE_SET:format(mode))
			ns.SettingsChanged()
		else
			local names = { "auto" }
			for _, name in ipairs(ns.Tracker and ns.Tracker.rotation and ns.Tracker.rotation.order or {}) do
				table.insert(names, name)
			end
			ns.Print(L.MODE_HELP:format(table.concat(names, " | "), settings.rotationMode))
		end
	else
		ns.Print(L.HELP_HEADER)
		for _, line in ipairs(L.HELP_LINES) do
			print("  " .. line)
		end
	end
end
