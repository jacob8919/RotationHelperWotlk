-- G1: diseases on several enemies; G2: learning damage from the combat log.
local T = require("testlib")
local Mock = require("wowmock")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local ME, NPC = Mock.PLAYER_GUID, Mock.FLAGS_HOSTILE_NPC
local FROST_FEVER, BLOOD_PLAGUE = 55095, 55078

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local SPELLS = { "Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
    "Horn of Winter", "Death Coil", "Pestilence", "Blood Boil", "Death and Decay" }

local function Fight()
    local s, RH = newAddon()
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    RH.db.profile.display.showStatus = true -- the "2/3 DIS" status text is checked
    s:Slash("ACECONSOLE_RH", "lock")
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    return s, RH
end

local function TargetDiseases(s)
    s:AddAura("target", { name = "Frost Fever", spellId = FROST_FEVER, duration = 15, expires = s.time + 12, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = BLOOD_PLAGUE, duration = 15, expires = s.time + 12, harmful = true })
end

-- A combat log line from us to `guid`.
local function Log(s, subevent, guid, spellId, spellName, ...)
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, subevent, ME, "Me", Mock.FLAGS_ME,
        guid, "Mob", NPC, spellId, spellName, ...)
end

local function Diseases(s, guid)
    Log(s, "SPELL_AURA_APPLIED", guid, FROST_FEVER, "Frost Fever", 16, "DEBUFF")
    Log(s, "SPELL_AURA_APPLIED", guid, BLOOD_PLAGUE, "Blood Plague", 32, "DEBUFF")
end

local function Eval(s, text)
    local resolve = s.ns.Expressions.CreateResolver(s.env.RotationHelper.classData)
    local fn, message = s.ns.APL.Compiler.CompileExpression(text, resolve)
    if not fn then error("compile failed: " .. message, 2) end
    return fn(s.ns.State:Reset())
end

---------------------------------------------------------------------------
-- G1 Diseases on several enemies
---------------------------------------------------------------------------
test("dots: counted per enemy from the combat log, the target from its auras", function()
    local s = Fight()
    TargetDiseases(s)
    eq(Eval(s, "active_dot.frost_fever"), 1, "only the target")
    eq(Eval(s, "diseased_enemies"), 1, "target diseased")
    Diseases(s, "0xF1300000000000A1")
    Log(s, "SPELL_AURA_APPLIED", "0xF1300000000000A2", FROST_FEVER, "Frost Fever", 16, "DEBUFF")
    eq(Eval(s, "active_dot.frost_fever"), 3, "target + 2")
    eq(Eval(s, "active_dot.blood_plague"), 2, "target + 1")
    eq(Eval(s, "diseased_enemies"), 2, "only one other has both")
    eq(Eval(s, "active_enemies"), 3, "enemies")

    Log(s, "SPELL_AURA_REMOVED", "0xF1300000000000A1", BLOOD_PLAGUE, "Blood Plague", 32, "DEBUFF")
    eq(Eval(s, "diseased_enemies"), 1, "removed")
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, "UNIT_DIED", nil, nil, 0, "0xF1300000000000A2", "Mob", NPC)
    eq(Eval(s, "active_dot.frost_fever"), 2, "died")
end)

test("dots: go stale without ticks; ticks keep them", function()
    local s = Fight()
    Diseases(s, "0xF1300000000000A1")
    eq(Eval(s, "active_dot.frost_fever"), 1, "applied")
    for _ = 1, 3 do
        s.time = s.time + 3
        Log(s, "SPELL_PERIODIC_DAMAGE", "0xF1300000000000A1", FROST_FEVER, "Frost Fever", 16, 500, 0, 16, 0, 0, 0, nil)
    end
    eq(Eval(s, "active_dot.frost_fever"), 1, "ticking")
    eq(Eval(s, "active_dot.blood_plague"), 0, "no plague ticks: stale")
    s.time = s.time + 7
    eq(Eval(s, "active_dot.frost_fever"), 0, "no ticks for a while")
end)

test("dots: other players' diseases don't count; combat end forgets", function()
    local s = Fight()
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, "SPELL_AURA_APPLIED", "0x0000000000000099", "Other", 0x514,
        "0xF1300000000000A1", "Mob", NPC, FROST_FEVER, "Frost Fever", 16, "DEBUFF")
    eq(Eval(s, "active_dot.frost_fever"), 0, "someone else's")
    Diseases(s, "0xF1300000000000A1")
    s:FireEvent("PLAYER_REGEN_ENABLED")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    eq(Eval(s, "active_dot.frost_fever"), 0, "forgotten")
end)

test("Pestilence: spreads once when an enemy lacks diseases, predicted as spread", function()
    local s, RH = Fight()
    TargetDiseases(s)
    RH.db.profile.toggles.aoeMode = "auto"
    for i = 1, 3 do
        s:CombatLog("SPELL_DAMAGE", ME, Mock.FLAGS_ME, "0xF1300000000000B" .. i, NPC)
    end
    s:Tick(0.1)
    eq(s.ns.State.real.activeEnemies, 4, "4 enemies")
    local names = {}
    for _, e in ipairs(RH.recommendations) do names[#names + 1] = e.name end
    eq(names[1], "pestilence", "spread first")
    for i = 2, #names do falsy(names[i] == "pestilence", "not again in the queue (" .. i .. ")") end

    -- All diseased: no Pestilence.
    for i = 1, 3 do Diseases(s, "0xF1300000000000B" .. i) end
    s:Tick(0.1)
    for _, e in ipairs(RH.recommendations) do falsy(e.name == "pestilence", "all diseased") end
end)

test("status line: diseased of enemies", function()
    local s, RH = Fight()
    TargetDiseases(s)
    for i = 1, 2 do s:CombatLog("SPELL_DAMAGE", ME, Mock.FLAGS_ME, "0xF1300000000000C" .. i, NPC) end
    Diseases(s, "0xF1300000000000C1")
    s:Tick(0.1)
    truthy(s.ns.Display:GetStatusText():find("2/3 DIS", 1, true), "status: " .. s.ns.Display:GetStatusText())
    Diseases(s, "0xF1300000000000C2")
    s:Tick(0.1)
    truthy(s.ns.Display:GetStatusText():find("3/3 DIS", 1, true), "all")
    RH.db.profile.toggles.aoeMode = "single"
    s:Tick(0.1)
    falsy(s.ns.Display:GetStatusText():find("DIS", 1, true), "single target: no hint")
end)

test("simulator: Pestilence spreads in AoE and diseases stay up", function()
    local s, RH = newAddon()
    s:Learn(unpack(SPELLS))
    local apl = s.ns.Recommender:GetAPL()
    local summary = s.ns.Sim.Summarize(apl, { seconds = 120, enemies = 4, cooldowns = false }, 2)
    local pest = 0
    for _, c in ipairs(summary.casts) do if c.key == "pestilence" then pest = c.perMinute end end
    truthy(pest > 0 and pest <= 6.5, "Pestilence per minute: " .. pest)
end)

---------------------------------------------------------------------------
-- G2 Damage log
---------------------------------------------------------------------------
local function Cast(s, name) s:FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", name, "") end
local function Hit(s, id, name, amount, crit, periodic)
    Log(s, periodic and "SPELL_PERIODIC_DAMAGE" or "SPELL_DAMAGE", "0xF1300000000000D1", id, name, 16,
        amount, 0, 16, 0, 0, 0, crit and 1 or nil)
end

test("damage log: per cast (both hands), per rune, crits, dots per tick, melee", function()
    local s, RH = Fight()
    for i = 1, 5 do
        Cast(s, "Obliterate")
        Hit(s, 51425, "Obliterate", 4000, i <= 2)   -- main hand
        Hit(s, 66974, "Obliterate", 2000, false)    -- off hand
    end
    for _ = 1, 6 do Hit(s, FROST_FEVER, "Frost Fever", 500, false, true) end
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, "SWING_DAMAGE", ME, "Me", Mock.FLAGS_ME,
        "0xF1300000000000D1", "Mob", NPC, 1000, 0, 1, 0, 0, 0, 1)
    local log = s.ns.DamageLog
    eq(log:PerCast("obliterate"), 6000, "per cast")
    eq(log:PerTick("frost_fever"), 500, "per tick")
    local data = RH.db.char.damage
    eq(data.total, 30000 + 3000 + 1000, "total")
    eq(data.abilities.obliterate.crits, 2, "crits")
    eq(data.abilities.melee.crits, 1, "melee crit")

    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "damage")
    truthy(s:ChatContains("Obliterate: 5 casts, 6,000 per cast, 3,000 per rune, 20%% crit, 88.2%% of your damage"),
        "report line")
    truthy(s:ChatContains("Frost Fever: 500 per tick"), "dot line")
    truthy(s:ChatContains("Melee: 1,000 per swing, 100%% crit"), "melee line")

    s:Slash("ACECONSOLE_RH", "damage reset")
    eq(RH.db.char.damage.total, 0, "reset")
    falsy(log:PerCast("obliterate"), "no data")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "damage")
    truthy(s:ChatContains("No damage recorded"), "empty")
end)

test("damage log: other people's damage and too few casts are ignored", function()
    local s, RH = Fight()
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, "SPELL_DAMAGE", "0x0000000000000099", "Other", 0x514,
        "0xF1300000000000D1", "Mob", NPC, 51425, "Obliterate", 1, 9999, 0, 1, 0, 0, 0, nil)
    eq(RH.db.char.damage.total, 0, "not ours")
    Cast(s, "Frost Strike")
    Hit(s, 55268, "Frost Strike", 3000)
    falsy(s.ns.DamageLog:PerCast("frost_strike"), "one cast isn't enough")
end)

test("simulator: estimated damage from the log", function()
    local s, RH = Fight()
    local apl = s.ns.Recommender:GetAPL()
    local summary = s.ns.Sim.Summarize(apl, { seconds = 60, cooldowns = false }, 1)
    falsy(summary.damage, "no log, no estimate")

    for _ = 1, 5 do
        Cast(s, "Obliterate"); Hit(s, 51425, "Obliterate", 6000)
        Cast(s, "Frost Strike"); Hit(s, 55268, "Frost Strike", 3000)
    end
    summary = s.ns.Sim.Summarize(apl, { seconds = 60, cooldowns = false }, 1)
    truthy(summary.damage, "estimate")
    local expected = 0
    for _, c in ipairs(summary.casts) do
        if c.key == "obliterate" then expected = expected + c.perMinute * 6000 end
        if c.key == "frost_strike" then expected = expected + c.perMinute * 3000 end
    end
    near(summary.damage.perMinute, expected, "casts x per cast", expected * 0.02)
    local missing = table.concat(summary.damage.missing, " ")
    truthy(missing:find("icy_touch", 1, true) or missing:find("frost_fever", 1, true), "lists what has no data: " .. missing)
    local text = table.concat(s.ns.Sim.Format(summary), "\n")
    truthy(text:find("Estimated damage %(from your damage log%): [%d,]+ per minute %(no data for"), "formatted")
end)
