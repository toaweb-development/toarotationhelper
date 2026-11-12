-- Priest rotations for WoW Forever.
--
-- Found with the MythicSim Forever engine (github.com/sage3648/mythicsim-forever-engine), 2026-11-12,
-- level 60 reference builds, 2000 fights per cell. Only conditions the addon can follow from the
-- player's own casts are used (cooldowns, own DoTs, estimated mana); fight length and target debuff
-- stacks cannot be read in Forever combat, so rules that need them were dropped and re-tested.
--
--   Smite (Discipline/Holy talents), DPS    30 s    60 s    120 s   300 s
--     MythicSim preset (full)               564     562     557     533
--     These rules                           572     572     559     534
--   Shadow, DPS                                     60 s    120 s   300 s
--     MythicSim preset (full)                       334     322     276
--     These rules                                   337     324     286
--
-- Penance was tested as damage in the Smite list and lost 1-3 %: it stays a heal.
--
-- Levelling (MythicSim level fixtures, wand damage added for the time not spent casting, because the
-- engine only fires wands for hunters). "Effective DPS" counts the drinking needed to win the mana back:
--                                      L22 30 s / 90 s     L30 Holy 30 s / 90 s   L30 Shadow 30 s / 90 s
--     Smite list (spells, then drink)    20.1 / 21.3          76.0 / 82.5           78.4 / 87.4
--     Wand list (SW:P, Mind Blast, wand) 25.4 / 25.6          62.8 / 63.7           75.8 / 80.2
-- Below level 25 with a wand, the wand list levels about 25 % faster; from 30 spells win.
local _, ns = ...

ns.Rotations = ns.Rotations or {}

local SAVE_MANA = function(h)
	return h:manaPct() >= (h:setting("saveManaPct") or 20)
end

local smite = {
	-- Inner Focus right before a Holy Fire that is due (a free, crit-boosted Holy Fire).
	{
		family = "innerfocus",
		when = function(h)
			return h:known("holyfire") and h:dotRemaining("holyfire") < 3 and SAVE_MANA(h)
		end,
	},
	-- ...and that Holy Fire straight after it (MythicSim's strict Inner Focus -> Holy Fire sequence).
	{
		family = "holyfire",
		when = function(h)
			return h:recentlyCast("innerfocus", 3)
		end,
	},
	{
		family = "swp",
		when = function(h)
			return not h:dotActive("swp")
		end,
	},
	{ family = "devouringplague" },
	{
		family = "holyfire",
		when = function(h)
			return h:dotRemaining("holyfire") < 3 and SAVE_MANA(h)
		end,
	},
	{ family = "mindblast", when = SAVE_MANA },
	{ family = "smite", when = SAVE_MANA },
	-- Below the mana line: Smite rank 2 keeps damage going at a fraction of the cost.
	{ family = "smite", rank = "low" },
	{ family = "smite" },
	{ family = "wand" },
}

local shadow = {
	{
		family = "shadowform",
		marks = "shadowform",
		when = function(h)
			return not h:flag("shadowform") and not h:dotActive("shadowform")
		end,
	},
	{
		family = "swp",
		when = function(h)
			return not h:dotActive("swp")
		end,
	},
	{ family = "devouringplague" },
	{
		family = "innerfocus",
		when = function(h)
			return h:ready("mindblast")
		end,
	},
	{ family = "mindblast" },
	{ family = "swdeath" },
	{ family = "mindflay" },
	{ family = "smite" },
	{ family = "wand" },
}

-- Levelling with a wand: keep Shadow Word: Pain up, Mind Blast on cooldown, wand the rest.
-- Without a wand equipped the wand line is skipped and Smite fills in.
local wand = {
	{
		family = "swp",
		when = function(h)
			return not h:dotActive("swp")
		end,
	},
	{ family = "mindblast" },
	{ family = "wand" },
	{ family = "smite" },
}

-- Below this level, with a wand, the wand list levels faster (see the table above). Wand Specialization 2/2
-- (+25 % wand damage) moved the tie to level 30 for a Shadow-leaning priest (L30: 78.8 wand vs 78.5 spells,
-- 30 s fights), but not for Holy, whose Searing Light / Divine Fury make Smite stronger (66.3 vs 75.8).
local WAND_LEVEL = 25
local WAND_LEVEL_SPECIALIZED = 30

local function wandLevel(flags)
	if (flags.wandSpecialization or 0) >= 2 and (flags.searingLight or 0) == 0 then
		return WAND_LEVEL_SPECIALIZED
	end
	return WAND_LEVEL
end

ns.Rotations.PRIEST = {
	data = function()
		return ns.Data.PRIEST
	end,
	lowRanks = { smite = 2 },
	lists = { smite = smite, shadow = shadow, wand = wand },
	order = { "smite", "shadow", "wand" },
	--- Auto mode: Shadow once Mind Flay (a Shadow talent) is known; below level 25 with a wand, the
	--- wand list; otherwise Smite.
	choose = function(spells, flags, level)
		if spells.mindflay then
			return "shadow"
		end
		if flags and flags.wand and level and level < wandLevel(flags) then
			return "wand"
		end
		return "smite"
	end,
	wandLevel = wandLevel,
}
