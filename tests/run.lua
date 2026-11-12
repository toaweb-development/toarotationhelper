-- Pure-logic tests (§wow-addon/testing). Run with: lua5.1 tests/run.lua

local ns = { modules = {} }
local failures, passed = 0, 0

local function load(path)
	local chunk = assert(loadfile(path))
	chunk("TOARotationHelper", ns)
end

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

load("Util.lua")
load("Data/Priest.lua")
load("Modules/Rotation.lua")
load("Rotations/Priest.lua")
local Util = ns.Util
local Rotation = ns.Rotation
local PRIEST = ns.Rotations.PRIEST

--- A priest of `level` who knows every rank up to that level plus the listed talent spells.
local function priestState(level, talents, extra)
	local known = {}
	for _, info in pairs(ns.Data.PRIEST.spells) do
		for _, r in ipairs(info.ranks) do
			if r.level <= level then
				known[r.id] = true
			end
		end
	end
	local talentSpells = { innerfocus = 14751, mindflay = 15407, shadowform = 15473, penance = 402174 }
	for family, id in pairs(talentSpells) do
		if not (talents and talents[family]) then
			for _, r in ipairs(ns.Data.PRIEST.spells[family].ranks) do
				known[r.id] = nil
			end
		elseif level >= 20 then
			known[id] = true
		end
	end
	local spells, low = Rotation.KnownSpells(ns.Data.PRIEST, function(id)
		return known[id]
	end, PRIEST.lowRanks)
	local state = {
		now = 100,
		spells = spells,
		low = low,
		readyAt = {},
		dots = {},
		flags = {},
		settings = { saveManaPct = 20 },
		mana = 5000,
		manaMax = 5000,
	}
	for k, v in pairs(extra or {}) do
		state[k] = v
	end
	return state
end

local function names(entries, count)
	local index = Rotation.IndexSpells(ns.Data.PRIEST)
	index[5019] = { family = "wand", rank = 0 }
	local out = {}
	for i = 1, count do
		local e = entries[i]
		out[i] = e and (index[e.id].family .. (index[e.id].rank > 0 and ("r" .. index[e.id].rank) or "")) or "-"
	end
	return table.concat(out, " ")
end

test("Smite 60 without Inner Focus: SW:P, Devouring Plague, Holy Fire, Mind Blast, Smite", function()
	local state = priestState(60, {})
	local out = Rotation.Queue(PRIEST.lists.smite, state, 5)
	local got = names(out, 5)
	assert(got == "swpr8 devouringplaguer6 holyfirer8 mindblastr9 smiter8", got)
end)

test("Smite 60 with Inner Focus opens Inner Focus -> Holy Fire", function()
	local state = priestState(60, { innerfocus = true })
	local got = names(Rotation.Queue(PRIEST.lists.smite, state, 3), 3)
	assert(got == "innerfocus holyfirer8 swpr8", got)
end)

test("Low mana switches to Smite rank 2 after the DoTs are up", function()
	local state = priestState(60, {}, { mana = 400 })
	state.dots.swp = 200
	state.readyAt.devouringplague = 200
	local got = names(Rotation.Queue(PRIEST.lists.smite, state, 2), 2)
	assert(got == "smiter2 smiter2", got)
end)

test("Spells are not repeated while their DoT or cooldown runs", function()
	local state = priestState(60, {})
	local out = Rotation.Queue(PRIEST.lists.smite, state, 8)
	local seen = {}
	for i = 1, 8 do
		local family = Rotation.IndexSpells(ns.Data.PRIEST)[out[i].id].family
		if family == "swp" or family == "devouringplague" then
			assert(not seen[family], family .. " twice")
			seen[family] = true
		end
	end
end)

test("Level 12 priest uses the ranks it has", function()
	local state = priestState(12, {})
	local got = names(Rotation.Queue(PRIEST.lists.smite, state, 3), 3)
	assert(got == "swpr2 mindblastr1 smiter2", got) -- Mind Blast rank 2 comes at level 16
end)

test("Shadow 60 opens Shadowform, then DoTs, Inner Focus + Mind Blast, Mind Flay", function()
	local state = priestState(60, { innerfocus = true, mindflay = true, shadowform = true })
	assert(PRIEST.choose(state.spells) == "shadow")
	local got = names(Rotation.Queue(PRIEST.lists.shadow, state, 7), 7)
	assert(got == "shadowform swpr8 devouringplaguer6 innerfocus mindblastr9 swdeathr4 mindflayr6", got)
end)

test("Shadow in form skips Shadowform and fills with Mind Flay", function()
	local state = priestState(60, { mindflay = true, shadowform = true })
	state.flags.shadowform = true
	state.dots.swp = 200
	state.readyAt.devouringplague, state.readyAt.mindblast, state.readyAt.swdeath = 200, 200, 200
	local got = names(Rotation.Queue(PRIEST.lists.shadow, state, 2), 2)
	assert(got == "mindflayr6 mindflayr6", got)
end)

test("Out of mana with a wand: Shoot", function()
	local state = priestState(30, {}, { mana = 5 })
	state.spells.wand = { id = 5019, rank = 0, cost = 0, cast = 0, cooldown = 0, duration = 0, gcd = 1.5 }
	local rule, entry = Rotation.Next(PRIEST.lists.smite, state)
	assert(rule.family == "wand" and entry.id == 5019)
end)

local WAND = { id = 5019, rank = 0, cost = 0, cast = 0, cooldown = 0, duration = 0, gcd = 1.5 }

test("Auto mode: wand list below 25 with a wand, Smite from 25, Shadow with Mind Flay", function()
	assert(PRIEST.choose({}, { wand = true }, 22) == "wand")
	assert(PRIEST.choose({}, { wand = false }, 22) == "smite")
	assert(PRIEST.choose({}, { wand = true }, 25) == "smite")
	assert(PRIEST.choose({ mindflay = {} }, { wand = true }, 22) == "shadow")
end)

test("Wand list: SW:P, Mind Blast, wand, then the next Mind Blast instead of a second wand", function()
	local state = priestState(22, {})
	state.spells.wand = WAND
	local got = names(Rotation.Queue(PRIEST.lists.wand, state, 4), 4)
	assert(got == "swpr3 mindblastr3 wand mindblastr3", got)
end)

test("Wand list without a wand falls back to Smite", function()
	local state = priestState(22, {})
	state.dots.swp = 200
	state.readyAt.mindblast = 200
	local rule = Rotation.Next(PRIEST.lists.wand, state)
	assert(rule.family == "smite")
end)

test("Improved SW:P lengthens the tracked DoT", function()
	local state = priestState(60, {}, { durationBonus = { swp = 6 } })
	Rotation.Apply(state, "swp", state.spells.swp)
	assert(state.dots.swp == 100 + 18 + 6, tostring(state.dots.swp))
end)

test("AbbreviateKey shortens modifiers and mouse buttons", function()
	assert(Util.AbbreviateKey("1") == "1")
	assert(Util.AbbreviateKey("SHIFT-1") == "S1")
	assert(Util.AbbreviateKey("CTRL-SHIFT-Q") == "CSQ")
	assert(Util.AbbreviateKey("BUTTON4") == "M4")
	assert(Util.AbbreviateKey("ALT-MOUSEWHEELUP") == "AMwU")
	assert(Util.AbbreviateKey("NUMPAD5") == "N5")
	assert(Util.AbbreviateKey(nil) == nil and Util.AbbreviateKey("") == nil)
end)

test("PushFront keeps newest first and trims", function()
	local list = {}
	for i = 1, 5 do
		Util.PushFront(list, i, 3)
	end
	assert(#list == 3 and list[1] == 5 and list[2] == 4 and list[3] == 3)
	Util.PushFront(list, 9, 2)
	assert(#list == 2 and list[1] == 9 and list[2] == 5)
end)

test("Clamp bounds numbers and replaces non-numbers", function()
	assert(Util.Clamp(5, 0, 3, 1) == 3)
	assert(Util.Clamp(-1, 0, 3, 1) == 0)
	assert(Util.Clamp("x", 0, 3, 1) == 1)
end)

test("ApplyDefaults fills gaps without overwriting", function()
	local db = { settings = { shown = false } }
	Util.ApplyDefaults(db, { settings = { shown = true, size = 2 }, list = { 1 } })
	assert(db.settings.shown == false and db.settings.size == 2 and db.list[1] == 1)
end)

test("Migrate runs each step once and sets the version", function()
	local steps = {}
	local db = { schemaVersion = 1 }
	Util.Migrate(db, 3, {
		[1] = function()
			table.insert(steps, 1)
		end,
		[2] = function()
			table.insert(steps, 2)
		end,
	})
	assert(db.schemaVersion == 3 and #steps == 2)
	assert(Util.Migrate({}, 3, {}).schemaVersion == 3)
end)

print(string.format("%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
