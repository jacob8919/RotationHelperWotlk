-- While you cast or channel, the spell being cast gets its own icon beside
-- the main one: it slides out, shrinks and fades as the cast progresses,
-- and is gone when it lands. The main icon stays what to press next.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local CAST_ICON = "Interface\\Icons\\Spell_Nature_Lightning"

local function near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.01 then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local function Fight()
    local s, RH = newAddon({ class = "WARLOCK" })
    s.talentTabs = {
        { name = "Affliction", talents = {} },
        { name = "Demonology", talents = {} },
        { name = "Destruction", talents = { { "Bane", 5 }, { "Conflagrate", 1 }, { "Chaos Bolt", 1 } } },
    }
    s.power = { type = 0, current = 20000, max = 20000 }
    s:Learn("Immolate", "Conflagrate", "Chaos Bolt", "Incinerate", "Curse of Doom", "Curse of Agony", "Corruption",
        "Shadow Bolt", "Life Tap", "Fel Armor")
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.display.locked = true
    RH.db.profile.display.castSlot = true
    RH.db.profile.toggles.cooldowns = false
    s:AddAura("player", { name = "Fel Armor", spellId = 47893, duration = 1800, expires = s.time + 1800 })
    s:AddAura("target", { name = "Immolate", spellId = 47811, duration = 15, expires = s.time + 12, harmful = true })
    s:AddAura("target", { name = "Curse of Doom", spellId = 47867, duration = 60, expires = s.time + 50, harmful = true })
    s.cooldowns["Conflagrate"] = { s.time, 10 }
    s.cooldowns["Chaos Bolt"] = { s.time, 12 }
    RH:OnConfigChanged()
    return s, RH
end

test("not casting: no cast icon", function()
    local s = Fight()
    s:Tick(0.1)
    falsy(s.ns.Display.castButton:IsShown(), "hidden")
    truthy(s.ns.Display.buttons[1]:IsShown(), "main icon")
end)

test("casting: the cast slides out beside the main icon and shrinks until it lands", function()
    local s, RH = Fight()
    s:Tick(0.1)
    local D = s.ns.Display
    local mainIcon = D.buttons[1].icon:GetTexture()
    local size = RH.db.profile.display.iconSize
    s.playerCast = { name = "Incinerate", startedAgo = 0, endsIn = 2, icon = CAST_ICON }
    s:Tick(0.1)
    local b = D.castButton
    truthy(b:IsShown(), "cast icon shown")
    eq(b.icon:GetTexture(), CAST_ICON, "the spell being cast")
    truthy(b.cooldown:IsShown(), "progress sweep")
    eq(D.buttons[1].icon:GetTexture(), mainIcon, "the main icon stays the next action")
    truthy(D.buttons[1].cooldown:IsShown(), "which waits for the cast")

    -- Start: full size, on top of the main icon. The mock's cast began at
    -- the read, so use the button's own times.
    b.slideStart = b.castStart
    D:AnimateCast(b.castStart)
    near(b:GetWidth(), size, "full size at the start")
    local p = { b:GetPoint(1) }
    eq(p[1], "RIGHT", "left of the main icon")
    near(p[4], size, "on top of the main icon")
    -- Halfway: slid out, smaller and fainter.
    D:AnimateCast(b.castStart + 1)
    near(b:GetWidth(), size * 0.7, "shrinking")
    near(b:GetAlpha(), 0.75, "fading")
    p = { b:GetPoint(1) }
    near(p[4], -RH.db.profile.display.spacing, "beside the main icon")
    eq(b.hold:GetText(), "1.0", "time left")
    -- Landed: gone.
    D:AnimateCast(b.castEnd)
    falsy(b:IsShown(), "gone when the cast lands")
end)

test("queue growing left: the cast goes to the right", function()
    local s, RH = Fight()
    RH.db.profile.display.direction = "LEFT"
    RH:OnConfigChanged()
    s.playerChannel = { name = "Drain Life", startedAgo = 1, endsIn = 4, icon = CAST_ICON }
    s:Tick(0.1)
    local b = s.ns.Display.castButton
    truthy(b:IsShown(), "channels too")
    eq((b:GetPoint(1)), "LEFT", "right of the main icon")
end)

test("the setting turns it off; sample icons don't show it", function()
    local s, RH = Fight()
    s.playerCast = { name = "Incinerate", startedAgo = 0.5, endsIn = 1.5, icon = CAST_ICON }
    RH.db.profile.display.castSlot = false
    RH:OnConfigChanged()
    s:Tick(0.1)
    falsy(s.ns.Display.castButton:IsShown(), "off")
    RH.db.profile.display.castSlot = true
    RH:OnConfigChanged()
    s:Tick(0.1)
    truthy(s.ns.Display.castButton:IsShown(), "on")
    s.ns.Display:SetTestMode(true)
    falsy(s.ns.Display.castButton:IsShown(), "not with sample icons")
end)
