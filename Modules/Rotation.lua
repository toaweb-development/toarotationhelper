-- Rotation: a small priority-list evaluator, like Hekili's APL runner (§wow-addon/structure: pure logic).
--
-- No WoW API here, so tests/run.lua can drive it. It works on a plain state snapshot:
--   state.now          time the next action can start (seconds)
--   state.spells[f]    the best known rank of spell family f: { id, rank, cost, cast, cooldown, duration,
--                      gcd, channel }; a family the player does not know is absent
--   state.low[f]       a low rank of family f for mana saving (optional)
--   state.readyAt[f]   when f's own cooldown ends (from the player's own casts)
--   state.dots[f]      when f's damage over time on the current target ends
--   state.mana, state.manaMax   current (or estimated) mana; nil when unknown
--   state.flags        extra booleans a rotation may read (shadowform, wand, ...)
--
-- A rotation is a list of rules { family = "swp", rank = "low"?, when = function(h) ... end }. The first
-- rule whose spell is known, affordable and whose `when` passes is the recommendation. Queue() applies
-- each pick to a copy of the state to predict the next ones, the way Hekili shows 2-3 icons ahead.
local _, ns = ...

local Rotation = {}
ns.Rotation = Rotation

local READY_SLACK = 0.05 -- a cooldown ending within this many seconds counts as ready
local WAND_STEP = 0.5 -- queue look-ahead while wanding: step and limit (seconds)
local WAND_LOOKAHEAD = 20

-- Helpers ------------------------------------------------------------------------

local helperMeta = {}
helperMeta.__index = helperMeta

function helperMeta:known(family)
	return self.state.spells[family] ~= nil
end

function helperMeta:ready(family)
	local s = self.state
	return s.spells[family] ~= nil and (s.readyAt[family] or 0) <= s.now + READY_SLACK
end

function helperMeta:cooldownRemaining(family)
	local s = self.state
	return math.max(0, (s.readyAt[family] or 0) - s.now)
end

--- True when family (a spell with a cooldown) was cast within the last `secs` seconds.
function helperMeta:recentlyCast(family, secs)
	local entry = self.state.spells[family]
	if not entry or (entry.cooldown or 0) <= 0 then
		return false
	end
	return self:cooldownRemaining(family) > entry.cooldown - secs
end

function helperMeta:dotRemaining(family)
	local s = self.state
	return math.max(0, (s.dots[family] or 0) - s.now)
end

function helperMeta:dotActive(family)
	return self:dotRemaining(family) > 0
end

--- Mana in percent; 100 when unknown so mana rules never block a guess.
function helperMeta:manaPct()
	local s = self.state
	if not s.mana or not s.manaMax or s.manaMax <= 0 then
		return 100
	end
	return 100 * s.mana / s.manaMax
end

function helperMeta:flag(name)
	return self.state.flags[name] and true or false
end

function helperMeta:setting(name)
	return self.state.settings and self.state.settings[name]
end

local helper = setmetatable({}, helperMeta) -- one reused helper; Next() points it at the state

local function helperFor(state)
	helper.state = state
	return helper
end

-- State copies (reused tables: Queue runs several times a second) -------------------

local function copyInto(dst, src)
	for k in pairs(dst) do
		dst[k] = nil
	end
	for k, v in pairs(src) do
		dst[k] = v
	end
	return dst
end

local scratch = { readyAt = {}, dots = {} }

local function copyState(state)
	scratch.now = state.now
	scratch.spells = state.spells
	scratch.low = state.low
	scratch.mana = state.mana
	scratch.manaMax = state.manaMax
	scratch.flags = state.flags
	scratch.settings = state.settings
	scratch.durationBonus = state.durationBonus
	copyInto(scratch.readyAt, state.readyAt)
	copyInto(scratch.dots, state.dots)
	return scratch
end

-- Evaluation ---------------------------------------------------------------------

--- Returns the spell entry a rule would cast, or nil when its spell is unknown.
local function entryFor(state, rule)
	if rule.rank == "low" then
		return state.low and state.low[rule.family]
	end
	return state.spells[rule.family]
end

local function affordable(state, entry)
	if not state.mana or not entry.cost then
		return true
	end
	return state.mana >= entry.cost
end

--- The first matching rule: returns rule, entry (the spell rank to press). Nil when nothing matches.
function Rotation.Next(rules, state)
	local h = helperFor(state)
	for _, rule in ipairs(rules) do
		local entry = entryFor(state, rule)
		if entry and affordable(state, entry) and (rule.family == "wand" or h:ready(rule.family)) then
			local ok, pass = true, true
			if rule.when then
				ok, pass = pcall(rule.when, h)
			end
			if ok and pass then
				return rule, entry
			end
		end
	end
	return nil
end

--- Applies a cast of `entry` (family) to state: cooldown, damage over time, mana and the time it takes.
--- A rule with `marks = "name"` sets that lasting mark (a form or buff) so the queue does not repeat it.
function Rotation.Apply(state, family, entry, rule)
	if rule and rule.marks then
		state.dots[rule.marks] = math.huge
	end
	local cast = entry.cast or 0
	local gcd = entry.gcd or 1.5
	local start = state.now
	local landed = entry.channel and start or (start + cast)
	if (entry.cooldown or 0) > 0 then
		state.readyAt[family] = landed + entry.cooldown
	end
	if (entry.duration or 0) > 0 and not entry.channel then
		local bonus = state.durationBonus and state.durationBonus[family] or 0
		state.dots[family] = landed + entry.duration + bonus
	end
	if state.mana and entry.cost then
		state.mana = math.max(0, state.mana - entry.cost)
	end
	state.now = start + math.max(cast, gcd)
	return state
end

--- Predicts up to `count` picks. Fills `out` (reused) with entries; returns out and the number found.
function Rotation.Queue(rules, state, count, out)
	out = out or {}
	for i = #out, 1, -1 do
		out[i] = nil
	end
	local sim = copyState(state)
	local i = 0
	while i < count do
		local rule, entry = Rotation.Next(rules, sim)
		if not rule then
			break
		end
		i = i + 1
		out[i] = entry
		if rule.family == "wand" then
			-- The wand shoots on its own until a spell is due: show that spell next, not the wand again.
			local nextRule, nextEntry
			local limit = sim.now + WAND_LOOKAHEAD
			repeat
				sim.now = sim.now + WAND_STEP
				nextRule, nextEntry = Rotation.Next(rules, sim)
			until (nextRule and nextRule.family ~= "wand") or sim.now >= limit
			if not nextRule or nextRule.family == "wand" or i >= count then
				break
			end
			i = i + 1
			out[i] = nextEntry
			Rotation.Apply(sim, nextRule.family, nextEntry, nextRule)
		else
			Rotation.Apply(sim, rule.family, entry, rule)
		end
	end
	return out, #out
end

--- Builds the spell lookup from generated class data: family key -> best rank known at `isKnown`.
--- Returns spells (best rank per family) and low (rank `lowRank[family]` or the lowest known).
function Rotation.KnownSpells(classData, isKnown, lowRanks, spells, low)
	spells = spells or {}
	low = low or {}
	for k in pairs(spells) do
		spells[k] = nil
	end
	for k in pairs(low) do
		low[k] = nil
	end
	for family, info in pairs(classData.spells) do
		local best, wanted, lowest
		for _, r in ipairs(info.ranks) do
			if isKnown(r.id) then
				best = r
				lowest = lowest or r
				if lowRanks and lowRanks[family] == r.rank then
					wanted = r
				end
			end
		end
		if best then
			spells[family] = {
				id = best.id,
				rank = best.rank,
				cost = best.cost,
				cast = best.cast,
				cooldown = info.cooldown,
				duration = info.duration,
				gcd = info.gcd,
				channel = info.channel,
			}
			local lowEntry = wanted or lowest
			if lowRanks and lowRanks[family] and lowEntry.id ~= best.id then
				low[family] = {
					id = lowEntry.id,
					rank = lowEntry.rank,
					cost = lowEntry.cost,
					cast = lowEntry.cast,
					cooldown = info.cooldown,
					duration = info.duration,
					gcd = info.gcd,
					channel = info.channel,
				}
			end
		end
	end
	return spells, low
end

--- Index spellID -> { family, entry rank data } for every rank in the class data.
function Rotation.IndexSpells(classData, index)
	index = index or {}
	for family, info in pairs(classData.spells) do
		for _, r in ipairs(info.ranks) do
			index[r.id] = { family = family, rank = r.rank, cost = r.cost, cast = r.cast }
		end
	end
	return index
end
