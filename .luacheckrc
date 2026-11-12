-- TOA Rotation Helper — lint (§wow-addon/tooling)
std = "lua51"
max_line_length = 120
self = false
exclude_files = { "Libs/", ".release/", "tests/", "tools/" }

-- The only globals the addon may define (§wow-addon/structure).
globals = {
	"TOARotationHelperDB",
	"TOARotationHelper_OnAddonCompartmentClick",
	"SLASH_TOAROTATIONHELPER1",
	"SLASH_TOAROTATIONHELPER2",
	SlashCmdList = { fields = { "TOAROTATIONHELPER" } },
}

read_globals = {
	"wipe",
	"strtrim",
	"issecretvalue",
	"ActionBarButtonEventsFrame",
	"C_ActionBar",
	"C_AddOns",
	"C_AssistedCombat",
	"C_Spell",
	"CreateFrame",
	"GetBindingKey",
	"GetSpellBaseCooldown",
	"InCombatLockdown",
	"IsPlayerSpell",
	"MinimalSliderWithSteppersMixin",
	"Settings",
	"UIParent",
	"GetTime",
	"GetNumTalentTabs",
	"GetNumTalents",
	"GetTalentInfo",
	"GetShapeshiftForm",
	"HasWandEquipped",
	"IsSpellKnown",
	"IsAutoRepeatSpell",
	"GetInventoryItemID",
	"C_Item",
	"UnitLevel",
	"UnitStat",
	"UnitRace",
	"UnitHealthMax",
	"GetCritChance",
	"GetSpellCritChance",
	"GetSpellBonusDamage",
	"GetInventoryItemLink",
	"C_ClassTalents",
	"C_Traits",
	"date",
	"STANDARD_TEXT_FONT",
	"UnitCastingInfo",
	"UnitChannelInfo",
	"UnitClass",
	"UnitGUID",
	"UnitPower",
	"UnitPowerMax",
}
