-- Feral cat Druid: Cat Form energy, 1 second GCD, Savage Roar, Rip, Rake,
-- Mangle (anyone's), Clearcasting, Berserk, Tiger's Fury.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Cat Form", "Mangle (Cat)", "Shred", "Rake", "Rip", "Savage Roar", "Ferocious Bite", "Tiger's Fury",
    "Berserk", "Faerie Fire (Feral)", "Mark of the Wild" }

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- A cat in combat with a boss; `setUp` puts Faerie Fire, Mangle, Rake, Rip
-- and Savage Roar up.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon({ class = "DRUID" })
    s.talentTabs = {
        { name = "Balance", talents = { { "Starlight Wrath", 2 } } },
        { name = "Feral Combat", talents = { { "Ferocity", 5 }, { "Shredding Attacks", 2 }, { "King of the Jungle", 3 },
            { "Berserk", 1 }, { "Mangle", 1 }, { "Improved Mangle", 3 } } },
        { name = "Restoration", talents = { { "Omen of Clarity", 1 } } },
    }
    s.power = { type = 3, current = opts.energy or 100, max = 100 }
    s.combo = opts.combo or 0
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    s:AddAura("player", { name = "Cat Form", spellId = 768, duration = 0, expires = 0 })
    if opts.setUp then
        s:AddAura("target", { name = "Faerie Fire (Feral)", spellId = 16857, duration = 300, expires = s.time + 200, harmful = true })
        s:AddAura("target", { name = "Mangle (Cat)", spellId = 48566, duration = 60, expires = s.time + 50, harmful = true })
        s:AddAura("target", { name = "Rake", spellId = 48574, duration = 9, expires = s.time + 8, harmful = true })
        s:AddAura("target", { name = "Rip", spellId = 49800, duration = 12, expires = s.time + 11, harmful = true })
        s:AddAura("player", { name = "Savage Roar", spellId = 52610, duration = 34, expires = s.time + 30 })
    end
    return s, RH
end

local function Queue(s, count)
    s:Tick(0.1)
    local out = {}
    for i, e in ipairs(s.env.RotationHelper.recommendations or {}) do
        if i > count then break end
        out[#out + 1] = e.wait < 0.05 and e.name or ("%s +%.1f"):format(e.name, e.wait)
    end
    return table.concat(out, ", ")
end

test("feral: the cat rotation loads cleanly", function()
    local s, RH = Fight()
    eq(#RH.classData.badSpellIds, 0, "spell IDs")
    eq(s.ns.Spec.key, "feral_combat", "spec")
    local apl = s.ns.Recommender:GetAPL()
    eq(apl.name, "Feral cat & bear (default)", "rotation")
    eq(#apl.errors, 0, "compiles")
    Queue(s, 1)
    eq(#RH.errors, 0, "no errors while running (" .. tostring(RH.errors[1] and RH.errors[1].message) .. ")")
end)

test("opener: Faerie Fire, Mangle, Savage Roar, Rake (1 second GCD)", function()
    local s = Fight()
    eq(Queue(s, 4), "faerie_fire_feral, mangle_cat +1.0, savage_roar +2.0, rake +3.0", "opener")
    eq(s.ns.State.real.gcdDuration, 1, "GCD")
end)

test("anyone's Mangle or Trauma counts", function()
    local s = Fight()
    s:AddAura("target", { name = "Trauma", spellId = 46857, duration = 60, expires = s.time + 50, harmful = true,
        caster = "raid5" })
    falsy(Queue(s, 3):find("mangle_cat", 1, true), "a warrior's Trauma")
end)

test("5 points: Rip when it's running out, Ferocious Bite when everything's long", function()
    local s = Fight({ setUp = true, combo = 5 })
    eq(Queue(s, 1), "ferocious_bite", "Rip 11s, Savage Roar 30s")
    s.auras.target[4].expires = s.time + 1
    eq(Queue(s, 1), "rip", "Rip running out")
end)

test("energy costs: talents, Berserk halves them, Clearcasting makes them free", function()
    local s, RH = Fight({ setUp = true })
    local A, abilities = s.ns.Abilities, RH.classData.abilities
    local st = s.ns.State:Reset()
    eq(A.PowerCost(abilities.shred, st), 60 - 5 - 18, "Shred with Ferocity and Shredding Attacks")
    eq(A.PowerCost(abilities.mangle_cat, st), 45 - 5 - 6, "Mangle with Improved Mangle")
    s:AddAura("player", { name = "Berserk", spellId = 50334, duration = 15, expires = s.time + 15 })
    st = s.ns.State:Reset()
    near(A.PowerCost(abilities.shred, st), 37 / 2, "Berserk")
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    st = s.ns.State:Reset()
    eq(A.PowerCost(abilities.shred, st), 0, "Clearcasting")
    local v = s.ns.State:Virtual()
    A.Apply(v, "shred", v.now)
    eq(v.buffs.clearcasting, nil, "used up")
    eq(A.SpendsProc(st, "shred", "clearcasting", st.now) ~= nil, true, "glows")
end)

test("Tiger's Fury when low on energy (60 back with King of the Jungle)", function()
    local s, RH = Fight({ setUp = true, energy = 20 })
    RH.db.profile.toggles.cooldowns = true
    s.cooldowns["Berserk"] = { s.time, 180 }
    eq(Queue(s, 1), "tigers_fury", "20 energy")
    local st = s.ns.State:Reset()
    eq(s.ns.Abilities.PowerGain(RH.classData.abilities.tigers_fury), 60, "60 energy")
end)

test("simulator: Feral", function()
    local s = Fight()
    local summary = s.ns.Sim.Summarize(s.ns.Recommender:GetAPL(), { seconds = 180, cooldowns = true }, 2)
    local casts, uptime = {}, {}
    for _, c in ipairs(summary.casts) do casts[c.key] = c.perMinute end
    for _, d in ipairs(summary.debuffs) do uptime[d.key] = d.uptime end
    truthy((casts.shred or 0) > 12, "Shred per minute " .. tostring(casts.shred))
    truthy((casts.rip or 0) > 2, "Rip per minute " .. tostring(casts.rip))
    truthy((uptime.mangle or 0) > 90 and (uptime.rake or 0) > 80, "Mangle and Rake uptime")
end)
