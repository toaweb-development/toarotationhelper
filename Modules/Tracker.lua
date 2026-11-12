-- Tracker: follows the player's own casts to know what Forever hides in combat.
--
-- Cooldowns, mana and the target's debuffs are secret in Forever combat, but the player's own casts
-- (UNIT_SPELLCAST_*) are not. From them and the generated spell data (Data/<Class>.lua) the tracker keeps:
--   * each spell's cooldown (cast time + cooldown from the data, synced with the real value out of combat)
--   * own damage over time on each target (cast time + duration + talents)
--   * an estimate of mana (real value whenever readable, minus the cost of each cast otherwise)
--   * the spell being cast right now, so the recommendation is for what comes AFTER it (like Hekili)
-- Every value from the game is checked with ns.IsPlain before it is used (§wow-addon/restrictions).
local _, ns = ...

local Tracker = {
	class = nil, -- "PRIEST", ...
	rotation = nil, -- ns.Rotations[class]
	data = nil, -- ns.Data[class]
	spells = {}, -- best known rank per family (ns.Rotation.KnownSpells)
	low = {}, -- low ranks per family
	index = {}, -- spellID -> { family, rank, cost, cast }
	readyAt = {}, -- family -> time the cooldown ends
	dotsByTarget = {}, -- target key -> { family -> expires }
	flags = {}, -- shadowform, wand, ...
	durationBonus = {}, -- family -> extra seconds from talents
	castMod = {}, -- family -> cast time change in seconds from talents
	costMult = {}, -- family -> mana cost multiplier from talents
	talentRanks = {}, -- data talent key -> rank
	allTalents = {}, -- talent name -> rank, every talent the client reported
	talentMethod = "none",
	gcdStart = 0,
	gcdDuration = 0,
	casting = nil, -- { family, entry, startTime, endTime, channel }
	mana = nil,
	manaMax = nil,
	manaIsEstimate = false,
	freeNextCast = false, -- Inner Focus
	targetKey = "target",
	lastCasts = {}, -- debug: recent { time, family, id }
}
ns.Tracker = Tracker
table.insert(ns.modules, Tracker)

local WAND_SPELL = 5019 -- Shoot
local MANA = 0 -- Enum.PowerType.Mana

local function now()
	return GetTime()
end

local function plainNumber(v)
	return ns.IsPlain(v) and type(v) == "number" and v or nil
end

local function isKnown(spellID)
	if IsPlayerSpell then
		local ok, known = pcall(IsPlayerSpell, spellID)
		if ok and ns.IsPlain(known) then
			return known and true or false
		end
	end
	if IsSpellKnown then
		local ok, known = pcall(IsSpellKnown, spellID)
		if ok and ns.IsPlain(known) then
			return known and true or false
		end
	end
	return false
end

-- Knowledge: ranks, talents, wand ----------------------------------------------------

-- Talents ----------------------------------------------------------------------------------
-- Forever's talent UI may be the classic one (GetTalentInfo) or a trait tree (C_Traits). Both are read
-- out of combat into name -> rank; the method used shows in /toarot talents.

--- Classic talent API: fills out[name] = rank. Returns true when the API answered.
local function readClassicTalents(out)
	if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then
		return false
	end
	local okTabs, tabs = pcall(GetNumTalentTabs)
	if not okTabs or not ns.IsPlain(tabs) or not tabs or tabs == 0 then
		return false
	end
	local any = false
	for tab = 1, tabs do
		local okNum, count = pcall(GetNumTalents, tab)
		for i = 1, (okNum and ns.IsPlain(count) and count) or 0 do
			local ok, name, _, _, _, rank = pcall(GetTalentInfo, tab, i)
			if ok and ns.IsPlain(name) and type(name) == "string" and ns.IsPlain(rank) then
				out[name] = rank or 0
				any = true
			end
		end
	end
	return any
end

--- Trait-tree talent API (C_ClassTalents / C_Traits): fills out[name] = rank. Returns true when it answered.
local function readTraitTalents(out)
	if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo) then
		return false
	end
	local okConfig, configID = pcall(C_ClassTalents.GetActiveConfigID)
	if not okConfig or not ns.IsPlain(configID) or not configID then
		return false
	end
	local okInfo, config = pcall(C_Traits.GetConfigInfo, configID)
	if not okInfo or type(config) ~= "table" or type(config.treeIDs) ~= "table" then
		return false
	end
	local any = false
	for _, treeID in ipairs(config.treeIDs) do
		local okNodes, nodes = pcall(C_Traits.GetTreeNodes, treeID)
		for _, nodeID in ipairs(okNodes and nodes or {}) do
			local okNode, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
			if okNode and type(node) == "table" then
				local rank = node.currentRank or node.ranksPurchased or 0
				local entryID = node.activeEntry and node.activeEntry.entryID or (node.entryIDs and node.entryIDs[1])
				local okEntry, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
				local definitionID = okEntry and type(entry) == "table" and entry.definitionID
				local okDef, definition = pcall(C_Traits.GetDefinitionInfo, definitionID)
				local spellID = okDef and type(definition) == "table" and definition.spellID
				local name = spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
				if ns.IsPlain(name) and type(name) == "string" and ns.IsPlain(rank) then
					out[name] = math.max(out[name] or 0, rank)
					any = true
				end
			end
		end
	end
	return any
end

--- Reads all talents into self.allTalents (name -> rank) and the data's talents into self.talentRanks.
function Tracker:ReadTalents()
	local all = self.allTalents
	wipe(all)
	if readClassicTalents(all) then
		self.talentMethod = "classic"
	elseif readTraitTalents(all) then
		self.talentMethod = "traits"
	else
		self.talentMethod = "known spells"
	end
	wipe(self.talentRanks)
	for key, talent in pairs(self.data.talents or {}) do
		local rank = all[talent.name]
		if rank == nil and self.talentMethod == "known spells" then
			-- No talent API: the talent's spell being known means it is taken; assume the full talent.
			rank = isKnown(talent.id) and talent.maxRank or 0
		end
		self.talentRanks[key] = math.min(rank or 0, talent.maxRank)
	end
end

--- Applies the talents to the known spells: cast time, cooldown, cost, DoT duration; flags for the rest.
function Tracker:ApplyTalents()
	wipe(self.durationBonus)
	wipe(self.castMod)
	wipe(self.costMult)
	for key, talent in pairs(self.data.talents or {}) do
		local rank = self.talentRanks[key] or 0
		local value = talent.valueAtMax * rank / talent.maxRank
		if talent.kind == "flag" then
			self.flags[key] = rank
		elseif rank > 0 then
			for _, family in ipairs(talent.families) do
				local best, low = self.spells[family], self.low[family]
				if talent.kind == "duration" then
					self.durationBonus[family] = (self.durationBonus[family] or 0) + value
				elseif talent.kind == "cast" then
					self.castMod[family] = (self.castMod[family] or 0) + value
					for _, entry in ipairs({ best, low }) do
						if entry and (entry.cast or 0) > 0 then
							entry.cast = math.max(0, entry.cast + value)
						end
					end
				elseif talent.kind == "cooldown" then
					for _, entry in ipairs({ best, low }) do
						if entry and (entry.cooldown or 0) > 0 then
							entry.cooldown = math.max(0, entry.cooldown + value)
						end
					end
				elseif talent.kind == "costPct" then
					self.costMult[family] = (self.costMult[family] or 1) * (1 + value / 100)
					for _, entry in ipairs({ best, low }) do
						if entry and entry.cost then
							entry.cost = math.floor(entry.cost * (1 + value / 100) + 0.5)
						end
					end
				end
			end
		end
	end
end

function Tracker:RefreshKnowledge()
	if not self.data then
		return
	end
	ns.Rotation.KnownSpells(self.data, isKnown, self.rotation.lowRanks, self.spells, self.low)
	if not ns.inCombat then
		self:ReadTalents() -- talent ranks may be secret in combat; keep the last ones read
	end
	self:ApplyTalents()

	local hasWand = false
	if HasWandEquipped then
		local ok, result = pcall(HasWandEquipped)
		hasWand = ok and ns.IsPlain(result) and result and true or false
	elseif GetInventoryItemID and C_Item and C_Item.GetItemInfoInstant then
		-- Ranged slot (18) holds a wand: item class Weapon (2), subclass Wand (19).
		local ok, itemID = pcall(GetInventoryItemID, "player", 18)
		if ok and ns.IsPlain(itemID) and itemID then
			local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
			hasWand = classID == 2 and subclassID == 19
		end
	end
	self.flags.wand = hasWand
	if hasWand then
		self.spells.wand = { id = WAND_SPELL, rank = 0, cost = 0, cast = 0, cooldown = 0, duration = 0, gcd = 1.5 }
	end
	self:RefreshForm()
	ns.Fire("ROTATION_CHANGED")
end

function Tracker:RefreshForm()
	if not GetShapeshiftForm then
		return
	end
	local ok, form = pcall(GetShapeshiftForm)
	if ok and ns.IsPlain(form) then
		self.flags.shadowform = (form or 0) > 0 and self.spells.shadowform ~= nil
	end
end

--- Reads real cooldowns and mana while they are readable (out of combat) to correct the estimates.
function Tracker:SyncFromGame()
	local t = now()
	if C_Spell and C_Spell.GetSpellCooldown then
		for family, entry in pairs(self.spells) do
			if (entry.cooldown or 0) > 0 then
				local ok, info = pcall(C_Spell.GetSpellCooldown, entry.id)
				if ok and type(info) == "table" then
					local start, duration = plainNumber(info.startTime), plainNumber(info.duration)
					-- Ignore the global cooldown; only real cooldowns move readyAt.
					if start and duration and duration > 1.6 then
						self.readyAt[family] = start + duration
					elseif start and duration == 0 then
						self.readyAt[family] = math.min(self.readyAt[family] or 0, t)
					end
				end
			end
		end
	end
	self:ReadMana()
end

function Tracker:ReadMana()
	if not UnitPower then
		return
	end
	local okMax, max = pcall(UnitPowerMax, "player", MANA)
	max = okMax and plainNumber(max)
	if max and max > 0 then
		self.manaMax = max
	end
	local ok, value = pcall(UnitPower, "player", MANA)
	value = ok and plainNumber(value)
	if value then
		self.mana = value
		self.manaIsEstimate = false
	elseif self.mana then
		self.manaIsEstimate = true
	end
end

-- Targets ------------------------------------------------------------------------------

function Tracker:CurrentDots()
	local key = self.targetKey
	local dots = self.dotsByTarget[key]
	if not dots then
		dots = {}
		self.dotsByTarget[key] = dots
	end
	return dots
end

function Tracker:OnTargetChanged()
	local guid
	if UnitGUID then
		local ok, value = pcall(UnitGUID, "target")
		if ok and ns.IsPlain(value) then
			guid = value
		end
	end
	if guid then
		self.targetKey = guid -- opaque key only (§wow-addon/restrictions)
	else
		-- No readable identity: start fresh for the new target.
		self.targetKey = "target"
		self.dotsByTarget.target = nil
	end
end

-- Casts ----------------------------------------------------------------------------------

local function entryForSpell(self, spellID)
	if not ns.IsPlain(spellID) or type(spellID) ~= "number" then
		return nil
	end
	local info = self.index[spellID]
	if not info then
		return nil
	end
	local family = self.spells[info.family]
	if not family then
		return nil
	end
	-- Same family data, but the cost and cast time of the rank actually cast.
	return info.family, family, info
end

function Tracker:OnCastStart(spellID, channel)
	local family, entry, info = entryForSpell(self, spellID)
	if not family then
		return
	end
	local t = now()
	local endTime
	local fn = channel and UnitChannelInfo or UnitCastingInfo
	if fn then
		local ok, _, _, _, _, endMs = pcall(fn, "player")
		endMs = ok and plainNumber(endMs)
		if endMs then
			endTime = endMs / 1000
		end
	end
	local cast = channel and (entry.duration or info.cast) or math.max(0, info.cast + (self.castMod[family] or 0))
	self.casting = {
		family = family,
		entry = entry,
		info = info,
		startTime = t,
		endTime = endTime or (t + (cast or 0)),
		channel = channel,
	}
	if (entry.gcd or 0) > 0 then
		self.gcdStart, self.gcdDuration = t, entry.gcd
	end
end

function Tracker:OnCastStop()
	if self.casting and not self.casting.channel then
		self.casting = nil
	end
end

function Tracker:OnChannelStop()
	if self.casting and self.casting.channel then
		self.casting = nil
	end
end

function Tracker:OnCastSucceeded(spellID)
	local family, entry, info = entryForSpell(self, spellID)
	if not family then
		return
	end
	local t = now()
	if (entry.cooldown or 0) > 0 then
		self.readyAt[family] = t + entry.cooldown
	end
	if (entry.duration or 0) > 0 and not entry.channel then
		self:CurrentDots()[family] = t + entry.duration + (self.durationBonus[family] or 0)
	end
	if family == "shadowform" then
		self.flags.shadowform = true
	end
	-- Instant spells start the global cooldown here; cast-time spells started it at OnCastStart.
	if (info.cast or 0) == 0 and (entry.gcd or 0) > 0 then
		self.gcdStart, self.gcdDuration = t, entry.gcd
	end
	if self.manaIsEstimate and self.mana then
		local cost = (info.cost or 0) * (self.costMult[family] or 1)
		if self.freeNextCast and cost > 0 then
			cost = 0
			self.freeNextCast = false
		end
		self.mana = math.max(0, self.mana - cost)
	end
	if family == "innerfocus" then
		self.freeNextCast = true
	end
	if self.casting and not self.casting.channel and self.casting.family == family then
		self.casting = nil
	end
	ns.Util.PushFront(self.lastCasts, family .. ":" .. tostring(spellID), 8)
end

-- Snapshot for the rotation ------------------------------------------------------------------

local snapshot = { readyAt = {}, dots = {}, settings = {} }

--- Fills and returns the rotation state for "the moment the next spell can be pressed".
function Tracker:Snapshot()
	local s = snapshot
	local t = now()
	s.now = t
	s.spells = self.spells
	s.low = self.low
	s.flags = self.flags
	s.durationBonus = self.durationBonus
	s.mana = self.mana
	s.manaMax = self.manaMax
	s.settings.saveManaPct = ns.db.settings.saveManaPct
	wipe(s.readyAt)
	for k, v in pairs(self.readyAt) do
		s.readyAt[k] = v
	end
	wipe(s.dots)
	for k, v in pairs(self:CurrentDots()) do
		s.dots[k] = v
	end

	local casting = self.casting
	if casting and casting.endTime > t then
		if casting.channel then
			s.now = casting.endTime
		else
			-- Treat the cast in progress as done: its cooldown, DoT and cost apply at its end.
			s.now = casting.startTime
			ns.Rotation.Apply(s, casting.family, casting.entry)
			s.now = math.max(s.now, casting.endTime)
		end
	end
	s.now = math.max(s.now, self.gcdStart + self.gcdDuration)
	return s
end

--- start, duration of the tracked cooldown for spellID (plain numbers), or nil.
function Tracker:Cooldown(spellID)
	local family = ns.IsPlain(spellID) and self.index[spellID] and self.index[spellID].family
	local entry = family and self.spells[family]
	if not entry or (entry.cooldown or 0) <= 0 then
		return nil
	end
	local ready = self.readyAt[family]
	if not ready or ready <= now() then
		return nil
	end
	return ready - entry.cooldown, entry.cooldown
end

function Tracker:GCD()
	if self.gcdStart + self.gcdDuration > now() then
		return self.gcdStart, self.gcdDuration
	end
	return nil
end

--- Spell IDs (best known rank) of tracked families with a cooldown of 8 s or more, for the cooldown row.
function Tracker:CooldownSpells(out)
	wipe(out)
	if not self.data then
		return out
	end
	for family, entry in pairs(self.spells) do
		if (entry.cooldown or 0) >= 8 then
			table.insert(out, entry.id)
		end
	end
	table.sort(out)
	return out
end

-- Start-up -----------------------------------------------------------------------------------

function Tracker:Init()
	local _, class = UnitClass("player")
	self.class = class
	self.rotation = ns.Rotations and ns.Rotations[class]
	self.data = self.rotation and self.rotation.data()
	if not self.data then
		return -- no own rotation for this class yet; Engine falls back to Assisted Combat
	end
	ns.Rotation.IndexSpells(self.data, self.index)

	local function refresh()
		self:RefreshKnowledge()
		if not ns.inCombat then
			self:SyncFromGame()
		end
	end
	for _, event in ipairs({
		"PLAYER_ENTERING_WORLD",
		"SPELLS_CHANGED",
		"PLAYER_LEVEL_UP",
		"CHARACTER_POINTS_CHANGED",
		"PLAYER_EQUIPMENT_CHANGED",
	}) do
		ns.RegisterEvent(self, event, refresh)
	end
	ns.RegisterEvent(self, "UPDATE_SHAPESHIFT_FORM", function()
		self:RefreshForm()
	end)
	ns.RegisterEvent(self, "PLAYER_TARGET_CHANGED", function()
		self:OnTargetChanged()
	end)
	ns.RegisterEvent(self, "PLAYER_REGEN_DISABLED", function()
		-- Last readable values before they turn secret.
		self:SyncFromGame()
	end)
	ns.RegisterEvent(self, "PLAYER_REGEN_ENABLED", function()
		wipe(self.dotsByTarget)
		self:SyncFromGame()
	end)
	ns.RegisterEvent(self, "SPELL_UPDATE_COOLDOWN", function()
		if not ns.inCombat then
			self:SyncFromGame()
		end
	end)

	ns.RegisterPlayerEvent(self, "UNIT_POWER_UPDATE", function()
		self:ReadMana()
	end)
	ns.RegisterPlayerEvent(self, "UNIT_SPELLCAST_START", function(_, _, _, spellID)
		self:OnCastStart(spellID, false)
	end)
	ns.RegisterPlayerEvent(self, "UNIT_SPELLCAST_CHANNEL_START", function(_, _, _, spellID)
		self:OnCastStart(spellID, true)
	end)
	for _, event in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
		ns.RegisterPlayerEvent(self, event, function()
			self:OnCastStop()
		end)
	end
	ns.RegisterPlayerEvent(self, "UNIT_SPELLCAST_CHANNEL_STOP", function()
		self:OnChannelStop()
	end)
	ns.RegisterPlayerEvent(self, "UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
		self:OnCastSucceeded(spellID)
	end)

	self:OnTargetChanged()
	refresh()
end
