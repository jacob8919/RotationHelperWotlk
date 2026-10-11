-- Feral cat at 5 combo points with nothing to spend them on yet: the queue
-- must never go blank, and a cooldown that's still recharging (a trinket)
-- must not fill the gap.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local SPELLS = { "Cat Form", "Mangle (Cat)", "Shred", "Rake", "Rip", "Savage Roar", "Ferocious Bite", "Tiger's Fury",
    "Berserk", "Faerie Fire (Feral)", "Mark of the Wild" }

local TRINKET = { "Some Trinket", "i", "Some Use",
    tooltip = { "Some Trinket", "Use: Increases attack power by 1024 for 20 sec. (2 Min Cooldown)" } }

-- A cat at 5 points, Faerie Fire, Mangle, Rake and Savage Roar up.
-- opts: energy, rip (seconds left, nil = no Rip), roar (seconds left),
-- ttd (target's time to die), cooldowns, trinketUsed (seconds ago).
local function Fight(opts)
    local s, RH = newAddon({ class = "DRUID" })
    s.talentTabs = {
        { name = "Balance", talents = { { "Starlight Wrath", 2 } } },
        { name = "Feral Combat", talents = { { "Ferocity", 5 }, { "Shredding Attacks", 2 }, { "King of the Jungle", 3 },
            { "Berserk", 1 }, { "Mangle", 1 }, { "Improved Mangle", 3 } } },
        { name = "Restoration", talents = { { "Omen of Clarity", 1 } } },
    }
    s.power = { type = 3, current = opts.energy or 30, max = 100 }
    s.combo = opts.combo or 5
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    if opts.trinketUsed then
        s.items[50000] = TRINKET
        s.equipped[13] = 50000
        s:FireEvent("PLAYER_EQUIPMENT_CHANGED")
        s.itemCooldowns[50000] = { s.time - opts.trinketUsed, 120 }
    end
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    if opts.ttd then s.ns.Targets.TimeToDie = function() return opts.ttd end end
    s:AddAura("player", { name = "Cat Form", spellId = 768, duration = 0, expires = 0 })
    s:AddAura("target", { name = "Faerie Fire (Feral)", spellId = 16857, duration = 300, expires = s.time + 200, harmful = true })
    s:AddAura("target", { name = "Mangle (Cat)", spellId = 48566, duration = 60, expires = s.time + 50, harmful = true })
    s:AddAura("target", { name = "Rake", spellId = 48574, duration = 9, expires = s.time + 8, harmful = true })
    if opts.rip then
        s:AddAura("target", { name = "Rip", spellId = 49800, duration = 12, expires = s.time + opts.rip, harmful = true })
    end
    s:AddAura("player", { name = "Savage Roar", spellId = 52610, duration = 34, expires = s.time + (opts.roar or 30) })
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

test("5 points on a dying mob (no Rip worth it): Ferocious Bite, not a blank display", function()
    local s = Fight({ ttd = 6, energy = 30 })
    eq(Queue(s, 1), "ferocious_bite +0.5", "mob dies in 6s (35 energy for Bite)")
end)

test("5 points, Rip too short to Bite, not yet due: pool for Rip, not a blank display", function()
    local s = Fight({ rip = 5, energy = 30 })
    eq(Queue(s, 1), "rip +2.9", "Rip 4.9s left: refresh at 2s left")
end)

test("5 points, Savage Roar runs out first: pool for Savage Roar", function()
    local s = Fight({ rip = 7, roar = 4, energy = 30 })
    eq(Queue(s, 1), "savage_roar +1.9", "Roar 4s, Rip 7s")
end)

test("5 points while pooling: Shred before energy caps", function()
    local s = Fight({ rip = 7, energy = 70 })
    eq(Queue(s, 1), "shred +1.0", "70 energy, Rip 7s: Shred at 80")
    s = Fight({ rip = 7, energy = 90 })
    eq(Queue(s, 1), "shred", "already at 90")
end)

test("boss, trinket recharging: the gap isn't filled with the trinket", function()
    local s = Fight({ rip = 5, energy = 30, cooldowns = true, trinketUsed = 5 })
    local q = Queue(s, 2)
    falsy(q:find("^trinket1"), "trinket first: " .. q)
    eq(q:match("^[^,]+"), "rip +2.9", "pool for Rip")
end)

test("nothing to wait for: Ferocious Bite when Rip and Savage Roar are long", function()
    local s = Fight({ rip = 11, energy = 40 })
    eq(Queue(s, 1), "ferocious_bite", "Rip 11s")
end)

test("sweep: the cat queue is never blank, never led by a recharging trinket", function()
    local bad = {}
    for _, combo in ipairs({ 0, 3, 5 }) do
        for _, energy in ipairs({ 0, 30, 60, 85, 100 }) do
            for _, rip in ipairs({ false, 1, 4, 7, 12 }) do
                for _, roar in ipairs({ 1, 5, 9, 20 }) do
                    for _, ttd in ipairs({ 4, 30 }) do
                        for _, notBehind in ipairs({ false, true }) do
                            local s, RH = Fight({ combo = combo, energy = energy, rip = rip or nil, roar = roar,
                                ttd = ttd, cooldowns = true, trinketUsed = 5 })
                            s.ns.APLOptions.Set("feral_combat", "not_behind", notBehind)
                            local q = Queue(s, 1)
                            local wait = tonumber(q:match("%+([%d.]+)")) or 0
                            if q == "" or q:find("^trinket") or wait > 6 then
                                bad[#bad + 1] = ("cp%d e%d rip%s roar%d ttd%d nb%s: '%s'"):format(combo, energy,
                                    tostring(rip), roar, ttd, tostring(notBehind), q)
                            end
                        end
                    end
                end
            end
        end
    end
    eq(#bad, 0, table.concat(bad, "; "):sub(1, 600))
end)
