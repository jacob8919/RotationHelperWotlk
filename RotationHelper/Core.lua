local ADDON_NAME, ns = ...

local RH = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")
ns.RH = RH
_G.RotationHelper = RH

local Utils = ns.Utils
local GetTime, UnitClass = GetTime, UnitClass
local GetSpellInfo, debugstack, xpcall, wipe = GetSpellInfo, debugstack, xpcall, wipe
local tinsert, ipairs, pairs, lower = table.insert, ipairs, pairs, string.lower

RH.version = GetAddOnMetadata(ADDON_NAME, "Version") or "dev"

-- Class data registered by Classes/*.lua, keyed by class token.
ns.Classes = {}

-- Resolves localized spell names from IDs and records any IDs the client
-- doesn't know, so bad data is reported instead of silently ignored.
function ns.RegisterClass(classToken, data)
    data.classToken = classToken
    data.badSpellIds = {}
    data.abilityByName = {}
    for key, ability in pairs(ns.SharedAbilities or {}) do
        if data.abilities[key] == nil then data.abilities[key] = ability end
    end
    for key, aura in pairs(ns.SharedAuras or {}) do
        if data.auras[key] == nil then data.auras[key] = aura end
    end
    for key, ability in pairs(data.abilities) do
        ability.key = key
        if ability.id then
            ability.name = GetSpellInfo(ability.id)
            if ability.name then
                data.abilityByName[ability.name] = key
            else
                tinsert(data.badSpellIds, key .. " (" .. ability.id .. ")")
            end
        end
        -- Item abilities (no id) get their name from Engine/Items.lua.
        -- Every variant (e.g. each Judgement) counts as this ability when cast.
        for _, id in pairs(ability.variants or {}) do
            local name = GetSpellInfo(id)
            if name then
                data.abilityByName[name] = key
            else
                tinsert(data.badSpellIds, key .. " (" .. id .. ")")
            end
        end
    end
    for key, aura in pairs(data.auras) do
        aura.key = key
        for _, id in ipairs(aura.ids or { aura.id }) do
            if not GetSpellInfo(id) then tinsert(data.badSpellIds, key .. " (" .. id .. ")") end
        end
    end
    data.gcdSpellName = GetSpellInfo(data.gcdSpell)
    table.sort(data.badSpellIds)
    ns.Classes[classToken] = data
end

-- Default action lists registered by APLs/*.lua: ns.APLs[class][spec].
-- `options` lists the rotation's settings (Engine/APLOptions.lua).
ns.APLs = {}

local OPTION_TYPES = { range = true, toggle = true, select = true }

function ns.RegisterAPL(classToken, specKey, name, text, options)
    for _, decl in ipairs(options or {}) do
        local where = classToken .. " " .. specKey .. " option " .. tostring(decl.key)
        assert(type(decl.key) == "string" and decl.key:match("^[%w_]+$"), where .. ": bad key")
        assert(OPTION_TYPES[decl.type], where .. ": type must be range, toggle or select")
        assert(decl.name and decl.default ~= nil, where .. ": needs a name and a default")
        assert(decl.type ~= "select" or (decl.values and decl.values[decl.default]), where .. ": default not in values")
        assert(decl.type ~= "range" or (decl.min and decl.max), where .. ": needs min and max")
    end
    ns.APLs[classToken] = ns.APLs[classToken] or {}
    ns.APLs[classToken][specKey] = { name = name, text = text, options = options }
end

local AOE_MODES = { "auto", "single", "aoe" }

local defaults = {
    global = {
        versionCheck = true, -- tell me when players around me run a newer version (UI/VersionCheck.lua)
        newestVersion = nil, -- the newest version seen, if newer than ours
    },
    char = {
        specProfiles = {}, -- [talent group] = profile name (SpecProfiles.lua)
        reviews = {},      -- fight review summaries, newest last (Engine/Review.lua)
        damage = { abilities = {}, total = 0 }, -- damage per ability (Engine/DamageLog.lua)
    },
    profile = {
        enabled = true,
        paused = false,
        debug = false,
        updateInterval = 0.1, -- seconds between recommendation refreshes
        toggles = {
            cooldowns = true,
            cooldownsBossOnly = true, -- cooldowns only in boss fights (Engine/Bosses.lua)
            consumables = true, -- potions (see items.consumablesBossOnly)
            aoeMode = "auto", -- auto | single | aoe
        },
        customAPLs = {}, -- [class][spec] = APL text edited in the options
        aplOptions = {}, -- [class][spec][key] = rotation setting (Engine/APLOptions.lua)
        variants = {},   -- [ability key] = chosen variant, e.g. judgement = "wisdom"
        editor = {
            syntaxColors = true,
        },
        latency = {
            mode = "auto", -- auto (lag tolerance or latency) | fixed | off
            fixedMs = 100,
        },
        prepull = {
            enabled = true,
            -- Presence expected before a pull, per spec ("any" = don't check).
            -- 3.3.5 guides use Blood Presence for Frost and Unholy DPS.
            presence = { blood = "any", frost = "blood", unholy = "blood" },
        },
        burst = {
            extra = "", -- more burst buffs, names or spell IDs separated by commas
        },
        items = {
            trinkets = "offensive", -- suggest trinkets: offensive (use effects only) | all | none
            consumablesBossOnly = true, -- consumables only while targeting a boss or with boss frames up
            extraBosses = "",           -- more boss names, comma separated (Engine/Bosses.lua)
        },
        review = {
            enabled = true,
            autoShow = false,  -- open the review window after a fight (off: /rh review)
            minDuration = 20,  -- seconds; shorter fights aren't kept
        },
        threat = {
            enabled = true,
            threshold = 90, -- % of the threat needed to pull aggro
        },
        minimap = {
            show = true,
            angle = 200, -- degrees around the minimap
        },
        waste = {
            enabled = true,
            runes = true,      -- a rune pair with both runes ready
            power = true,      -- runic power, energy or rage near the maximum
            powerDeficit = 10, -- "near" = within this much of the maximum
            grace = 1.5,       -- seconds a cap may last before warning
        },
        display = {
            locked = false,
            scale = 1.0,
            numIcons = 4,
            iconSize = 50,
            queueScale = 0.8, -- queued icons relative to the main icon
            spacing = 4,
            direction = "RIGHT", -- RIGHT | LEFT | UP | DOWN
            hideOutOfCombat = false,
            showStatus = true, -- toggle states under the main icon
            pressFlash = true, -- flash the main icon when it can be pressed
            castSlot = true,   -- while casting: the spell being cast slides out beside the main icon
            interrupt = true,  -- interrupt icon while the target casts something interruptible
            shiftInteract = true, -- Shift: tooltips on the icons, clickable CD / AoE
            procGlow = true,   -- glow on icons that spend a proc (Killing Machine, Rime)
            procBadge = true,  -- the proc's icon in the corner when it's why an ability is recommended
            procSound = "none", -- PlaySound name for a new proc, or "none"
            holdIndicator = true, -- label what the main icon waits on when it's more than a GCD away
            alternative = true,   -- in-range alternative when the main ability is out of range
            runeBar = true,       -- runes above the icons, with their type after the predicted actions
            cooldownStrip = true, -- major cooldowns and trinkets with the time left
            timeline = false,     -- queued icons placed by when they're usable
            colors = {            -- see Display.COLOR_PRESETS
                outOfRange = { 1, 0.25, 0.25 },
                noResources = { 0.4, 0.5, 1 },
                waste = { 1, 0.5, 0 },
                threat = { 0.9, 0.1, 0.1 },
            },
            point = { "CENTER", "UIParent", "CENTER", 0, -150 },
            -- Dual display (like Hekili's): the main display shows the single
            -- target priority and a second one the AoE priority, side by side.
            dualDisplay = false,
            aoePoint = { "CENTER", "UIParent", "CENTER", 0, -240 },
            -- The AoE display's own size (spacing and direction follow the main display).
            aoeScale = 1.0,
            aoeIconSize = 50,
            aoeQueueScale = 0.8,
            aoeNumIcons = 4,
        },
    },
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function RH:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("RotationHelperDB", defaults, true)
    self.db.RegisterCallback(self, "OnProfileChanged", "OnConfigChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnConfigChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnConfigChanged")

    self:RegisterChatCommand("rh", "SlashCommand")
    self:RegisterChatCommand("rotationhelper", "SlashCommand")

    local _, class = UnitClass("player")
    self.playerClass = class
    self.classData = ns.Classes[class]
    self.classSupported = self.classData ~= nil
end

function RH:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "Invalidate")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatChanged")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatChanged")
    self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "OnTalentsChanged")
    self:RegisterEvent("CHARACTER_POINTS_CHANGED", "OnTalentsChanged")
    self:RegisterEvent("PLAYER_TARGET_CHANGED", "Invalidate")

    self:ResetPerf()
    self:StartUpdateLoop()

    if not self.classSupported then
        self:Print(("No rotation available for %s yet; the addon will stay idle."):format(self.playerClass or "?"))
    elseif #self.classData.badSpellIds > 0 then
        self:Print("Unknown spell IDs in class data: " .. table.concat(self.classData.badSpellIds, ", "))
    end
end

function RH:OnDisable()
    self:StopUpdateLoop()
end

---------------------------------------------------------------------------
-- Update loop
--
-- Modules register an updater with RH:RegisterUpdater(fn, order, name,
-- onError). The loop calls every updater, lowest order first, at most once
-- per `updateInterval`, and immediately on the next frame after something
-- calls RH:Invalidate(). The order is explicit because AceAddon r960
-- enables modules in no particular order.
--
-- Each updater runs protected: an error is recorded (see Errors below),
-- `onError` gets a chance to clean up, and the other updaters still run.
---------------------------------------------------------------------------
RH.UPDATE_ORDER = { TARGETS = 5, RECOMMEND = 10, WASTE = 20, THREAT = 22, PREPULL = 24, REVIEW = 25,
    DEFAULT = 50, DISPLAY = 100, INTERRUPT = 110 }

local updaters = {}
local updateFrame = CreateFrame("Frame")
updateFrame:Hide()

local elapsedSince = 0
local dirty = true

function RH:RegisterUpdater(fn, order, name, onError)
    tinsert(updaters, { fn = fn, order = order or RH.UPDATE_ORDER.DEFAULT, index = #updaters + 1,
        name = name or "updater", onError = onError })
    table.sort(updaters, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.index < b.index
    end)
end

function RH:Invalidate()
    dirty = true
end

function RH:IsActive()
    local p = self.db.profile
    return self.classSupported and p.enabled and not p.paused
end

-- Events like UNIT_AURA on the target can fire every frame in a raid; don't
-- update more than 20 times a second however often something changes.
local MIN_UPDATE_SPACING = 0.05

-- Cost of the update loop, for /rh perf. debugprofilestop() is a
-- millisecond clock that works without script profiling.
local debugprofilestop = debugprofilestop
local perf = { updates = 0, totalMs = 0, maxMs = 0, since = 0 }
RH.perf = perf

function RH:ResetPerf()
    perf.updates, perf.totalMs, perf.maxMs, perf.since = 0, 0, 0, GetTime()
    UpdateAddOnMemoryUsage()
    perf.memoryStart = GetAddOnMemoryUsage(ADDON_NAME)
end

---------------------------------------------------------------------------
-- Errors: a bug in one updater must not freeze the display or spam chat.
-- Unique errors (by message) are kept, the newest MAX_ERRORS of them; the
-- first occurrence prints one chat line, repeats only count. The display
-- shows a red "!" until /rh errors has been used.
---------------------------------------------------------------------------
local MAX_ERRORS = 20
RH.errors = {}          -- oldest first: { source, message, stack, count, first, last }
RH.unseenErrors = 0

function RH:RecordError(source, message, stack)
    local now = GetTime()
    for _, err in ipairs(self.errors) do
        if err.message == message and err.source == source then
            err.count = err.count + 1
            err.last = now
            return err
        end
    end
    local err = { source = source, message = message, stack = stack, count = 1, first = now, last = now }
    tinsert(self.errors, err)
    if #self.errors > MAX_ERRORS then table.remove(self.errors, 1) end
    self.unseenErrors = self.unseenErrors + 1
    self:Print(("|cffff4040Error in %s:|r %s (details: /rh errors)"):format(source, message))
    return err
end

function RH:ClearErrors()
    wipe(self.errors)
    self.unseenErrors = 0
end

-- xpcall in Lua 5.1 can't pass arguments, so the function and time go
-- through upvalues; this keeps the no-error path free of garbage.
local currentFn, currentNow
local function CallCurrent() return currentFn(RH, currentNow) end
local lastStack
local function CaptureStack(message)
    lastStack = debugstack(2, 12, 0)
    return message
end

local function RunUpdater(updater, now)
    currentFn, currentNow = updater.fn, now
    local ok, message = xpcall(CallCurrent, CaptureStack)
    if not ok then
        RH:RecordError(updater.name, tostring(message), lastStack)
        if updater.onError then pcall(updater.onError, RH) end
    end
end

local function RunUpdaters(now)
    local start = debugprofilestop()
    for _, updater in ipairs(updaters) do
        RunUpdater(updater, now)
    end
    local ms = debugprofilestop() - start
    perf.updates = perf.updates + 1
    perf.totalMs = perf.totalMs + ms
    if ms > perf.maxMs then perf.maxMs = ms end
end

updateFrame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < MIN_UPDATE_SPACING then return end
    if not dirty and elapsedSince < RH.db.profile.updateInterval then return end
    elapsedSince = 0
    dirty = false
    if RH:IsActive() then
        RunUpdaters(GetTime())
    end
end)

function RH:StartUpdateLoop()
    dirty = true
    updateFrame:Show()
end

function RH:StopUpdateLoop()
    updateFrame:Hide()
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------
-- InCombatLockdown() can still be false while PLAYER_REGEN_DISABLED fires,
-- so trust the event name.
function RH:OnCombatChanged(event)
    self.inCombat = event == "PLAYER_REGEN_DISABLED"
    self.combatStart = self.inCombat and GetTime() or nil
    self:SendMessage("ROTATIONHELPER_COMBAT_CHANGED", self.inCombat)
    self:Invalidate()
end

function RH:OnTalentsChanged()
    self:SendMessage("ROTATIONHELPER_TALENTS_CHANGED")
    self:Invalidate()
end

-- Debuffs whose uptime the review and simulator report: classData.reviewDebuffs,
-- either one list for the class or one per spec ({ arms = { "rend" } }).
local NO_DEBUFFS = {}
function RH:ReviewDebuffs()
    local list = self.classData and self.classData.reviewDebuffs
    if not list then return NO_DEBUFFS end
    if list[1] then return list end
    return list[ns.Spec and ns.Spec.key or ""] or NO_DEBUFFS
end

function RH:OnConfigChanged()
    if ns.Burst then ns.Burst.built = false end -- the burst list may have changed
    if ns.Bosses then ns.Bosses.built = false end -- and the extra boss names
    self:SendMessage("ROTATIONHELPER_CONFIG_CHANGED")
    self:Invalidate()
end

-- For changes made by slash commands or key bindings: also redraws the
-- options window if it's open. (Changes made in the window must not do
-- that: redrawing mid-drag would break its sliders.)
function RH:SettingChangedOutsideOptions()
    self:OnConfigChanged()
    ns.Options:RefreshIfOpen()
end

---------------------------------------------------------------------------
-- Toggles (also used by key bindings, see Bindings.xml)
---------------------------------------------------------------------------
function RH:ToggleCooldowns()
    local t = self.db.profile.toggles
    t.cooldowns = not t.cooldowns
    self:Print("Cooldowns: " .. Utils.OnOff(t.cooldowns) .. (t.cooldowns and t.cooldownsBossOnly and " (bosses only)" or ""))
    self:SettingChangedOutsideOptions()
end

function RH:ToggleConsumables()
    local t = self.db.profile.toggles
    t.consumables = not t.consumables
    local note = t.consumables and self.db.profile.items.consumablesBossOnly and " (bosses only)" or ""
    self:Print("Consumables: " .. Utils.OnOff(t.consumables) .. note)
    self:SettingChangedOutsideOptions()
end

function RH:CycleAoEMode()
    local t = self.db.profile.toggles
    local nextIndex = 1
    for i, mode in ipairs(AOE_MODES) do
        if mode == t.aoeMode then nextIndex = i % #AOE_MODES + 1 end
    end
    t.aoeMode = AOE_MODES[nextIndex]
    self:Print("AoE mode: " .. Utils.Colorize(t.aoeMode, "ffd100"))
    self:SettingChangedOutsideOptions()
end

function RH:ToggleDualDisplay()
    local d = self.db.profile.display
    d.dualDisplay = not d.dualDisplay
    self:Print("Dual display " .. (d.dualDisplay and "on: single target above, AoE below." or "off."))
    self:SettingChangedOutsideOptions()
end

function RH:TogglePause()
    local p = self.db.profile
    p.paused = not p.paused
    self:Print(p.paused and "Paused." or "Resumed.")
    self:SettingChangedOutsideOptions()
end

function RH:ToggleLock()
    local d = self.db.profile.display
    d.locked = not d.locked
    self:Print("Display " .. (d.locked and "locked." or "unlocked; drag to move."))
    self:SettingChangedOutsideOptions()
end

function RH:ToggleDebug()
    local p = self.db.profile
    p.debug = not p.debug
    self:Print("Debug: " .. Utils.OnOff(p.debug))
end

function RH:Debug(...)
    if self.db and self.db.profile.debug then
        self:Print(Utils.Colorize("[debug]", "888888"), ...)
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
function RH:ToggleTestMode()
    local display = ns.Display
    display:SetTestMode(not display.testMode)
    self:Print("Test icons " .. (display.testMode and "shown." or "hidden."))
    ns.Options:RefreshIfOpen()
end

-- Parses a number argument and stores it in the display settings.
local function SetDisplayNumber(self, key, label, arg, minValue, maxValue, integer)
    local value = tonumber(arg)
    if not value or value < minValue or value > maxValue then
        self:Print(("Usage: /rh %s <%s-%s> (currently %s)"):format(label, minValue, maxValue,
            tostring(self.db.profile.display[key])))
        return
    end
    if integer then value = math.floor(value + 0.5) end
    self.db.profile.display[key] = value
    self:Print(("%s set to %s."):format(label, value))
    self:SettingChangedOutsideOptions()
end

function RH:SetScale(arg)
    SetDisplayNumber(self, "scale", "scale", arg, 0.5, 3)
end

function RH:SetIconCount(arg)
    SetDisplayNumber(self, "numIcons", "icons", arg, 1, 5, true)
end

function RH:SetAoEScale(arg)
    SetDisplayNumber(self, "aoeScale", "aoescale", arg, 0.5, 3)
end

function RH:SetAoEIconCount(arg)
    SetDisplayNumber(self, "aoeNumIcons", "aoeicons", arg, 1, 5, true)
end

-- /rh pull N: a local pull timer (0 cancels).
function RH:StartPullTimer(arg)
    local seconds = tonumber(arg)
    if not seconds or seconds < 0 or seconds > 60 then
        self:Print("Usage: /rh pull <0-60> (0 cancels)")
        return
    end
    ns.PullTimer:Start(seconds, "you")
    self:Print(seconds > 0 and ("Pull timer: " .. seconds .. "s.") or "Pull timer cancelled.")
end

function RH:ShowReview(arg)
    ns.ReviewWindow:Show(tonumber(arg))
end

function RH:OpenOptions()
    if not ns.Options:Open() then self:PrintHelp() end
end

function RH:OpenRotationEditor()
    if not self.classSupported then
        self:Print("No rotation support for " .. tostring(self.playerClass) .. " yet.")
    elseif not ns.Options:Open("rotation") then
        self:Print("The options panel isn't available.")
    end
end

local HELP = {
    { "", "open the options panel" },
    { "apl", "open the rotation editor" },
    { "status", "show current settings" },
    { "lock", "lock/unlock the display" },
    { "test", "show/hide sample icons" },
    { "snapshot", "print what the addon reads from the game" },
    { "why <ability>", "why an ability is or isn't recommended right now" },
    { "review [n]", "show the last fight review (or saved fight n)" },
    { "version", "your version, and whether a newer one has been seen" },
    { "report", "a bug report to copy into a GitHub issue" },
    { "keys", "the keybinds found for your spells (to check bar addons like ElvUI)" },
    { "sim [seconds]", "simulate the active rotation (5 fights, 300s by default)" },
    { "damage", "your damage per ability from the combat log (/rh damage reset to start over)" },
    { "pull <seconds>", "start a pull timer for the rotation (DBM/BigWigs timers work too; 0 cancels)" },
    { "perf", "show CPU and memory use (/rh perf reset to start over)" },
    { "errors", "show recorded errors (/rh errors clear to empty the list)" },
    { "scale <n>", "display scale (0.5-3)" },
    { "icons <n>", "number of icons shown (1-5)" },
    { "aoescale <n>", "AoE display scale (0.5-3), with the dual display" },
    { "aoeicons <n>", "number of icons on the AoE display (1-5)" },
    { "cd", "toggle cooldown recommendations" },
    { "aoe", "cycle AoE mode (auto / single / aoe)" },
    { "dual", "toggle the dual display: single target and AoE suggestions side by side" },
    { "pause", "pause/resume recommendations" },
    { "debug", "toggle debug output" },
    { "reset", "reset the current profile to defaults" },
}

function RH:PrintHelp()
    self:Print(("v%s commands:"):format(self.version))
    for _, entry in ipairs(HELP) do
        local command = entry[1] == "" and "/rh" or ("/rh " .. entry[1])
        print(("  |cffffd100%s|r - %s"):format(command, entry[2]))
    end
end

function RH:PrintStatus()
    local p = self.db.profile
    self:Print(("v%s, class %s (%s)"):format(self.version, self.playerClass or "?",
        self.classSupported and "supported" or "not supported"))
    print("  Enabled: " .. Utils.OnOff(p.enabled) .. "  Paused: " .. Utils.OnOff(p.paused))
    print("  Cooldowns: " .. Utils.OnOff(p.toggles.cooldowns) .. (p.toggles.cooldownsBossOnly and " (bosses only)" or "")
        .. "  AoE mode: " .. p.toggles.aoeMode)
    print("  Consumables: " .. Utils.OnOff(p.toggles.consumables)
        .. (p.items.consumablesBossOnly and " (bosses only)" or ""))
    print("  Display locked: " .. Utils.OnOff(p.display.locked) .. "  Debug: " .. Utils.OnOff(p.debug))
    print("  Profile: " .. self.db:GetCurrentProfile())
end

local commands = {
    status = "PrintStatus",
    lock = "ToggleLock",
    unlock = "ToggleLock",
    cd = "ToggleCooldowns",
    cooldowns = "ToggleCooldowns",
    pots = "ToggleConsumables",
    consumables = "ToggleConsumables",
    aoe = "CycleAoEMode",
    dual = "ToggleDualDisplay",
    pause = "TogglePause",
    debug = "ToggleDebug",
    test = "ToggleTestMode",
    snapshot = "PrintSnapshot",
    snap = "PrintSnapshot",
    perf = "PrintPerf",
    errors = "PrintErrors",
    why = "PrintWhy",
    review = "ShowReview",
    version = "PrintVersion",
    report = "ShowReport",
    keys = "PrintKeybinds",
    sim = "PrintSim",
    damage = "PrintDamage",
    pull = "StartPullTimer",
    scale = "SetScale",
    icons = "SetIconCount",
    aoescale = "SetAoEScale",
    aoeicons = "SetAoEIconCount",
    help = "PrintHelp",
    config = "OpenOptions",
    options = "OpenOptions",
    apl = "OpenRotationEditor",
    rotation = "OpenRotationEditor",
}

function RH:SlashCommand(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = lower(cmd)
    if cmd == "" then
        self:OpenOptions()
    elseif cmd == "reset" then
        self.db:ResetProfile()
        self:Print("Profile reset.")
        ns.Options:RefreshIfOpen()
    elseif commands[cmd] then
        self[commands[cmd]](self, rest)
    else
        self:Print(("Unknown command '%s'."):format(cmd))
        self:PrintHelp()
    end
end

---------------------------------------------------------------------------
-- Key bindings (names referenced from Bindings.xml)
---------------------------------------------------------------------------
BINDING_HEADER_ROTATIONHELPER = "RotationHelper"
BINDING_NAME_ROTATIONHELPER_TOGGLE_COOLDOWNS = "Toggle Cooldowns"
BINDING_NAME_ROTATIONHELPER_TOGGLE_CONSUMABLES = "Toggle Consumables"
BINDING_NAME_ROTATIONHELPER_CYCLE_AOE = "Cycle AoE Mode"
BINDING_NAME_ROTATIONHELPER_TOGGLE_DUAL = "Toggle Dual Display"
BINDING_NAME_ROTATIONHELPER_TOGGLE_PAUSE = "Pause / Resume"
