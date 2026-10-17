-- Destruction Warlock: Immolate, Conflagrate and Backdraft, Chaos Bolt,
-- curses by fight length.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Immolate", "Conflagrate", "Chaos Bolt", "Incinerate", "Curse of Doom", "Curse of Agony", "Corruption",
    "Shadow Bolt", "Seed of Corruption", "Searing Pain", "Life Tap", "Fel Armor", "Demon Skin" }

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- A Destruction warlock in combat with a boss, Fel Armor up; `setUp` puts
-- Immolate and Curse of Doom up and Conflagrate and Chaos Bolt on cooldown.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon({ class = "WARLOCK" })
    s.talentTabs = {
        { name = "Affliction", talents = { { "Improved Curse of Agony", 2 } } },
        { name = "Demonology", talents = { { "Demonic Embrace", 3 } } },
        { name = "Destruction", talents = { { "Bane", 5 }, { "Emberstorm", 5 }, { "Backdraft", 3 }, { "Conflagrate", 1 },
            { "Chaos Bolt", 1 }, { "Ruin", 5 }, { "Devastation", 1 } } },
    }
    s.power = { type = 0, current = opts.mana or 20000, max = 20000 }
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    s:AddAura("player", { name = "Fel Armor", spellId = 47893, duration = 1800, expires = s.time + 1800 })
    if opts.setUp then
        s:AddAura("target", { name = "Immolate", spellId = 47811, duration = 15, expires = s.time + 12, harmful = true })
        s:AddAura("target", { name = "Curse of Doom", spellId = 47867, duration = 60, expires = s.time + 50, harmful = true })
        s.cooldowns["Conflagrate"] = { s.time, 10 }
        s.cooldowns["Chaos Bolt"] = { s.time, 12 }
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

local function Eval(s, text)
    local resolve = s.ns.Expressions.CreateResolver(s.env.RotationHelper.classData)
    local fn, message = s.ns.APL.Compiler.CompileExpression(text, resolve)
    if not fn then error("compile failed: " .. message, 2) end
    return fn(s.ns.State:Reset())
end

test("destruction: the rotation loads cleanly", function()
    local s, RH = Fight()
    eq(s.ns.Spec.key, "destruction", "spec")
    local apl = s.ns.Recommender:GetAPL()
    eq(apl.name, "Destruction (default)", "rotation")
    eq(#apl.errors, 0, "compiles")
    Queue(s, 1)
    eq(#RH.errors, 0, "no errors while running (" .. tostring(RH.errors[1] and RH.errors[1].message) .. ")")
end)

test("opener: Immolate, Conflagrate (uses Immolate up), Immolate again, Chaos Bolt", function()
    local s = Fight()
    eq(Queue(s, 4), "immolate, conflagrate +1.5, immolate +3.0, chaos_bolt +4.0", "opener")
end)

test("Glyph of Conflagrate keeps Immolate", function()
    local s = Fight()
    s.glyphs = { 56235 } -- Glyph of Conflagrate
    s.spells[56235] = { "Glyph of Conflagrate", "i" }
    s:FireEvent("GLYPH_ADDED")
    eq(Queue(s, 3), "immolate, conflagrate +1.5, chaos_bolt +3.0", "glyphed")
end)

test("Backdraft: three faster casts after Conflagrate", function()
    local s, RH = Fight({ setUp = true })
    near(Eval(s, "action.incinerate.cast_time"), 2.25, "Incinerate with Emberstorm 5/5")
    s:AddAura("player", { name = "Backdraft", spellId = 54277, count = 3, duration = 15, expires = s.time + 15 })
    near(Eval(s, "action.incinerate.cast_time"), 2.25 * 0.7, "30% faster")
    s.ns.State:Reset()
    local st = s.ns.State:Virtual()
    for i = 1, 3 do
        s.ns.Abilities.Apply(st, "incinerate", st.castEnd)
    end
    eq(st.buffs.backdraft, nil, "used up after three")
end)

test("Backdraft shortens the GCD too, to no less than a second", function()
    local s, RH = Fight({ setUp = true })
    local Abilities, incinerate = s.ns.Abilities, RH.classData.abilities.incinerate
    local st = s.ns.State:Reset()
    near(Abilities.Gcd(st, incinerate), 1.5, "without")
    s:AddAura("player", { name = "Backdraft", spellId = 54277, count = 3, duration = 15, expires = s.time + 15 })
    st = s.ns.State:Reset()
    near(Abilities.Gcd(st, incinerate), 1.05, "30% shorter")
    near(Eval(s, "action.incinerate.execute_time"), 2.25 * 0.7, "the cast is still longer")
    eq(Abilities.Gcd(st, RH.classData.abilities.conflagrate), 1.5, "not Conflagrate")
    local v = s.ns.State:Virtual()
    Abilities.Apply(v, "incinerate", v.now)
    near(v.gcdEnd - v.now, 1.05, "applied")
    st.gcdDuration = 1.2 -- lots of haste
    near(Abilities.Gcd(st, incinerate), 1, "floor")
end)

test("curses: Doom when the target lives a minute, else Agony", function()
    local s = Fight({ setUp = true })
    s.auras.target[2] = nil -- no Curse of Doom
    eq(Queue(s, 1), "curse_of_doom", "long fight (time to die unknown)")
    -- Losing 4% a second: dying in about 20 seconds.
    for i = 1, 12 do
        s.target.health = 100 - i * 2
        s:Tick(0.5)
    end
    eq(Queue(s, 1), "curse_of_agony", "short fight")
end)

test("filler: Incinerate", function()
    local s = Fight({ setUp = true })
    eq(Queue(s, 1), "incinerate", "Incinerate")
    local recs = s.env.RotationHelper.recommendations
    eq(recs[2].name, "incinerate", "and again")
    near(recs[2].wait, 2.25, "after the 2.25s cast", 0.01)
end)

test("simulator: Destruction", function()
    local s = Fight()
    local summary = s.ns.Sim.Summarize(s.ns.Recommender:GetAPL(), { seconds = 180, cooldowns = true }, 2)
    local casts = {}
    for _, c in ipairs(summary.casts) do casts[c.key] = c.perMinute end
    truthy(summary.gcdUsage > 95, "time spent casting " .. summary.gcdUsage)
    truthy((casts.conflagrate or 0) > 5, "Conflagrate per minute " .. tostring(casts.conflagrate))
    truthy((casts.chaos_bolt or 0) > 3.5, "Chaos Bolt per minute (12s cooldown + cast) " .. tostring(casts.chaos_bolt))
    truthy((casts.incinerate or 0) > 8, "Incinerate per minute " .. tostring(casts.incinerate))
    truthy(summary.debuffs[1] and summary.debuffs[1].uptime > 80, "Immolate uptime")
end)

test("casting Immolate: its DoT counts as up when it lands, so it isn't suggested again", function()
    local s = Fight()
    eq(Queue(s, 1), "immolate", "no Immolate yet")
    s.playerCast = { name = "Immolate", startedAgo = 0.5, endsIn = 1 }
    local queue = Queue(s, 2)
    eq(queue:match("^([%w_]+)"), "conflagrate", "Conflagrate next, on the Immolate being cast: " .. queue)
end)

-- After a spell lands, the game shows its DoT a moment later (or never, if
-- it missed). Until the combat log says, it still counts as applied.
local function Landed(s, spellName)
    s:FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", spellName)
end
local function CombatLog(s, subevent, spellId, spellName)
    local Mock = require("wowmock")
    -- After the school: the damage amount for a hit, the miss type for a miss.
    local extra = subevent == "SPELL_MISSED" and "MISS" or 100
    s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, subevent, Mock.PLAYER_GUID, "Me", Mock.FLAGS_ME,
        "0xF130000000000099", "Mob", Mock.FLAGS_HOSTILE_NPC, spellId, spellName, 4, extra)
end

test("a DoT that just landed counts as up until the game shows it", function()
    local s = Fight()
    eq(Queue(s, 1), "immolate", "no Immolate")
    Landed(s, "Immolate")
    T.falsy(Queue(s, 1) == "immolate", "just landed: not again")
    -- The hit in the combat log and the debuff arrive: the game's state takes over.
    CombatLog(s, "SPELL_DAMAGE", 47811, "Immolate")
    s:AddAura("target", { name = "Immolate", spellId = 47811, duration = 15, expires = s.time + 15, harmful = true })
    s:Tick(0.2)
    T.falsy(Queue(s, 1) == "immolate", "up for real")
end)

test("a DoT that missed is suggested again at once", function()
    local s = Fight()
    Landed(s, "Immolate")
    T.falsy(Queue(s, 1) == "immolate", "just landed")
    CombatLog(s, "SPELL_MISSED", 47811, "Immolate")
    eq(Queue(s, 1), "immolate", "resisted: again")
end)

test("with no word from the combat log, it counts for a second at most", function()
    local s = Fight()
    Landed(s, "Immolate")
    T.falsy(Queue(s, 1) == "immolate", "just landed")
    s:Tick(1)
    eq(Queue(s, 1), "immolate", "after the grace")
end)
