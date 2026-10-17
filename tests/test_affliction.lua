-- Affliction Warlock: DoT upkeep, Haunt, Everlasting Affliction, Drain Soul,
-- Life Tap.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Haunt", "Corruption", "Unstable Affliction", "Curse of Agony", "Curse of the Elements", "Shadow Bolt",
    "Drain Soul", "Seed of Corruption", "Searing Pain", "Life Tap", "Fel Armor", "Demon Skin" }

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local function Dot(s, name, id, remains)
    s:AddAura("target", { name = name, spellId = id, duration = 18, expires = s.time + remains, harmful = true })
end

-- An Affliction warlock in combat with a boss, Fel Armor up; `dots` puts all
-- DoTs and Haunt up and Haunt on cooldown.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon({ class = "WARLOCK" })
    s.talentTabs = {
        { name = "Affliction", talents = { { "Everlasting Affliction", 5 }, { "Haunt", 1 }, { "Unstable Affliction", 1 },
            { "Pandemic", 1 }, { "Shadow Embrace", 5 } } },
        { name = "Demonology", talents = { { "Demonic Embrace", 3 } } },
        { name = "Destruction", talents = { { "Bane", 5 } } },
    }
    s.power = { type = 0, current = opts.mana or 20000, max = 20000 }
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    RH.db.profile.display.showStatus = true -- the "2/3 CORR" status text is checked
    s:AddAura("player", { name = "Fel Armor", spellId = 47893, duration = 1800, expires = s.time + 1800 })
    if opts.dots then
        Dot(s, "Haunt", 59164, 10)
        Dot(s, "Unstable Affliction", 47843, opts.ua or 12)
        Dot(s, "Corruption", 47813, 15)
        Dot(s, "Curse of Agony", 47864, 20)
        s.cooldowns["Haunt"] = { s.time, 8 }
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

test("warlock: class data and the Affliction rotation load cleanly", function()
    local s, RH = Fight()
    eq(#RH.classData.badSpellIds, 0, "spell IDs")
    eq(s.ns.Spec.key, "affliction", "spec")
    local apl = s.ns.Recommender:GetAPL()
    eq(apl.name, "Affliction (default)", "rotation")
    eq(#apl.errors, 0, "compiles")
    Queue(s, 1)
    eq(#RH.errors, 0, "no errors while running (" .. tostring(RH.errors[1] and RH.errors[1].message) .. ")")
end)

test("opener: Haunt, Unstable Affliction, Corruption, Curse of Agony", function()
    local s = Fight()
    eq(Queue(s, 4), "haunt, unstable_affliction +1.5, corruption +3.0, curse_of_agony +4.5", "opener")
end)

test("everything up: Shadow Bolt (2.5s with Bane)", function()
    local s = Fight({ dots = true })
    eq(Queue(s, 3), "shadow_bolt, shadow_bolt +2.5, shadow_bolt +5.0", "Shadow Bolt filler, 2.5s casts")
end)

test("Unstable Affliction is recast as it runs out", function()
    local s = Fight({ dots = true, ua = 1 })
    eq(Queue(s, 1), "unstable_affliction", "1s left, 1.5s cast")
end)

test("Everlasting Affliction: Shadow Bolt refreshes Corruption", function()
    local s = Fight({ dots = true })
    s.ns.State:Reset()
    local st = s.ns.State:Virtual()
    s.ns.Abilities.Apply(st, "shadow_bolt", st.now)
    near(st.debuffs.corruption.expires, st.now + 2.5 + 18, "refreshed when the bolt lands")
end)

test("Drain Soul below 25%; Life Tap for mana and while moving", function()
    local s = Fight({ dots = true })
    s.target.health = 20
    eq(Queue(s, 1), "drain_soul", "execute")
    -- A 15 second channel, cut after the tick (every 3 seconds) once Haunt is back (7.9s).
    eq(Queue(s, 2), "drain_soul, haunt +9.0", "cut after the third tick")
    s = Fight({ dots = true, mana = 3000 })
    eq(Queue(s, 1), "life_tap", "15% mana")
    s = Fight({ dots = true, mana = 12000 })
    s.speed = 7
    eq(Queue(s, 1), "life_tap", "moving")
end)

test("simulator: Affliction keeps its DoTs up", function()
    local s = Fight()
    local summary = s.ns.Sim.Summarize(s.ns.Recommender:GetAPL(), { seconds = 180, cooldowns = true }, 2)
    local casts, uptime = {}, {}
    for _, c in ipairs(summary.casts) do casts[c.key] = c.perMinute end
    for _, d in ipairs(summary.debuffs) do uptime[d.key] = d.uptime end
    truthy(summary.gcdUsage > 95, "time spent casting " .. summary.gcdUsage)
    truthy((casts.corruption or 0) < 1, "Corruption kept up by Everlasting Affliction: " .. tostring(casts.corruption))
    truthy((casts.haunt or 0) > 5, "Haunt per minute " .. tostring(casts.haunt))
    for key, value in pairs(uptime) do truthy(value > 88, key .. " uptime " .. value) end
end)

test("several enemies: Corruption counted on each ('2/3 CORR'), active_dot for all three dots", function()
    local Mock = require("wowmock")
    local s, RH = Fight({ dots = true })
    local function Log(subevent, guid, spellId, name)
        -- After the school: the damage amount for a hit, the aura type for an aura event.
        local extra = subevent == "SPELL_DAMAGE" and 100 or "DEBUFF"
        s:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", s.time, subevent, Mock.PLAYER_GUID, "Me", Mock.FLAGS_ME,
            guid, "Mob", Mock.FLAGS_HOSTILE_NPC, spellId, name, 32, extra)
    end
    for i = 1, 2 do Log("SPELL_DAMAGE", "0xF1300000000000D" .. i, 686, "Shadow Bolt") end
    Log("SPELL_AURA_APPLIED", "0xF1300000000000D1", 47813, "Corruption")
    Log("SPELL_AURA_APPLIED", "0xF1300000000000D1", 47864, "Curse of Agony")
    s:Tick(0.1)
    eq(s.ns.State.real.activeEnemies, 3, "3 enemies")
    truthy(s.ns.Display:GetStatusText():find("2/3 CORR", 1, true), "status: " .. s.ns.Display:GetStatusText())
    local st = s.ns.State:Reset()
    local resolve = function(name) return s.ns.Recommender.resolver(name) end
    eq(s.ns.APL.Compiler.CompileExpression("active_dot.corruption", resolve)(st), 2, "Corruption")
    eq(s.ns.APL.Compiler.CompileExpression("active_dot.curse_of_agony", resolve)(st), 2, "Curse of Agony")
    eq(s.ns.APL.Compiler.CompileExpression("active_dot.unstable_affliction", resolve)(st), 1, "only the target")
    Log("SPELL_AURA_APPLIED", "0xF1300000000000D2", 47813, "Corruption")
    s:Tick(0.1)
    truthy(s.ns.Display:GetStatusText():find("3/3 CORR", 1, true), "all")
    -- Destruction tracks nothing.
    falsy(RH.classData.trackDots.destruction, "per spec")
end)
