-- Export: writes the character to SavedVariables so tools/sim_character.py can simulate it in MythicSim.
--
-- Everything is read out of combat, when the values are plain. The data lands in
-- WTF/Account/<account>/SavedVariables/TOARotationHelper.lua after /reload or logout.
-- Only game data is stored: level, race, class, stats, gear (item and enchant IDs), talents, known ranks.
local _, ns = ...

local Export = {}
ns.Export = Export
table.insert(ns.modules, Export)

-- MythicSim / wowsims item slot order -> WoW inventory slot IDs.
local SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
local SPELL_SCHOOLS = { 2, 3, 4, 5, 6, 7 } -- holy, fire, nature, frost, shadow, arcane

local function plain(v)
	return ns.IsPlain(v) and v or nil
end

local function call(fn, ...)
	if not fn then
		return nil
	end
	local ok, a, b, c, d = pcall(fn, ...)
	if not ok then
		return nil
	end
	return plain(a), plain(b), plain(c), plain(d)
end

local function round(v, places)
	if type(v) ~= "number" then
		return nil
	end
	local m = 10 ^ (places or 2)
	return math.floor(v * m + 0.5) / m
end

local function equipment()
	local items = {}
	for i, slot in ipairs(SLOTS) do
		local link = call(GetInventoryItemLink, "player", slot)
		local entry = {}
		if type(link) == "string" then
			local id, enchant = link:match("item:(%d+):(%d*)")
			entry.id = tonumber(id)
			if enchant and enchant ~= "" and tonumber(enchant) ~= 0 then
				entry.enchant = tonumber(enchant)
			end
		end
		items[i] = entry
	end
	return items
end

--- Returns the export table, or nil and a reason.
function Export:Collect()
	if InCombatLockdown() then
		return nil, ns.L.EXPORT_IN_COMBAT
	end
	local tracker = ns.Tracker
	-- Forever's UnitStat returns the total in both of its first values; the gear part is subtracted by
	-- tools/sim_character.py from the item data. The raw values are kept to check that later.
	local base, attributes, statRaw = {}, {}, {}
	for i = 1, 5 do
		local b, effective, posBuff, negBuff = call(UnitStat, "player", i)
		base[i], attributes[i] = round(b, 0), round(effective, 0)
		statRaw[i] = { b, effective, posBuff, negBuff }
	end
	local spellCrit = {}
	for i, school in ipairs(SPELL_SCHOOLS) do
		spellCrit[i] = round(call(GetSpellCritChance, school), 2)
	end
	local _, race = call(UnitRace, "player")
	local _, class = call(UnitClass, "player")

	local talents = {}
	if tracker and tracker.allTalents then
		tracker:ReadTalents()
		for name, rank in pairs(tracker.allTalents) do
			talents[name] = rank
		end
	end
	local known = {}
	if tracker and tracker.data then
		for _, info in pairs(tracker.data.spells) do
			for _, r in ipairs(info.ranks) do
				local ok, isKnown = pcall(IsPlayerSpell, r.id)
				if ok and ns.IsPlain(isKnown) and isKnown then
					table.insert(known, r.id)
				end
			end
		end
		table.sort(known)
	end

	return {
		addonVersion = ns.version,
		date = date and date("%Y-%m-%d %H:%M") or nil,
		level = call(UnitLevel, "player"),
		race = race,
		class = class,
		health = call(UnitHealthMax, "player"),
		mana = call(UnitPowerMax, "player", 0),
		base = base,
		attributes = attributes,
		statRaw = statRaw,
		meleeCrit = round(call(GetCritChance), 2),
		spellCrit = spellCrit,
		spellPower = call(GetSpellBonusDamage, 6), -- shadow; holy is school 2
		holySpellPower = call(GetSpellBonusDamage, 2),
		equipment = equipment(),
		talents = talents,
		talentMethod = tracker and tracker.talentMethod or "none",
		knownSpells = known,
	}
end

function Export:Run()
	local data, reason = self:Collect()
	if not data then
		ns.Print(reason)
		return
	end
	ns.db.export = data
	ns.Print(ns.L.EXPORT_DONE)
end

function Export:Init() end
