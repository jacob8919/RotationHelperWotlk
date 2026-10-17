-- Dual display (like Hekili's): the main display shows single target and a
-- second display (UI/AoEDisplay.lua) always shows the AoE priority, with its
-- own size and position.
local T = require("testlib")
local Mock = require("wowmock")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Cat Form", "Mangle (Cat)", "Shred", "Rake", "Rip", "Savage Roar", "Ferocious Bite", "Tiger's Fury",
    "Berserk", "Faerie Fire (Feral)", "Mark of the Wild", "Swipe (Cat)" }

-- A cat at full energy in combat with a boss; the display locked when `locked`.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon({ class = "DRUID" })
    s.talentTabs = {
        { name = "Balance", talents = {} },
        { name = "Feral Combat", talents = { { "Ferocity", 5 }, { "Shredding Attacks", 2 }, { "Mangle", 1 } } },
        { name = "Restoration", talents = {} },
    }
    s.power = { type = 3, current = 100, max = 100 }
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    RH.db.profile.display.showStatus = true -- the ST / AOE chip is checked below
    RH.db.profile.display.aoeNumIcons = 4
    s:AddAura("player", { name = "Cat Form", spellId = 768, duration = 0, expires = 0 })
    if opts.locked then s:Slash("ACECONSOLE_RH", "lock") end
    if opts.dual then s:Slash("ACECONSOLE_RH", "dual") end
    return s, RH
end

local function Names(recs, count)
    local out = {}
    for i, e in ipairs(recs or {}) do
        if i > count then break end
        out[#out + 1] = e.name
    end
    return table.concat(out, ", ")
end

local function Hit(s, guid)
    s:CombatLog("SPELL_DAMAGE", Mock.PLAYER_GUID, Mock.FLAGS_ME, guid, Mock.FLAGS_HOSTILE_NPC)
end

local function AoE(s) return s.ns.AoEDisplay end

test("dual display: off by default; /rh dual and the keybind toggle it", function()
    local s, RH = Fight()
    falsy(RH.db.profile.display.dualDisplay, "off")
    s:Slash("ACECONSOLE_RH", "dual")
    truthy(RH.db.profile.display.dualDisplay, "on")
    truthy(s:ChatContains("Dual display on"), "says so")
    s:Slash("ACECONSOLE_RH", "dual")
    falsy(RH.db.profile.display.dualDisplay, "off again")
    s:Slash("ACECONSOLE_RH", "")
    truthy(s:ChatContains("/rh dual"), "in the help")
    eq(s.env.BINDING_NAME_ROTATIONHELPER_TOGGLE_DUAL, "Toggle Dual Display", "keybind name")
    local xml = io.open("RotationHelper/Bindings.xml"):read("*a")
    truthy(xml:find('name="ROTATIONHELPER_TOGGLE_DUAL"', 1, true), "binding")
    truthy(xml:find("RotationHelper:ToggleDualDisplay()", 1, true), "binding calls the toggle")
end)

test("dual display: main display single target whatever the AoE mode, the second one AoE", function()
    local s, RH = Fight({ dual = true })
    RH.db.profile.toggles.aoeMode = "aoe"
    s:Tick(0.1)
    eq(s.ns.State.real.activeEnemies, 1, "main: one enemy")
    eq(Names(RH.recommendations, 2), "faerie_fire_feral, mangle_cat", "main: single target")
    eq(Names(RH.aoeRecommendations, 3), "mangle_cat, savage_roar, swipe_cat", "second: the AoE list")
    eq(s.ns.Display.frame.aoeChip.lastText, "|cffffd100ST|r", "status chip shows ST")

    s:Slash("ACECONSOLE_RH", "dual")
    s:Tick(0.1)
    eq(RH.aoeRecommendations, nil, "off: no AoE pass")
    eq(Names(RH.recommendations, 1), "mangle_cat", "off: the AoE mode applies again")
    eq(s.ns.Display.frame.aoeChip.lastText, "|cffffd100AOE|r", "chip")
end)

test("dual display: the AoE prediction uses the real enemy count when 3 or more", function()
    local s, RH = Fight({ dual = true })
    local enemies
    local Predict = s.ns.Recommender.Predict
    s.ns.Recommender.Predict = function(self, count, trace, n)
        if n then enemies = n end
        return Predict(self, count, trace, n)
    end
    s:Tick(0.1)
    eq(enemies, 3, "at least 3")
    Hit(s, s.target.guid)
    for i = 1, 4 do Hit(s, "mob" .. i) end
    s:Tick(0.1)
    eq(enemies, 5, "the target and 4 more")
    eq(s.ns.State.real.activeEnemies, 1, "the main display stays single target")
end)

test("dual display: separate tables, the main ones aren't overwritten", function()
    local s, RH = Fight({ dual = true })
    s:Tick(0.1)
    truthy(RH.recommendations ~= RH.aoeRecommendations, "different lists")
    truthy(RH.recommendations[1] ~= RH.aoeRecommendations[1], "different entries")
    eq(RH.recommendations[1].name, "faerie_fire_feral", "main entry kept after the AoE pass")
    eq(#RH.aoeRecommendations, 4, "aoeNumIcons")
    RH.db.profile.display.aoeNumIcons = 2
    s:Tick(0.1)
    eq(#RH.aoeRecommendations, 2, "aoeNumIcons 2")
    eq(#RH.recommendations, 4, "main count unchanged")
end)

test("dual display: the Death Knight rune prediction comes from the main display only", function()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike", "Pestilence",
        "Horn of Winter", "Death Coil")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    s:Tick(0.1)
    local function Runes()
        local out = {}
        for i, r in ipairs(s.ns.Recommender.predictedRunes) do out[i] = ("%s@%.2f"):format(r.type, r.readyAt - s.time) end
        return table.concat(out, " ")
    end
    local single = Runes()
    s:Slash("ACECONSOLE_RH", "dual")
    s:Tick(0.1)
    eq(Runes(), single, "same runes with the AoE pass")
end)

test("AoE display: shown with the dual display, the same show/hide rules as the main one", function()
    local s, RH = Fight({ locked = true })
    s:Tick(0.1)
    falsy(AoE(s).frame:IsShown(), "dual display off")
    s:Slash("ACECONSOLE_RH", "dual")
    s:Tick(0.1)
    truthy(AoE(s).frame:IsShown(), "on")
    eq(AoE(s).frame:GetName(), "RotationHelperAoEDisplay", "frame name")
    eq(AoE(s).frame.mover.header:GetText(), "AOE", "named like Hekili's")
    falsy(AoE(s).frame.mover:IsShown(), "no box while locked")
    eq(AoE(s).buttons[1].icon:GetTexture() ~= nil, true, "icon drawn")
    truthy(AoE(s).buttons[4]:IsShown(), "4 icons")
    falsy(AoE(s).buttons[5]:IsShown(), "5th hidden")

    RH.db.profile.display.hideOutOfCombat = true
    s:FireEvent("PLAYER_REGEN_ENABLED")
    s:Tick(0.1)
    falsy(AoE(s).frame:IsShown(), "hidden out of combat")
    RH.db.profile.display.hideOutOfCombat = false

    s.hasTarget = false
    s:FireEvent("PLAYER_REGEN_DISABLED")
    s:Tick(0.1)
    falsy(AoE(s).frame:IsShown(), "nothing to suggest")
    s:Slash("ACECONSOLE_RH", "test")
    s:Tick(0.1)
    truthy(AoE(s).frame:IsShown(), "test mode")
end)

test("AoE display: unlocked it shows a preview and can be dragged; the position is saved", function()
    local s, RH = Fight({ dual = true })
    s.hasTarget = false
    s:Tick(0.1)
    local f = AoE(s).frame
    truthy(f:IsShown(), "preview while unlocked")
    truthy(f:IsMouseEnabled(), "draggable")
    truthy(f.mover:IsShown(), "the box with its name")
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", s.env.UIParent, "TOPLEFT", 20, -30)
    f.scripts.OnDragStop(f)
    local p = RH.db.profile.display.aoePoint
    eq(table.concat({ p[1], p[2], p[3], p[4], p[5] }, ","), "TOPLEFT,UIParent,TOPLEFT,20,-30", "saved")
end)

test("AoE display sizing: its own scale, icon size, queue size and icon count", function()
    local s, RH = Fight({ dual = true, locked = true })
    local d = RH.db.profile.display
    local defaults = RH.db.defaults.profile.display
    eq(defaults.aoeScale .. "," .. defaults.aoeIconSize .. "," .. defaults.aoeQueueSize .. "," .. defaults.aoeNumIcons,
        "1,50,50,3", "defaults (Hekili's AOE display)")
    eq(table.concat(d.aoePoint, ","), "CENTER,UIParent,CENTER,0,-170", "above the main display, like Hekili's")

    s:Slash("ACECONSOLE_RH", "aoescale 1.5")
    s:Slash("ACECONSOLE_RH", "aoeicons 2")
    d.aoeIconSize, d.aoeQueueSize = 60, 30
    s.ns.AoEDisplay:ApplySettings()
    s:Tick(0.1)
    local f, buttons = AoE(s).frame, AoE(s).buttons
    eq(f:GetScale(), 1.5, "scale")
    eq(buttons[1]:GetWidth(), 60, "icon size")
    eq(buttons[2]:GetWidth(), 30, "queue size")
    truthy(buttons[2]:IsShown(), "2 icons")
    falsy(buttons[3]:IsShown(), "not 3")
    eq(s.ns.Display.frame:GetScale(), 1, "the main display keeps its scale")

    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "aoescale 9")
    truthy(s:ChatContains("Usage: /rh aoescale"), "out of range")
    eq(d.aoeScale, 1.5, "unchanged")

    -- Missing values fall back to the main display's.
    d.aoeScale, d.aoeIconSize = nil, nil
    s.ns.AoEDisplay:ApplySettings()
    eq(f:GetScale(), d.scale, "scale falls back")
    eq(buttons[1]:GetWidth(), d.iconSize, "icon size falls back")
end)

test("options: the dual display toggle, its size section only when on, Reset position covers both", function()
    local s, RH = Fight()
    local display = s.ns.Options:GetOptionsTable().args.display
    local args = display.args
    truthy(args.aoeScale.hidden(), "AoE size options hidden while off")
    truthy(args.reactiveAoE.disabled(), "reactive mode greyed out while off")
    display.set({ "display", "dualDisplay" }, true)
    truthy(RH.db.profile.display.dualDisplay, "toggled from the options")
    falsy(args.aoeScale.hidden(), "shown when on")
    falsy(args.reactiveAoE.disabled(), "reactive mode available")
    display.set({ "display", "aoeNumIcons" }, 3)
    eq(RH.db.profile.display.aoeNumIcons, 3, "icon count from the options")

    RH.db.profile.display.aoePoint = { "TOPLEFT", "UIParent", "TOPLEFT", 5, 5 }
    args.resetPosition.func()
    local p = RH.db.profile.display.aoePoint
    eq(p[1] .. p[5], "CENTER-170", "AoE display position reset")
end)
