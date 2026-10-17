local T = require("testlib")
local Mock = require("wowmock")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local ME, HOSTILE, FRIENDLY = Mock.FLAGS_ME, Mock.FLAGS_HOSTILE_NPC, Mock.FLAGS_FRIENDLY_NPC
local PLAYER = Mock.PLAYER_GUID

local function Count(s) return s.ns.Targets:CountEnemies(s.time) end

local function Hit(s, guid, subevent)
    s:CombatLog(subevent or "SPELL_DAMAGE", PLAYER, ME, guid, HOSTILE)
end

---------------------------------------------------------------------------
-- Enemy counting
---------------------------------------------------------------------------
test("counts hostile units we damage, once each", function()
    local s = newAddon()
    Hit(s, "mob1")
    Hit(s, "mob2", "SWING_DAMAGE")
    Hit(s, "mob2", "SWING_MISSED")
    Hit(s, "mob3", "SPELL_PERIODIC_DAMAGE")
    eq(Count(s), 3, "three enemies")
end)

test("our debuffs and hostile attacks on us count", function()
    local s = newAddon()
    Hit(s, "mob1", "SPELL_AURA_APPLIED")
    s:CombatLog("SWING_DAMAGE", "mob2", HOSTILE, PLAYER, ME)
    eq(Count(s), 2, "debuffed + attacking us")
end)

test("friendly units and other people's fights don't count", function()
    local s = newAddon()
    s:CombatLog("SPELL_DAMAGE", PLAYER, ME, "friend", FRIENDLY)
    s:CombatLog("SPELL_DAMAGE", "someone", 0x514, "mob1", HOSTILE)   -- a party member's hit
    s:CombatLog("SPELL_AURA_APPLIED", "mob2", HOSTILE, PLAYER, ME)  -- a debuff on us
    s:CombatLog("SPELL_HEAL", PLAYER, ME, "mob3", HOSTILE)          -- not a fight event
    eq(Count(s), 0, "nothing counted")
end)

test("enemies time out after 6 seconds without activity", function()
    local s = newAddon()
    Hit(s, "mob1")
    s.time = s.time + 4
    Hit(s, "mob2")
    s.time = s.time + 3
    eq(Count(s), 1, "mob1 timed out, mob2 still counted")
end)

test("deaths and the end of combat clear enemies", function()
    local s = newAddon()
    Hit(s, "mob1")
    Hit(s, "mob2")
    s:CombatLog("UNIT_DIED", nil, 0, "mob1", HOSTILE)
    eq(Count(s), 1, "dead mob removed")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    s:FireEvent("PLAYER_REGEN_ENABLED")
    eq(Count(s), 0, "combat over")
end)

test("active_enemies by AoE mode", function()
    local s = newAddon()
    local Targets = s.ns.Targets
    Hit(s, "mob1")
    Hit(s, "mob2")
    eq(Targets:ActiveEnemies(s.time, "auto", false), 2, "auto")
    eq(Targets:ActiveEnemies(s.time, "single", false), 1, "single")
    eq(Targets:ActiveEnemies(s.time, "aoe", false), 3, "aoe forces at least 3")
    Hit(s, "mob3")
    Hit(s, "mob4")
    eq(Targets:ActiveEnemies(s.time, "aoe", false), 4, "aoe with more")
end)

test("a hostile target counts before anyone hits it", function()
    local s = newAddon()
    local Targets = s.ns.Targets
    s.hasTarget = true
    eq(Targets:ActiveEnemies(s.time, "auto", true), 1, "just the target")
    Hit(s, "mob1")
    eq(Targets:ActiveEnemies(s.time, "auto", true), 2, "target + another")
    Hit(s, s.target.guid)
    eq(Targets:ActiveEnemies(s.time, "auto", true), 2, "target isn't counted twice")
    eq(Targets:ActiveEnemies(s.time, "auto", false), 2, "no target")
end)

test("auto AoE mode switches the rotation to the AoE list", function()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Pestilence", "Howling Blast", "Horn of Winter")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 15, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 15, harmful = true })
    local function First()
        local st = s.ns.State:Reset()
        local action = s.ns.Recommender:Evaluate(st)
        return action and action.name, st.activeEnemies
    end
    eq(First(), "obliterate", "single target")
    Hit(s, s.target.guid)
    Hit(s, "mob2")
    Hit(s, "mob3")
    local name, enemies = First()
    eq(enemies, 3, "three enemies")
    eq(name, "pestilence", "AoE list")
    s:Slash("ACECONSOLE_RH", "aoe") -- auto -> single
    eq(First(), "obliterate", "forced single target")
end)

---------------------------------------------------------------------------
-- Time to die
---------------------------------------------------------------------------
-- Ticks the addon for `seconds` while the target loses `perSecond` health.
local function Fight(s, seconds, perSecond)
    for _ = 1, seconds * 10 do
        s.target.health = math.max(0, s.target.health - perSecond / 10)
        s:Tick(0.1)
    end
end

local function TTD(s) return s.ns.Targets:TimeToDie(s.time) end

test("time to die from a steady health loss", function()
    local s = newAddon()
    s.hasTarget = true
    s.target.health, s.target.healthMax = 100000, 100000
    Fight(s, 5, 2000)
    local ttd = TTD(s)
    truthy(math.abs(ttd - 45) < 0.5, "90000 health at 2000/s is about 45s (got " .. ttd .. ")")
end)

test("time to die is unknown without enough data or damage", function()
    local s = newAddon()
    local unknown = s.ns.Targets.TTD_UNKNOWN
    s.hasTarget = true
    s:Tick(0.1)
    eq(TTD(s), unknown, "one sample")
    Fight(s, 5, 0)
    eq(TTD(s), unknown, "training dummy: health never drops")
    Fight(s, 5, -500)
    eq(TTD(s), unknown, "being healed")
end)

test("time to die resets on a new target", function()
    local s = newAddon()
    s.hasTarget = true
    s.target.health = 100000
    Fight(s, 5, 2000)
    truthy(TTD(s) < 100, "estimate for the first target")
    s.target.guid = "0xF130000002"
    s.target.health = 50000
    s:FireEvent("PLAYER_TARGET_CHANGED")
    eq(TTD(s), s.ns.Targets.TTD_UNKNOWN, "starts over")
end)

test("time to die uses only the last 15 seconds", function()
    local s = newAddon()
    s.hasTarget = true
    s.target.health = 1000000
    Fight(s, 20, 20000) -- fast at first...
    Fight(s, 16, 1000)  -- ...then slow
    local ttd = TTD(s)
    local expected = s.target.health / 1000
    truthy(math.abs(ttd - expected) < 1, ("only the slow phase counts: expected ~%d, got %.1f"):format(expected, ttd))
end)

test("Empower Rune Weapon is held for a dying target", function()
    local s, RH = newAddon()
    s:Learn("Empower Rune Weapon", "Obliterate", "Icy Touch")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    s.target.health = 100000
    for i = 1, 6 do s.runes[i].readyAt = s.time + 1000 end
    local function First()
        for i = 1, 6 do s.runes[i].readyAt = s.time + 5 end
        local st = s.ns.State:Reset()
        local action = s.ns.Recommender:Evaluate(st)
        return action and action.name
    end
    eq(First(), "empower_rune_weapon", "long fight")
    Fight(s, 5, 15000) -- dies in ~2s
    eq(First(), "icy_touch", "held: target about to die (the next rune ability instead)")
end)

---------------------------------------------------------------------------
-- Status text and snapshot
---------------------------------------------------------------------------
test("status text shows toggles and enemy count", function()
    local s, RH = newAddon()
    s.hasTarget = true
    local D = s.ns.Display
    local status = D.frame.status
    RH.db.profile.display.showStatus = true
    RH:OnConfigChanged()
    s:Tick(0.2)
    eq(D:GetStatusText(), "CD", "cooldowns on, single enemy")
    eq(D.frame.cdChip.text:GetText(), "|cff40ff40CD|r", "green")
    Hit(s, s.target.guid)
    Hit(s, "mob2")
    Hit(s, "mob3")
    s:Tick(0.2)
    eq(D:GetStatusText(), "CD  3", "auto shows the count")
    s:Slash("ACECONSOLE_RH", "cd")
    s:Slash("ACECONSOLE_RH", "aoe")
    eq(D:GetStatusText(), "CD  ST", "forced single target")
    eq(D.frame.cdChip.text:GetText(), "|cffff4040CD|r", "red: cooldowns off")
    RH.db.profile.display.showStatus = false
    RH:OnConfigChanged()
    falsy(status:IsShown(), "hidden when disabled")
end)

test("/rh snapshot shows enemies and time to die", function()
    local s = newAddon()
    s.hasTarget = true
    Hit(s, "mob2")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "snapshot")
    truthy(s:ChatContains("dies in unknown"), "ttd")
    truthy(s:ChatContains("2 active %(AoE mode auto, 1 seen in the combat log%)"), "enemies")
end)
