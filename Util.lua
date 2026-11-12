-- Pure helpers without WoW API calls, so tests/run.lua can test them (§wow-addon/testing).
local _, ns = ...

local Util = {}
ns.Util = Util

--- Copies missing defaults into db without overwriting what is already there. Returns db.
function Util.ApplyDefaults(db, defaults)
	for key, value in pairs(defaults) do
		if db[key] == nil then
			if type(value) == "table" then
				db[key] = Util.ApplyDefaults({}, value)
			else
				db[key] = value
			end
		elseif type(value) == "table" and type(db[key]) == "table" then
			Util.ApplyDefaults(db[key], value)
		end
	end
	return db
end

--- Lifts db one schema step at a time with migrations[n] (n -> n + 1). A new, empty db is already current.
function Util.Migrate(db, current, migrations)
	local version = db.schemaVersion or current
	while version < current do
		local step = assert(migrations[version], "missing migration from schema " .. version)
		step(db)
		version = version + 1
	end
	db.schemaVersion = version
	return db
end

-- Modifier and key names shortened the way Hekili and most bar addons show them.
local MODIFIERS = { { "ALT%-", "A" }, { "CTRL%-", "C" }, { "SHIFT%-", "S" }, { "META%-", "M" } }
local KEYS = {
	{ "^MOUSEWHEELUP$", "MwU" },
	{ "^MOUSEWHEELDOWN$", "MwD" },
	{ "^MIDDLEMOUSE$", "M3" },
	{ "^BUTTON(%d+)$", "M%1" },
	{ "^NUMPADPLUS$", "N+" },
	{ "^NUMPADMINUS$", "N-" },
	{ "^NUMPADMULTIPLY$", "N*" },
	{ "^NUMPADDIVIDE$", "N/" },
	{ "^NUMPADDECIMAL$", "N." },
	{ "^NUMPAD(%d)$", "N%1" },
	{ "^SPACE$", "Spc" },
	{ "^BACKSPACE$", "BkS" },
	{ "^CAPSLOCK$", "Cap" },
	{ "^INSERT$", "Ins" },
	{ "^DELETE$", "Del" },
	{ "^HOME$", "Hm" },
	{ "^END$", "End" },
	{ "^PAGEUP$", "PU" },
	{ "^PAGEDOWN$", "PD" },
	{ "^ESCAPE$", "Esc" },
	{ "^TAB$", "Tab" },
	{ "^ENTER$", "Ent" },
}

--- Shortens a binding key such as "SHIFT-BUTTON4" to "SM4". Returns nil for nil or "".
function Util.AbbreviateKey(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	local prefix = ""
	local rest = key
	local changed = true
	while changed do
		changed = false
		for _, pair in ipairs(MODIFIERS) do
			local stripped, count = rest:gsub("^" .. pair[1], "")
			if count > 0 then
				prefix = prefix .. pair[2]
				rest = stripped
				changed = true
			end
		end
	end
	for _, pair in ipairs(KEYS) do
		local replaced, count = rest:gsub(pair[1], pair[2])
		if count > 0 then
			rest = replaced
			break
		end
	end
	return prefix .. rest
end

--- Inserts value at the front of list and trims it to max entries. Reuses the list (no new tables).
function Util.PushFront(list, value, max)
	for i = math.min(#list, max - 1), 1, -1 do
		list[i + 1] = list[i]
	end
	list[1] = value
	for i = #list, max + 1, -1 do
		list[i] = nil
	end
	return list
end

--- Clamps a number to [low, high]; falls back to default when value is not a number.
function Util.Clamp(value, low, high, default)
	if type(value) ~= "number" then
		return default
	end
	if value < low then
		return low
	elseif value > high then
		return high
	end
	return value
end
