-- Keybinds: finds the key bound to the action button that holds a spell, like Hekili's keybind text.
--
-- C_ActionBar.FindSpellActionButtons is NeverSecret in Forever. The slot -> binding map is read (never
-- written) from Blizzard's own action buttons, so nothing protected is touched (§wow-addon/restrictions).
local _, ns = ...

local Keybinds = {}
ns.Keybinds = Keybinds
table.insert(ns.modules, Keybinds)

local cache = {} -- [spellID] = text or false
local slotBinding = {} -- [action slot] = binding text
local slotsDirty = true

local function bindingTextForButton(button)
	local action = button.bindingAction
	if type(action) ~= "string" or action == "" then
		return nil
	end
	local key = GetBindingKey(action)
	if not key and button.GetName and button:GetName() then
		key = GetBindingKey("CLICK " .. button:GetName() .. ":LeftButton")
	end
	return ns.Util.AbbreviateKey(key)
end

local function rebuildSlots()
	wipe(slotBinding)
	slotsDirty = false
	local events = ActionBarButtonEventsFrame
	if not (events and type(events.frames) == "table") then
		return
	end
	for _, button in pairs(events.frames) do
		local slot = button.action
		if ns.IsPlain(slot) and type(slot) == "number" and button:IsVisible() and not slotBinding[slot] then
			local text = bindingTextForButton(button)
			if text then
				slotBinding[slot] = text
			end
		end
	end
end

local function lookup(spellID)
	if not (C_ActionBar and C_ActionBar.FindSpellActionButtons) then
		return nil
	end
	local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, spellID)
	if not ok or type(slots) ~= "table" then
		return nil
	end
	for _, slot in ipairs(slots) do
		if ns.IsPlain(slot) and slotBinding[slot] then
			return slotBinding[slot]
		end
	end
	return nil
end

--- Returns the short key text for spellID, or nil. Secret IDs return nil (they cannot be used as keys).
function Keybinds:Get(spellID)
	if spellID == nil or not ns.IsPlain(spellID) then
		return nil
	end
	local cached = cache[spellID]
	if cached ~= nil then
		return cached or nil
	end
	if slotsDirty then
		rebuildSlots()
	end
	local text = lookup(spellID)
	-- Forever spells have ranks: the bar may hold another rank of the same spell. Only for the best
	-- rank: a mana-saving low rank must not show the key of the full-cost rank.
	local tracker = ns.Tracker
	local info = not text and tracker and tracker.index[spellID]
	local best = info and tracker.spells[info.family]
	local family = best and best.id == spellID and tracker.data.spells[info.family]
	if family then
		for i = #family.ranks, 1, -1 do
			local id = family.ranks[i].id
			if id ~= spellID then
				text = lookup(id)
				if text then
					break
				end
			end
		end
	end
	-- The recommendation can be an override (e.g. a talent-replaced spell) while the bar holds the base spell.
	if not text and C_Spell and C_Spell.GetBaseSpell then
		local okBase, baseID = pcall(C_Spell.GetBaseSpell, spellID)
		if okBase and ns.IsPlain(baseID) and type(baseID) == "number" and baseID ~= spellID then
			text = lookup(baseID)
		end
	end
	cache[spellID] = text or false
	return text
end

function Keybinds:Invalidate()
	wipe(cache)
	slotsDirty = true
	ns.Fire("KEYBINDS_CHANGED")
end

function Keybinds:Init()
	local function invalidate()
		self:Invalidate()
	end
	for _, event in ipairs({
		"UPDATE_BINDINGS",
		"ACTIONBAR_SLOT_CHANGED",
		"ACTIONBAR_PAGE_CHANGED",
		"UPDATE_BONUS_ACTIONBAR",
		"UPDATE_SHAPESHIFT_FORM",
		"PLAYER_ENTERING_WORLD",
		"SPELLS_CHANGED",
	}) do
		ns.RegisterEvent(self, event, invalidate)
	end
end
