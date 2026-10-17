local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local function display(s) return s.ns.Display end

-- Loads the addon with the display locked (the in-combat look). These tests
-- set RH.recommendations by hand, so the real recommender is switched off.
local function lockedAddon(opts)
    local s, RH = newAddon(opts)
    s.ns.Recommender.Update = function() end
    s:Slash("ACECONSOLE_RH", "lock")
    return s, RH
end

test("unlocked display shows preview icons and drag label", function()
    local s = newAddon()
    local D = display(s)
    truthy(D.frame:IsShown(), "frame shown")
    truthy(D.frame.mover:IsShown(), "the box with the display name is shown")
    eq(D.frame.mover.header:GetText(), "Primary", "named like Hekili's")
    truthy(D.frame:IsMouseEnabled(), "draggable")
    s:Tick(0.1)
    -- Samples come from the spec's rotation: Frost's main list starts with
    -- Pestilence, Icy Touch, Plague Strike, Obliterate.
    local preview = D:GetPreview()
    eq(preview[1].spellId .. "," .. preview[4].spellId, "50842,51425", "Frost abilities")
    eq(D.buttons[4].icon:GetTexture(), "Interface\\Icons\\Spell_DeathKnight_ClassIcon", "Obliterate's icon")
    truthy(D.buttons[4]:IsShown(), "4 icons (the test harness; the default is 3)")
    falsy(D.buttons[5]:IsShown(), "5th icon hidden")
end)

test("locked display is click-through and hidden without recommendations", function()
    local s = lockedAddon()
    local D = display(s)
    falsy(D.frame:IsMouseEnabled(), "click-through")
    falsy(D.frame:IsShown(), "hidden")
end)

test("sample icons are the class's own spells (not a Death Knight's)", function()
    local s = newAddon({ class = "DRUID" })
    s.talentTabs = {
        { name = "Balance", talents = { { "Starlight Wrath", 5 }, { "Moonkin Form", 1 } } },
        { name = "Feral Combat", talents = {} },
        { name = "Restoration", talents = {} },
    }
    s.power = { type = 0, current = 20000, max = 20000 }
    s:Learn("Wrath", "Starfire", "Moonfire", "Insect Swarm", "Faerie Fire", "Moonkin Form")
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:Tick(0.1) -- idle: no target, display unlocked
    local D = display(s)
    truthy(D.frame:IsShown(), "shown")
    local druid = {}
    for _, ability in pairs(s.env.RotationHelper.classData.abilities) do
        if ability.id then druid[ability.id] = true end
    end
    truthy(D:GetPreview()[1], "has samples")
    for i, entry in ipairs(D:GetPreview()) do
        truthy(druid[entry.spellId], "sample " .. i .. " is a Druid spell (" .. tostring(entry.spellId) .. ")")
    end
    -- A talent change to another spec rebuilds them.
    s.talentTabs[1].talents[1][2] = 0
    s.talentTabs[2].talents = { { "Ferocity", 5 }, { "Mangle", 1 }, { "Berserk", 1 } }
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:Tick(0.1)
    eq(s.ns.Spec.key, "feral_combat", "now feral")
    eq(D:GetPreview()[1].spellId, 768, "Cat Form first in the cat rotation")
end)

test("unsupported class shows nothing even when unlocked", function()
    local s = newAddon({ class = "MONK" })
    falsy(display(s).frame:IsShown(), "hidden for MONK")
end)

test("/rh test shows sample icons while locked", function()
    local s = lockedAddon()
    local D = display(s)
    s:Slash("ACECONSOLE_RH", "test")
    truthy(D.frame:IsShown(), "shown in test mode")
    falsy(D.frame.mover:IsShown(), "no box when locked")
    s:Slash("ACECONSOLE_RH", "test")
    falsy(D.frame:IsShown(), "hidden again")
end)

test("renders recommendations with keybinds", function()
    local s, RH = lockedAddon()
    s:PlaceSpell(2, 55268, "ACTIONBUTTON2", "SHIFT-2")
    RH.recommendations = { { spellId = 55268 }, { spellId = 49909 } }
    s:Tick(0.2)
    local D = display(s)
    truthy(D.frame:IsShown(), "shown")
    eq(D.buttons[1].icon:GetTexture(), "Interface\\Icons\\Spell_DeathKnight_EmpowerRuneBlade2", "main icon")
    eq(D.buttons[1].key:GetText(), "S2", "main keybind")
    eq(D.buttons[2].key:GetText(), "", "unbound spell shows no key")
    falsy(D.buttons[3]:IsShown(), "no third entry")
end)

test("numIcons limits the queue", function()
    local s, RH = lockedAddon()
    RH.recommendations = { { spellId = 51425 }, { spellId = 55268 }, { spellId = 51411 } }
    s:Slash("ACECONSOLE_RH", "icons 2")
    local D = display(s)
    truthy(D.buttons[2]:IsShown(), "second shown")
    falsy(D.buttons[3]:IsShown(), "third hidden")
end)

test("out of range and missing resources tint the icon (Hekili's red and grey)", function()
    local s, RH = lockedAddon()
    local D = display(s)
    RH.recommendations = { { spellId = 51425 }, { spellId = 55268, lacksResources = true } }
    s.hasTarget = true
    s.range["Obliterate"] = 0
    s:Tick(0.2)
    eq(D.buttons[1].icon.vertexColor[1] .. "," .. D.buttons[1].icon.vertexColor[2], "1,0", "red when out of range")
    truthy(D.buttons[1].icon.desaturated, "and desaturated")
    eq(D.buttons[2].icon.vertexColor[1] .. "," .. D.buttons[2].icon.vertexColor[3], "0.4,0.4", "grey when lacking resources")
    falsy(D.buttons[2].icon.desaturated, "grey, not desaturated")
    s.range["Obliterate"] = 1
    s:Tick(0.2)
    eq(D.buttons[1].icon.vertexColor[2], 1, "normal when in range")
    falsy(D.buttons[1].icon.desaturated, "color back")
end)

test("cooldown swipe only restarts when the ready time moves", function()
    local s, RH = lockedAddon()
    local cd = display(s).buttons[1].cooldown
    RH.recommendations = { { spellId = 51425, wait = 1.0 } }
    s:Tick(0.2)
    truthy(cd:IsShown(), "swipe shown")
    local firstStart = cd.cooldownStart
    eq(cd.cooldownDuration, 1.0, "duration")

    RH.recommendations[1].wait = 0.9 -- same ready time, 0.1s later
    s:Tick(0.1)
    eq(cd.cooldownStart, firstStart, "not restarted")

    RH.recommendations[1].wait = 2.0 -- ready time pushed back
    s:Tick(0.1)
    truthy(cd.cooldownStart > firstStart, "restarted")

    RH.recommendations[1].wait = 0
    s:Tick(0.1)
    falsy(cd:IsShown(), "hidden when ready")
end)

test("hide out of combat", function()
    local s, RH = lockedAddon()
    RH.db.profile.display.hideOutOfCombat = true
    RH.recommendations = { { spellId = 51425 } }
    s:Tick(0.2)
    local D = display(s)
    falsy(D.frame:IsShown(), "hidden out of combat")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    truthy(D.frame:IsShown(), "shown in combat")
end)

test("pause hides the locked display", function()
    local s, RH = lockedAddon()
    RH.recommendations = { { spellId = 51425 } }
    s:Tick(0.2)
    truthy(display(s).frame:IsShown(), "shown")
    s:Slash("ACECONSOLE_RH", "pause")
    falsy(display(s).frame:IsShown(), "hidden while paused")
end)

test("dragging saves the position", function()
    local s, RH = newAddon()
    local f = display(s).frame
    f.scripts.OnDragStart(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", s.env.UIParent, "BOTTOMLEFT", 300, 400)
    f.scripts.OnDragStop(f)
    local p = RH.db.profile.display.point
    eq(table.concat({ p[1], p[2], p[3], p[4], p[5] }, ","), "TOPLEFT,UIParent,BOTTOMLEFT,300,400", "saved point")
end)

test("queue grows in the configured direction", function()
    local s, RH = newAddon()
    RH.db.profile.display.direction = "DOWN"
    RH:OnConfigChanged()
    local b2 = display(s).buttons[2]
    local point, rel, relPoint, x, y = b2:GetPoint(1)
    eq(point .. "/" .. relPoint, "TOP/BOTTOM", "anchors")
    eq(rel, display(s).buttons[1], "anchored to previous")
    eq(x .. "," .. y, "0,-5", "offset (Hekili's 5px)")
    eq(b2.width, 50, "queue icon size (Hekili's 50px)")
end)
