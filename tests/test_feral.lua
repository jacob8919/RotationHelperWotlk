-- Feral cat Druid: Cat Form energy, 1 second GCD, Savage Roar, Rip, Rake,
-- Mangle (anyone's), Clearcasting, Berserk, Tiger's Fury; Whitemane's Glyph
-- of Omen of Clarity and the 3+ target list (Swipe).
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Cat Form", "Mangle (Cat)", "Shred", "Rake", "Rip", "Savage Roar", "Ferocious Bite", "Tiger's Fury",
    "Berserk", "Faerie Fire (Feral)", "Mark of the Wild", "Swipe (Cat)" }

-- Whitemane's custom glyph has no known spell ID; it's found by name.
local GLYPH_ID = 999001

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- A cat in combat with a boss; `setUp` puts Faerie Fire, Mangle, Rake, Rip
-- and Savage Roar up; `glyph` socket the Glyph of Omen of Clarity.
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
    if opts.glyph then
        s.glyphs[1] = GLYPH_ID
        s.spells[GLYPH_ID] = { "Glyph of Omen of Clarity", "i" }
    end
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

test("Tiger's Fury when its 60 energy (King of the Jungle) won't cap by the end of the GCD", function()
    local s, RH = Fight({ setUp = true, energy = 20 })
    eq(Queue(s, 1), "tigers_fury", "20 energy")
    eq(s.ns.Abilities.PowerGain(RH.classData.abilities.tigers_fury), 60, "60 energy")
    s.power.current = 39
    eq(Queue(s, 1), "tigers_fury", "39 energy, no GCD running: 99 after")
    s.power.current = 41
    falsy(Queue(s, 1) == "tigers_fury", "41: would cap")
    -- Half a GCD left: 5 more energy comes in before the next ability.
    s.cooldowns["Mark of the Wild"] = { s.time - 0.5, 1 }
    s.power.current = 34
    eq(Queue(s, 1), "tigers_fury", "34 energy, 0.5s of GCD left: 99 at its end")
    s.power.current = 45
    falsy(Queue(s, 1) == "tigers_fury", "45: would cap")
end)

test("Tiger's Fury with Clearcasting: 10 energy lower, since the next ability is free", function()
    local s = Fight({ setUp = true, energy = 35 })
    eq(Queue(s, 1), "tigers_fury", "35 energy")
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    s.power.current = 35
    falsy(Queue(s, 1) == "tigers_fury", "35 with Clearcasting: the free Shred doesn't spend any")
    s.power.current = 25
    eq(Queue(s, 1), "tigers_fury", "25 with Clearcasting")
end)

test("Tiger's Fury is part of the rotation: shown with the cooldown toggle off", function()
    local s, RH = Fight({ setUp = true, energy = 20 })
    RH.db.profile.toggles.cooldowns = false
    eq(Queue(s, 1), "tigers_fury", "CD off")
    RH.db.profile.toggles.cooldowns = true
    RH.db.profile.display.separateCooldowns = true -- major cooldowns in their own display
    s:FireEvent("PLAYER_TALENT_UPDATE")
    eq(Queue(s, 1), "tigers_fury", "separate cooldowns display")
end)

test("Tiger's Fury can't be used during Berserk: suggested once it ends", function()
    local s, RH = Fight({ setUp = true, energy = 20 })
    s:AddAura("player", { name = "Berserk", spellId = 50334, duration = 15, expires = s.time + 3 })
    local queue = Queue(s, 4)
    falsy(queue:match("^tigers_fury"), "not now: " .. queue)
    local recs = s.env.RotationHelper.recommendations
    local found
    for _, e in ipairs(recs) do
        if e.name == "tigers_fury" then found = e end
    end
    truthy(found and found.wait > 2.5 and found.limitedBy == "berserk",
        "after Berserk: " .. queue .. " (" .. tostring(found and found.limitedBy) .. ")")
    local st = s.ns.State:Reset()
    local at, limitedBy = s.ns.Abilities.ReadyAt(st, "tigers_fury")
    near(at - st.now, 2.9, "ready when Berserk ends (0.1s on)", 0.05)
    eq(limitedBy, "berserk", "limited by Berserk")
end)

test("Berserk right after Tiger's Fury, never while Tiger's Fury is about to come back", function()
    local s, RH = Fight({ setUp = true, energy = 20 })
    RH.db.profile.toggles.cooldowns = true
    eq(Queue(s, 2), "tigers_fury, berserk", "Tiger's Fury, then Berserk")
    s.cooldowns["Tiger's Fury"] = { s.time - 20, 30 } -- back in 10s: Berserk would block it
    s.power.current = 80
    falsy(Queue(s, 3):find("berserk", 1, true), "Berserk waits for Tiger's Fury")
    s.cooldowns["Tiger's Fury"] = { s.time - 5, 30 } -- back in 25s
    eq(Queue(s, 1), "berserk", "Berserk when Tiger's Fury is far away")
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

---------------------------------------------------------------------------
-- Glyph of Omen of Clarity (Whitemane): Faerie Fire (Feral) always procs
-- Clearcasting with the Omen of Clarity talent.
---------------------------------------------------------------------------
test("glyph: found by name, whatever its spell ID", function()
    local s = Fight({ glyph = true })
    truthy(s.ns.Spec.glyphs.omen_of_clarity, "glyph.omen_of_clarity")
    falsy(Fight().ns.Spec.glyphs.omen_of_clarity, "not socketed")
end)

test("glyph: Faerie Fire (Feral) predicts Clearcasting, only with the talent", function()
    local function AfterFaerieFire(s)
        s.ns.State:Reset()
        local v = s.ns.State:Virtual()
        s.ns.Abilities.Apply(v, "faerie_fire_feral", v.now)
        local rec = v.buffs.clearcasting
        return rec and rec.expires > v.now and rec.expires - v.now or nil
    end
    near(AfterFaerieFire(Fight({ glyph = true })), 15, "Clearcasting for 15 seconds")
    eq(AfterFaerieFire(Fight()), nil, "no glyph")
    local s = Fight({ glyph = true })
    s.talentTabs[3].talents = {}
    s:FireEvent("PLAYER_TALENT_UPDATE")
    eq(AfterFaerieFire(s), nil, "no Omen of Clarity talent")
end)

test("glyph: Faerie Fire on cooldown, its Clearcasting spent on Shred", function()
    local s = Fight({ setUp = true, glyph = true, combo = 2, energy = 40 })
    eq(Queue(s, 2), "faerie_fire_feral, shred +1.0", "free Shred after Faerie Fire")
    s = Fight({ setUp = true, combo = 2, energy = 40 })
    eq(Queue(s, 1), "shred", "no glyph: Shred, Faerie Fire is up")
end)

test("glyph: no Faerie Fire about to cap energy, or with Clearcasting already up", function()
    local s = Fight({ setUp = true, glyph = true, combo = 2, energy = 95 })
    eq(Queue(s, 1), "shred", "95 energy")
    s = Fight({ setUp = true, glyph = true, combo = 2, energy = 40 })
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    eq(Queue(s, 1), "shred", "Clearcasting up")
end)

test("glyph: Clearcasting goes on Shred before Rake (Mangle when not behind)", function()
    local s = Fight({ setUp = true, glyph = true, combo = 2, energy = 50 })
    s.auras.target[3].expires = s.time + 0.5 -- Rake running out
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    eq(Queue(s, 1), "shred", "glyph")
    s.ns.APLOptions.Set("feral_combat", "not_behind", true)
    eq(Queue(s, 1), "mangle_cat", "not behind")

    s = Fight({ setUp = true, combo = 2, energy = 50 })
    table.remove(s.auras.target, 3) -- Rake has fallen off
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    eq(Queue(s, 1), "rake", "no glyph: the usual priority")
end)

---------------------------------------------------------------------------
-- 3+ targets: Savage Roar, then Swipe (Cat)
---------------------------------------------------------------------------
test("AoE: Swipe with Savage Roar up, no single-target debuffs", function()
    local s, RH = Fight({ setUp = true, combo = 2 })
    RH.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 2), "swipe_cat, swipe_cat +1.0", "100 energy: two Swipes")
    eq(s.ns.Abilities.PowerCost(RH.classData.abilities.swipe_cat, s.ns.State:Reset()), 45, "50 - Ferocity")
    RH.db.profile.toggles.aoeMode = "single"
    falsy(Queue(s, 1):find("swipe"), "one target: no Swipe")
end)

test("AoE: Savage Roar first, building its point with Mangle", function()
    local s, RH = Fight({ combo = 0 })
    RH.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 3), "mangle_cat, savage_roar +1.0, swipe_cat +2.0", "no points")
    s = Fight({ combo = 1 })
    s.env.RotationHelper.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 1), "savage_roar", "one point is enough")
end)

test("AoE: Clearcasting makes a Swipe free; with the glyph, Faerie Fire for it", function()
    local s, RH = Fight({ setUp = true, energy = 10 })
    RH.db.profile.toggles.aoeMode = "aoe"
    s.cooldowns["Tiger's Fury"] = { s.time, 30 } -- (it comes first at 10 energy)
    s:AddAura("player", { name = "Clearcasting", spellId = 16870, duration = 15, expires = s.time + 15 })
    eq(Queue(s, 1), "swipe_cat", "free at 10 energy")
    s = Fight({ setUp = true, glyph = true, energy = 10 })
    s.cooldowns["Tiger's Fury"] = { s.time, 30 }
    s.env.RotationHelper.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 2), "faerie_fire_feral, swipe_cat +1.0", "glyph")
end)

---------------------------------------------------------------------------
-- Tuned with WoWSims (docs/WHITEMANE.md, "DPS tuning")
---------------------------------------------------------------------------
test("tuning: Rake once it has fallen off, not before", function()
    local s = Fight({ setUp = true, combo = 2, energy = 50 })
    s.auras.target[3].expires = s.time + 0.5
    eq(Queue(s, 1), "shred", "0.5s left: Shred")
    table.remove(s.auras.target, 3)
    eq(Queue(s, 1), "rake", "off: Rake")
end)

test("tuning: with the glyph, builders wait for Faerie Fire under half a second away", function()
    local s = Fight({ setUp = true, glyph = true, combo = 2, energy = 50 })
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 5.7, 6 } -- 0.2s left after the tick
    eq(Queue(s, 2), "faerie_fire_feral +0.2, shred +1.2", "wait for Faerie Fire and its free Shred")
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 4, 6 }
    eq(Queue(s, 1), "shred", "2 seconds away: Shred")
    s = Fight({ setUp = true, glyph = true, combo = 2, energy = 85 })
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 5.7, 6 }
    eq(Queue(s, 1), "shred", "high energy: don't wait")
    s = Fight({ setUp = true, combo = 2, energy = 50 })
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 5.7, 6 }
    eq(Queue(s, 1), "shred", "no glyph: don't wait")
end)
