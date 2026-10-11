-- Feral bear tanking: the Feral rotation switches to the bear lists in
-- (Dire) Bear Form. Rage, a 1.5 second GCD, Mangle (Bear), Lacerate stacks,
-- Maul on the next swing, Demoralizing Roar (anyone's), defensives.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Cat Form", "Mangle (Cat)", "Shred", "Rake", "Rip", "Savage Roar", "Ferocious Bite", "Tiger's Fury",
    "Berserk", "Faerie Fire (Feral)", "Mark of the Wild", "Dire Bear Form", "Mangle (Bear)", "Lacerate",
    "Swipe (Bear)", "Maul", "Demoralizing Roar", "Enrage", "Survival Instincts", "Barkskin", "Frenzied Regeneration" }

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- A bear in combat with a boss, `rage` (20: below Maul); `setUp` puts Mangle, Faerie Fire,
-- Demoralizing Roar and 5 Lacerates up; `cat` starts in Cat Form instead.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon({ class = "DRUID" })
    s.talentTabs = {
        { name = "Balance", talents = {} },
        { name = "Feral Combat", talents = { { "Ferocity", 5 }, { "Shredding Attacks", 2 }, { "Berserk", 1 },
            { "Mangle", 1 }, { "Improved Mangle", 3 } } },
        { name = "Restoration", talents = {} },
    }
    if opts.cat then
        s.power = { type = 3, current = 100, max = 100 }
    else
        s.power = { type = 1, current = opts.rage or 20, max = 100 }
    end
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    if not opts.outOfCombat then s:FireEvent("PLAYER_REGEN_DISABLED") end
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    if opts.cat then
        s:AddAura("player", { name = "Cat Form", spellId = 768, duration = 0, expires = 0 })
    else
        s:AddAura("player", { name = "Dire Bear Form", spellId = 9634, duration = 0, expires = 0 })
    end
    if opts.setUp then
        s:AddAura("target", { name = "Mangle (Bear)", spellId = 48564, duration = 60, expires = s.time + 50, harmful = true })
        s:AddAura("target", { name = "Faerie Fire (Feral)", spellId = 16857, duration = 300, expires = s.time + 200, harmful = true })
        s:AddAura("target", { name = "Demoralizing Roar", spellId = 48560, duration = 30, expires = s.time + 25, harmful = true })
        s:AddAura("target", { name = "Lacerate", spellId = 48568, count = 5, duration = 15, expires = s.time + 12, harmful = true })
        s.cooldowns["Mangle (Bear)"] = { s.time, 4.5 }
        s.cooldowns["Faerie Fire (Feral)"] = { s.time, 6 }
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

local function Option(s, key, value) s.ns.APLOptions.Set("feral_combat", key, value) end

test("bear: the abilities load cleanly, rage and a 1.5 second GCD", function()
    local s, RH = Fight()
    eq(#RH.classData.badSpellIds, 0, "spell IDs")
    eq(s.ns.Recommender:GetAPL().name, "Feral cat & bear (default)", "one rotation for both forms")
    eq(#s.ns.Recommender:GetAPL().errors, 0, "compiles")
    local st = s.ns.State:Reset()
    eq(st.gcdDuration, 1.5, "Bear Form GCD")
    eq(st.powerType, "rage", "rage")
    eq(st.powerRegen, 10, "rage income until the fight's is known")
    Queue(s, 1)
    eq(#RH.errors, 0, "no errors while running (" .. tostring(RH.errors[1] and RH.errors[1].message) .. ")")
    eq(Fight({ cat = true }).ns.State:Reset().gcdDuration, 1, "Cat Form GCD")
end)

test("bear: rage costs with Ferocity and Shredding Attacks", function()
    local s, RH = Fight()
    local A, abilities, st = s.ns.Abilities, RH.classData.abilities, s.ns.State:Reset()
    eq(A.PowerCost(abilities.mangle_bear, st), 15, "Mangle 20 - 5")
    eq(A.PowerCost(abilities.swipe_bear, st), 15, "Swipe 20 - 5")
    eq(A.PowerCost(abilities.maul, st), 10, "Maul 15 - 5")
    eq(A.PowerCost(abilities.lacerate, st), 13, "Lacerate 15 - 2")
    eq(A.CooldownDuration(abilities.mangle_bear), 4.5, "Mangle: 6 - 3 x 0.5 with Improved Mangle")
end)

test("bear: Mangle, Faerie Fire, Demoralizing Roar, then Lacerate", function()
    local s = Fight()
    eq(Queue(s, 4), "mangle_bear, faerie_fire_feral +1.5, demoralizing_roar +3.0, maul +3.0",
        "opener (Maul once rage reaches 25)")
    s = Fight({ setUp = true, rage = 20 })
    s.auras.target[4].count = 1
    eq(Queue(s, 1), "lacerate", "everything up, cooldowns running")
end)

test("bear: Lacerate to 5 stacks and before it falls off, else Swipe with spare rage", function()
    local s = Fight({ setUp = true, rage = 50 })
    eq(Queue(s, 1), "maul", "Maul first at 50 rage (off the GCD)")
    eq(Queue(s, 2):match(", (.*)"), "swipe_bear", "5 stacks, 12s left: Swipe")
    s.auras.target[4].expires = s.time + 3
    eq(Queue(s, 2):match(", (.*)"), "lacerate", "under 4 seconds: refresh")
    s.auras.target[4].expires = s.time + 12
    s.auras.target[4].count = 3
    eq(Queue(s, 2):match(", (.*)"), "lacerate", "3 stacks")
    s = Fight({ setUp = true, rage = 20 })
    eq(Queue(s, 1), "lacerate", "below the Swipe rage: Lacerate")
end)

test("bear: Maul from 25 rage (40 on 3+ enemies), not again while it's queued", function()
    local s, RH = Fight({ rage = 30 })
    eq(Queue(s, 2), "maul, mangle_bear", "next swing, off the GCD")
    s.current["Maul"] = true
    eq(Queue(s, 1), "mangle_bear", "already queued")
    s.current["Maul"] = nil
    Option(s, "maul_rage", 70)
    eq(Queue(s, 1), "mangle_bear", "below the setting")

    s, RH = Fight({ rage = 30 })
    RH.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 1), "swipe_bear", "3+ enemies, 30 rage: Swipe keeps the rage")
    s.power.current = 45
    eq(Queue(s, 2), "maul, swipe_bear", "45 rage")
    Option(s, "aoe_maul_rage", 50)
    eq(Queue(s, 1), "swipe_bear", "below the AoE setting")
end)

test("bear: wait for Mangle under a second away, for Faerie Fire under 1.5 seconds", function()
    local s = Fight({ setUp = true, rage = 20 })
    s.auras.target[4].count = 1 -- Lacerate to stack: the filler
    s.cooldowns["Mangle (Bear)"] = { s.time - 3.9, 4.5 } -- 0.5s left after the tick
    eq(Queue(s, 1), "mangle_bear +0.5", "Mangle 0.5s away: wait for it")
    s.cooldowns["Mangle (Bear)"] = { s.time - 2, 4.5 }
    eq(Queue(s, 1), "lacerate", "Mangle 2.4s away: Lacerate")
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 5, 6 } -- 0.9s left
    s.auras.target[4].count = 5
    eq(Queue(s, 1), "faerie_fire_feral +0.9", "Faerie Fire 0.9s away beats a filler Lacerate")
    s.cooldowns["Faerie Fire (Feral)"] = { s.time - 2, 6 }
    eq(Queue(s, 1), "lacerate", "Faerie Fire 3.9s away: Lacerate")
end)

test("bear: anyone's Demoralizing Roar or a Warrior's Demoralizing Shout counts; the setting turns it off", function()
    local s = Fight()
    s.cooldowns["Mangle (Bear)"] = { s.time, 4.5 }
    s:AddAura("target", { name = "Faerie Fire (Feral)", spellId = 16857, duration = 300, expires = s.time + 200, harmful = true })
    s.cooldowns["Faerie Fire (Feral)"] = { s.time, 6 }
    eq(Queue(s, 1), "demoralizing_roar", "missing")
    s:AddAura("target", { name = "Demoralizing Shout", spellId = 47437, duration = 30, expires = s.time + 25, harmful = true,
        caster = "raid3" })
    eq(Queue(s, 1), "lacerate", "a Warrior's shout")
    s.auras.target = {}
    s:AddAura("target", { name = "Faerie Fire (Feral)", spellId = 16857, duration = 300, expires = s.time + 200, harmful = true })
    Option(s, "demo_roar", false)
    eq(Queue(s, 1), "lacerate", "setting off")
end)

test("bear: Enrage when low on rage (short cooldowns, like Tiger's Fury), the setting at 0 never", function()
    local s, RH = Fight({ rage = 10, cooldowns = true })
    s.cooldowns["Berserk"] = { s.time, 180 }
    eq(Queue(s, 1), "enrage", "10 rage")
    RH.db.profile.toggles.cooldowns = false
    falsy(Queue(s, 3):find("enrage"), "cooldowns off")
    RH.db.profile.toggles.cooldowns = true
    eq(s.ns.Abilities.PowerGain(s.env.RotationHelper.classData.abilities.enrage), 20, "20 rage")
    Option(s, "enrage_rage", 0)
    falsy(Queue(s, 3):find("enrage"), "never")
end)

test("bear: Survival Instincts below 30% health, Barkskin below 50%; the setting turns them off", function()
    local s = Fight()
    s.player.health = 5000 -- 25%
    eq(Queue(s, 2), "survival_instincts, barkskin", "25%")
    s.player.health = 9000 -- 45%
    eq(Queue(s, 1), "barkskin", "45%")
    Option(s, "defensives", false)
    eq(Queue(s, 1), "mangle_bear", "setting off")
end)

test("bear: Berserk with cooldowns on; Mangle has no cooldown during it", function()
    local s = Fight({ rage = 60, cooldowns = true })
    s.current["Maul"] = true
    eq(Queue(s, 3), "berserk, mangle_bear, mangle_bear +1.5", "Berserk, then Mangle every GCD")
end)

test("bear: 3+ enemies: Swipe on every GCD it can, Berserk too", function()
    local s, RH = Fight({ setUp = true, rage = 30 })
    RH.db.profile.toggles.aoeMode = "aoe"
    eq(Queue(s, 2), "swipe_bear, swipe_bear +1.5", "Swipe")
    s.cooldowns["Mangle (Bear)"] = nil
    s:AddAura("player", { name = "Berserk", spellId = 50334, duration = 15, expires = s.time + 15 })
    eq(Queue(s, 1), "swipe_bear", "Berserk: still Swipe")
end)

test("shifting switches the suggestions; Cat Form isn't pushed on a bear", function()
    local s = Fight({ outOfCombat = true })
    -- (Cat Form's mana cost can't be paid from rage here, so give the state
    -- plenty of power: it's the rotation's condition that must say no.)
    local st = s.ns.State:Reset()
    st.power = 100000
    local action = s.ns.Recommender:Evaluate(st)
    falsy(action and action.name == "cat_form", "out of combat in Bear Form")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    eq(Queue(s, 1), "mangle_bear", "bear")
    s.auras.player = {}
    s:AddAura("player", { name = "Cat Form", spellId = 768, duration = 0, expires = 0 })
    s.power = { type = 3, current = 100, max = 100 }
    eq(Queue(s, 1), "faerie_fire_feral", "cat")
end)
