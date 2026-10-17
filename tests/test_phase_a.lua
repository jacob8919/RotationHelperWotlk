-- A8-A13: colors, /rh why, hold indicator, in-range alternative, threat
-- warning, minimap button.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local function near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-6 then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- In combat with a dummy, diseases and Horn up, display locked.
local function Fight()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
        "Horn of Winter", "Death Coil")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    local d = RH.db.profile.display -- the extras these tests cover
    d.showStatus, d.holdIndicator, d.alternative, d.warningBorders = true, true, true, true
    s:Slash("ACECONSOLE_RH", "lock")
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    return s, RH
end

local function Main(s) return s.ns.Display.buttons[1] end

---------------------------------------------------------------------------
-- A8 Colors
---------------------------------------------------------------------------
test("A8: tints use the profile's colors, and presets change them", function()
    local s, RH = Fight()
    s.range["Obliterate"] = 0
    s:Tick(0.1)
    eq(Main(s).icon.vertexColor[1], 1, "default out-of-range red")
    local args = s.ns.Options:GetOptionsTable().args.display.args
    args.colorsColorblind.func()
    s:Tick(0.1)
    near(Main(s).icon.vertexColor[1], 0.84, "color-blind vermillion")
    near(Main(s).warn.backdropBorderColor[1], 0.9, "waste border recolored")
    args.colorOutOfRange.set(nil, 0.1, 0.2, 0.3)
    s:Tick(0.1)
    near(Main(s).icon.vertexColor[3], 0.3, "custom color")
    eq(select(2, args.colorOutOfRange.get()), 0.2, "get")
    args.colorsDefault.func()
    s:Tick(0.1)
    eq(Main(s).icon.vertexColor[2], 0, "back to default (Hekili's red)")
end)

---------------------------------------------------------------------------
-- A10 Hold indicator
---------------------------------------------------------------------------
test("A10: the main icon says what it waits on", function()
    local s, RH = Fight()
    for i = 1, 6 do s.runes[i].readyAt = s.time + 3 end
    s.cooldowns["Horn of Winter"] = { s.time, 20 }
    s:Tick(0.1)
    truthy(Main(s).hold:IsShown(), "shown")
    eq(Main(s).hold:GetText(), "RUNES", "runes")
    RH.db.profile.display.holdIndicator = false
    s:Tick(0.1)
    falsy(Main(s).hold:IsShown(), "turned off")
end)

test("A10: no label for a normal GCD wait", function()
    local s = Fight()
    s.cooldowns["Death Coil"] = { s.time - 0.5, 1.5 } -- 1s of GCD
    s:Tick(0.1)
    falsy(Main(s).hold:IsShown(), "just the GCD")
end)

test("A10: a wait line is reported as WAIT", function()
    local s = Fight()
    local Compiler, Runner = s.ns.APL.Compiler, s.ns.APL.Runner
    local apl = Compiler.CompileAPL("actions=wait,sec=2\nactions+=/b", {
        resolve = function() return function() return 0 end end })
    local _, t, limitedBy = Runner.Run(apl, { now = 10, variables = {} }, {
        ReadyAt = function() return 10 end })
    eq(t, 12, "held until the wait ends")
    eq(limitedBy, "wait", "reason")
end)

---------------------------------------------------------------------------
-- A9 /rh why
---------------------------------------------------------------------------
test("A9: /rh why explains an ability that isn't recommended", function()
    local s = Fight()
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why frost strike")
    truthy(s:ChatContains("Why %(not%) frost_strike%?"), "heading, name normalized")
    truthy(s:ChatContains("In Frost %(default%): main list line %d+, main list line %d+"), "where it's used")
    truthy(s:ChatContains("Can't be used now: runic power %(needs 40, have 0%)"), "why not usable")
    truthy(s:ChatContains("Recommended instead: obliterate %(main list line %d+%)"), "what won")
end)

test("A9: /rh why for the recommendation itself", function()
    local s = Fight()
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why obliterate")
    truthy(s:ChatContains("Usable now"), "usable")
    truthy(s:ChatContains("default:obliterate  best so far"), "its trace line")
    truthy(s:ChatContains("It is the recommendation"), "verdict")
end)

test("A9: waiting, missing from the rotation, unknown, no argument", function()
    local s = Fight()
    for i = 1, 6 do s.runes[i].readyAt = s.time + 4 end
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why obliterate")
    truthy(s:ChatContains("Usable in 4%.0s, waiting on runes"), "waiting")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why death_strike")
    truthy(s:ChatContains("It isn't in your rotation"), "not in the rotation")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why fireball")
    truthy(s:ChatContains("Unknown ability 'fireball'"), "unknown")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "why")
    truthy(s:ChatContains("Usage: /rh why"), "usage")
end)

---------------------------------------------------------------------------
-- A11 In-range alternative
---------------------------------------------------------------------------
local function OutOfMelee(s)
    for _, name in ipairs({ "Obliterate", "Frost Strike", "Blood Strike", "Plague Strike" }) do
        s.range[name] = 0
    end
end

test("A11: out of melee range, the best ranged ability is offered", function()
    local s, RH = Fight()
    OutOfMelee(s)
    s:AddAura("player", { name = "Freezing Fog", spellId = 59052, duration = 15, expires = s.time + 10 })
    s:Tick(0.1)
    eq(RH.recommendations[1].name, "obliterate", "the main recommendation stays")
    truthy(RH.alternative, "an alternative")
    eq(RH.alternative.name, "howling_blast", "the free Howling Blast is in range")
    local alt = s.ns.Display.altButton
    truthy(alt:IsShown(), "alternative icon")
    eq(alt.icon:GetTexture(), "Interface\\Icons\\Spell_Frost_ArcticWinds", "its icon")
end)

test("A11: no alternative when the rotation has nothing in range", function()
    local s, RH = Fight()
    OutOfMelee(s) -- diseases up, no Rime: Icy Touch and Howling Blast aren't due
    s:Tick(0.1)
    eq(RH.alternative, nil, "nothing to offer")
end)

test("A11: nothing extra in range, or when turned off", function()
    local s, RH = Fight()
    s:Tick(0.1)
    eq(RH.alternative, nil, "in range: no alternative")
    falsy(s.ns.Display.altButton:IsShown(), "no icon")
    OutOfMelee(s)
    RH.db.profile.display.alternative = false
    s:Tick(0.1)
    eq(RH.alternative, nil, "turned off")
end)

---------------------------------------------------------------------------
-- A12 Threat
---------------------------------------------------------------------------
test("A12: threat warning only in a group", function()
    local s, RH = Fight()
    s.threat = { isTanking = false, scaledPercent = 95 }
    s:Tick(0.1)
    falsy(RH.threat.warn, "solo: no warning")
    s.party = 4
    s:Tick(0.1)
    truthy(RH.threat.warn, "in a group at 95%")
    truthy(Main(s).threat:IsShown(), "border")
    truthy(s.ns.Display:GetStatusText():find("THREAT"), "status")
    s.threat.scaledPercent = 60
    s:Tick(0.1)
    falsy(RH.threat.warn, "60%: fine")
    falsy(Main(s).threat:IsShown(), "no border")
    s.threat.isTanking = true
    s:Tick(0.1)
    truthy(RH.threat.warn, "you have aggro")
    RH.db.profile.threat.enabled = false
    s:Tick(0.1)
    falsy(RH.threat.warn, "turned off")
end)

---------------------------------------------------------------------------
-- A13 Minimap button
---------------------------------------------------------------------------
test("A13: minimap button clicks, drags and hides", function()
    local s, RH = newAddon()
    local b = s.ns.MinimapButton.button
    truthy(b and b:IsShown(), "shown")
    local _, rel = b:GetPoint(1)
    eq(rel, s.env.Minimap, "on the minimap")

    b.scripts.OnClick(b, "RightButton")
    eq(RH.db.profile.toggles.cooldowns, false, "right click toggles cooldowns")

    s.cursor = { 500, 600 } -- straight above the center
    b.scripts.OnDragStart(b)
    b.scripts.OnUpdate(b)
    b.scripts.OnDragStop(b)
    near(RH.db.profile.minimap.angle, 90, "dragged to the top")
    local _, _, _, x, y = b:GetPoint(1)
    truthy(math.abs(x) < 1e-6 and math.abs(y - 80) < 1e-6, "placed at the top of the minimap")

    RH.db.profile.minimap.show = false
    RH:OnConfigChanged()
    falsy(b:IsShown(), "hidden")
end)

test("A13: left click opens the options", function()
    local s = newAddon()
    local opened
    s.ns.Options.Open = function() opened = true end
    local b = s.ns.MinimapButton.button
    b.scripts.OnClick(b, "LeftButton")
    truthy(opened, "options opened")
end)

test("options for A8-A13 validate", function()
    local s = newAddon()
    local registry = s.env.LibStub("AceConfigRegistry-3.0")
    local ok, err = pcall(registry.ValidateOptionsTable, registry, s.ns.Options:GetOptionsTable(), "RotationHelper")
    truthy(ok, tostring(err))
end)
