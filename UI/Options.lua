-- Options: Blizzard Settings panel (Esc > Options > AddOns > TOA Rotation Helper) (§wow-addon/ui).
local _, ns = ...

local Options = {}
ns.Options = Options
table.insert(ns.modules, Options)

local L = ns.L
local category

local function onChanged(setting, fn)
	if setting.SetValueChangedCallback then
		setting:SetValueChangedCallback(fn)
	elseif Settings.SetOnValueChangedCallback then
		Settings.SetOnValueChangedCallback(setting:GetVariable(), fn)
	end
end

local function addCheckbox(key, label, tooltip)
	local settings, defaults = ns.db.settings, ns.defaults
	local setting = Settings.RegisterAddOnSetting(category, "TOARotationHelper_" .. key, key, settings,
		Settings.VarType.Boolean, label, defaults[key])
	onChanged(setting, ns.SettingsChanged)
	Settings.CreateCheckbox(category, setting, tooltip)
end

local function addSlider(key, label, tooltip, low, high, step, format)
	local settings, defaults = ns.db.settings, ns.defaults
	local setting = Settings.RegisterAddOnSetting(category, "TOARotationHelper_" .. key, key, settings,
		Settings.VarType.Number, label, defaults[key])
	onChanged(setting, ns.SettingsChanged)
	local options = Settings.CreateSliderOptions(low, high, step)
	if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return format:format(value)
		end)
	end
	Settings.CreateSlider(category, setting, options, tooltip)
end

local function addModeDropdown()
	local rotation = ns.Tracker and ns.Tracker.rotation
	if not (rotation and Settings.CreateDropdown and Settings.CreateControlTextContainer) then
		return
	end
	local settings, defaults = ns.db.settings, ns.defaults
	local setting = Settings.RegisterAddOnSetting(category, "TOARotationHelper_rotationMode", "rotationMode",
		settings, Settings.VarType.String, L.OPT_MODE, defaults.rotationMode)
	onChanged(setting, ns.SettingsChanged)
	local function options()
		local container = Settings.CreateControlTextContainer()
		container:Add("auto", L.OPT_MODE_AUTO)
		for _, name in ipairs(rotation.order) do
			container:Add(name, name:sub(1, 1):upper() .. name:sub(2))
		end
		return container:GetData()
	end
	Settings.CreateDropdown(category, setting, options, L.OPT_MODE_TIP)
end

local function build()
	category = Settings.RegisterVerticalLayoutCategory(L.ADDON_TITLE)
	pcall(addModeDropdown)
	addCheckbox("shown", L.OPT_SHOWN, L.OPT_SHOWN_TIP)
	addCheckbox("locked", L.OPT_LOCKED, L.OPT_LOCKED_TIP)
	addCheckbox("combatOnly", L.OPT_COMBAT_ONLY, L.OPT_COMBAT_ONLY_TIP)
	addCheckbox("showKeybind", L.OPT_KEYBIND, L.OPT_KEYBIND_TIP)
	addCheckbox("showRangeTint", L.OPT_RANGE, L.OPT_RANGE_TIP)
	addCheckbox("showCooldowns", L.OPT_COOLDOWNS, L.OPT_COOLDOWNS_TIP)
	addSlider("queueCount", L.OPT_QUEUE, L.OPT_QUEUE_TIP, 0, 3, 1, "%d")
	addSlider("saveManaPct", L.OPT_SAVE_MANA, L.OPT_SAVE_MANA_TIP, 0, 60, 5, "%d")
	addSlider("historyCount", L.OPT_HISTORY, L.OPT_HISTORY_TIP, 0, 6, 1, "%d")
	addSlider("scale", L.OPT_SCALE, L.OPT_SCALE_TIP, 0.5, 2, 0.05, "%.2f")
	addSlider("updateRateMs", L.OPT_RATE, L.OPT_RATE_TIP, 50, 500, 10, "%d")
	Settings.RegisterAddOnCategory(category)
end

function Options:Init()
	if not Settings or not Settings.RegisterVerticalLayoutCategory then
		return
	end
	local ok, err = pcall(build)
	if not ok then
		category = nil
		ns.Print("settings panel unavailable: " .. tostring(err))
	end
end

function Options:Open()
	if category and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	else
		SlashCmdList.TOAROTATIONHELPER("help")
	end
end
