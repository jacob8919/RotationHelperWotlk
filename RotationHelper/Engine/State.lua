local ADDON_NAME, ns = ...
local RH = ns.RH
local Utils = ns.Utils
local pairs, ipairs, type, wipe = pairs, ipairs, type, wipe

-- A snapshot of the real game state. The recommendation engine reads from
-- here; milestone 6 adds a virtual copy that can be moved forward in time.
local State = RH:NewModule("State", "AceEvent-3.0")
ns.State = State

local GetTime, UnitExists, UnitGUID, UnitName, UnitCanAttack, UnitIsDead =
    GetTime, UnitExists, UnitGUID, UnitName, UnitCanAttack, UnitIsDead
local UnitHealth, UnitHealthMax, UnitLevel, UnitClassification, UnitCreatureType =
    UnitHealth, UnitHealthMax, UnitLevel, UnitClassification, UnitCreatureType
local UnitCastingInfo, UnitChannelInfo, GetUnitSpeed = UnitCastingInfo, UnitChannelInfo, GetUnitSpeed
local GetCVar, GetNetStats, tonumber = GetCVar, GetNetStats, tonumber
local IsUsableSpell, IsCurrentSpell, GetTotemInfo = IsUsableSpell, IsCurrentSpell, GetTotemInfo

State.real = {
    now = 0,
    runes = {},
    buffs = {},
    debuffs = {},
    cooldowns = {},
    target = {},
    variables = {}, -- APL variables, reset for every evaluation
    lastCast = {},  -- ability key -> GetTime() of our last successful cast
    readySince = {}, -- ability key -> when its cooldown last became ready
    otherDots = {},      -- dot key -> enemies other than the target with it (Engine/Dots.lua)
    otherDotsUntil = {}, -- dot key -> when those run out (math.huge: until the log says so)
    usable = {},         -- reactive ability key -> usable right now (Rune Strike)
    queued = {},         -- on-next-swing ability key -> queued right now (Heroic Strike)
    totemKey = {},       -- element ("fire", "earth", "water", "air") -> totem ability key, or false
    totemExpires = {},   -- element -> when that totem runs out
}

-- GetTotemInfo slots.
State.TOTEM_ELEMENTS = { "fire", "earth", "water", "air" }
local totemKeyByName = {} -- "Magma Totem VII" -> "magma_totem" (cached)
local NO_BOOSTS = {}

local function TotemKey(name, classData)
    local key = totemKeyByName[name]
    if key == nil then
        key = classData.abilityByName[(name:gsub("%s+[IVXL]+$", ""))] or false
        totemKeyByName[name] = key
    end
    return key
end

local function ReadTotems(s, classData)
    for slot, element in ipairs(State.TOTEM_ELEMENTS) do
        local have, name, start, duration = GetTotemInfo(slot)
        if have and name and name ~= "" and duration and duration > 0 then
            s.totemKey[element] = TotemKey(name, classData)
            s.totemExpires[element] = start + duration
        else
            s.totemKey[element], s.totemExpires[element] = false, 0
        end
    end
end

local function ReadTarget(t)
    t.exists = UnitExists("target") and true or false
    if not t.exists then
        t.guid, t.name, t.canAttack, t.dead = nil, nil, false, false
        t.health, t.healthMax, t.healthPct, t.level, t.classification = 0, 0, 0, 0, nil
        t.creatureType = nil
        return
    end
    t.guid = UnitGUID("target")
    t.name = UnitName("target")
    t.canAttack = UnitCanAttack("player", "target") and true or false
    t.dead = UnitIsDead("target") and true or false
    t.health = UnitHealth("target")
    t.healthMax = UnitHealthMax("target")
    t.healthPct = t.healthMax > 0 and (t.health / t.healthMax * 100) or 0
    t.level = UnitLevel("target") -- -1 for bosses ("??")
    t.classification = UnitClassification("target")
    -- "undead", "demon", "humanoid", ... (lowercase; enUS as on Whitemane)
    local creatureType = UnitCreatureType("target")
    t.creatureType = creatureType and creatureType:lower() or nil
end

local function ReadCast(s, now)
    local name, _, _, texture, startTime, endTime = UnitCastingInfo("player")
    local channel
    if not name then
        name, _, _, texture, startTime, endTime = UnitChannelInfo("player")
        channel = name
    end
    s.castName = name
    s.castIcon = name and texture or nil
    s.channelName = channel -- a channel, which may be cut after a tick
    s.castStart = startTime and startTime / 1000 or nil
    s.castDuration = name and startTime and endTime and (endTime - startTime) / 1000 or nil
    s.castRemains = name and endTime and (endTime / 1000 - now) or 0
    if s.castRemains < 0 then s.castRemains = 0 end
end

-- Whether target `t` (as read by ReadTarget) makes this a boss fight.
function State.IsBossFight(t)
    if t.exists and (t.level == -1 or t.classification == "worldboss" or ns.Bosses:IsKnown(t.name)) then
        return true
    end
    return UnitExists("boss1") and true or false
end

-- Reads everything from the game. Order matters: cooldowns use the rune
-- regen time and presence buffs read before them.
function State:Reset(now)
    local s = self.real
    local classData = RH.classData
    now = now or GetTime()
    s.now = now
    s.inCombat = RH.inCombat or false
    if s.inCombat and s.combatStart ~= RH.combatStart then ns.Resources.ResetIncome(now) end
    s.combatStart = RH.combatStart
    s.petAlive = (UnitExists("pet") and not UnitIsDead("pet")) and true or false
    s.moving = GetUnitSpeed and GetUnitSpeed("player") > 0 or false
    s.form = GetShapeshiftForm and GetShapeshiftForm() or 0 -- warrior stances, druid forms
    local healthMax = UnitHealthMax("player")
    s.healthPct = healthMax > 0 and UnitHealth("player") / healthMax * 100 or 100
    -- Reactive abilities: usable (after a dodge or parry) and not already
    -- queued for the next swing.
    for key, ability in pairs(classData.abilities) do
        if ability.reactive then
            local name = ability.name
            s.usable[key] = (name and IsUsableSpell(name) and not IsCurrentSpell(name)) and true or false
        end
        if ability.nextSwing then
            s.queued[key] = (ability.name and IsCurrentSpell(ability.name)) and true or false
        end
    end
    local toggles = RH.db.profile.toggles

    ns.Resources.Read(s, classData, now)
    ns.Auras.Read(s, classData)
    -- Energy regenerates at a known rate (classData.energyRegen), faster with
    -- some buffs (classData.energyBoosts: Adrenaline Rush, Overkill); combo
    -- points on the target.
    s.regenBoost, s.regenBoostUntil = nil, nil
    if s.powerType == "energy" then
        s.powerRegen = classData.energyRegen and classData.energyRegen(ns.Spec) or 10
        for _, boost in ipairs(classData.energyBoosts or NO_BOOSTS) do
            local rec = s.buffs[boost.aura]
            if rec and rec.expires > now then ns.Abilities.Effects.BoostRegen(s, boost.factor, rec.expires) end
        end
    end
    s.comboPoints = GetComboPoints and GetComboPoints("player", "target") or 0
    -- The most recent of a group of buffs (Eclipse: Lunar or Solar), kept
    -- after it runs out: s.lastAura, for last.KEY in rotations.
    local group = classData.lastAuraGroup
    if group then
        local best, bestExpires
        for _, key in ipairs(group) do
            local rec = s.buffs[key]
            if rec and rec.expires > now and (not best or rec.expires > bestExpires) then
                best, bestExpires = key, rec.expires
            end
        end
        if best then s.lastAura = best end
    end
    ns.Cooldowns.Read(s, classData, now)
    ReadTarget(s.target)
    -- Consumables (potions): toggled on, and by default only in boss fights:
    -- a boss targeted (skull level, "worldboss", or a known boss name,
    -- Engine/Bosses.lua), or boss frames up.
    s.bossFight = State.IsBossFight(s.target)
    -- Cooldowns likewise: toggled on, and by default only in boss fights.
    s.cooldownsEnabled = toggles.cooldowns and (s.bossFight or not toggles.cooldownsBossOnly) or false
    s.shortCooldownsEnabled = toggles.cooldowns and true or false -- the toggle alone, trash included
    s.consumablesAllowed = toggles.consumables and (s.bossFight or not RH.db.profile.items.consumablesBossOnly) or false
    ReadCast(s, now)

    self:ApplyLookahead(s, now)

    local t = s.target
    local Targets = ns.Targets
    -- Dual display: the main display is the single-target one (the AoE one
    -- predicts with at least 3 enemies, see Recommender:Update).
    local aoeMode = RH.db.profile.display.dualDisplay and "single" or toggles.aoeMode
    s.activeEnemies = Targets:ActiveEnemies(now, aoeMode, t.exists and t.canAttack and not t.dead)
    t.timeToDie = t.exists and Targets:TimeToDie(now) or Targets.TTD_UNKNOWN
    ns.Dots:Read(s, now)
    if classData.usesTotems then ReadTotems(s, classData) end
    if classData.autoShot then ns.AutoShot:Read(s, now) end

    local pullRemains = ns.PullTimer:Remains(now)
    s.pullAt = pullRemains and (now + pullRemains) or nil
    s.burstUntil = now + ns.Burst:Remains(now)
    -- When each cooldown came off cooldown (cooldown.X.ready_for).
    for key, cd in pairs(s.cooldowns) do
        if cd.readyAt <= now then
            s.readySince[key] = s.readySince[key] or now
        else
            s.readySince[key] = nil
        end
    end
    return s
end

---------------------------------------------------------------------------
-- Latency compensation. The 3.3.5 client queues a press made shortly
-- before the GCD (or a cast) ends: the "lag tolerance" window, set under
-- Interface > Combat > Custom Lag Tolerance (CVars reducedLagTolerance and
-- MaxSpellStartRecoveryOffset), otherwise based on latency. Ending the GCD
-- and cast that much earlier makes the next ability show (and flash) as
-- soon as pressing it gets queued. Runes and cooldowns aren't shifted: a
-- press for a rune that isn't back yet is refused, not queued.
---------------------------------------------------------------------------
local MAX_LOOKAHEAD_MS = 400

-- Returns the lookahead in seconds and where it came from.
function State:Lookahead()
    local settings = RH.db.profile.latency
    if settings.mode == "off" then return 0, "off" end
    local ms, source
    if settings.mode == "fixed" then
        ms, source = settings.fixedMs, "fixed"
    else
        if GetCVar("reducedLagTolerance") == "1" then
            ms, source = tonumber(GetCVar("MaxSpellStartRecoveryOffset")), "custom lag tolerance"
        end
        if not ms then
            local _, _, latency = GetNetStats()
            ms, source = latency, "latency"
        end
    end
    ms = math.max(0, math.min(ms or 0, MAX_LOOKAHEAD_MS))
    return ms / 1000, source
end

function State:ApplyLookahead(s, now)
    local lookahead, source = self:Lookahead()
    s.lookahead, s.lookaheadSource = lookahead, source
    -- The unshifted values, for measuring (the fight review).
    s.realGcdEnd, s.realCastRemains = s.gcdEnd, s.castRemains
    s.castEnd = now + s.castRemains
    if lookahead <= 0 then return end
    s.gcdEnd = math.max(now, s.gcdEnd - lookahead)
    s.gcdRemains = s.gcdEnd - now
    s.castRemains = math.max(0, s.castRemains - lookahead)
    s.castEnd = now + s.castRemains
end

---------------------------------------------------------------------------
-- Virtual state: a copy of the real state that the prediction can change
-- (spend runes, apply buffs, ...) without touching the snapshot.
---------------------------------------------------------------------------
State.virtual = {
    runes = {},
    buffs = {},
    debuffs = {},
    cooldowns = {},
    variables = {},
    lastCast = {},
    readySince = {},
    otherDots = {},
    otherDotsUntil = {},
    usable = {},
    queued = {},
    totemKey = {},
    totemExpires = {},
}

local function CopyAuras(dst, src)
    for key, rec in pairs(dst) do
        Utils.Release(rec)
        dst[key] = nil
    end
    for key, rec in pairs(src) do
        local copy = Utils.Acquire()
        copy.spellId, copy.stacks, copy.duration, copy.expires = rec.spellId, rec.stacks, rec.duration, rec.expires
        dst[key] = copy
    end
end

local function CopyMap(dst, src)
    for key in pairs(dst) do
        if src[key] == nil then dst[key] = nil end
    end
    for key, value in pairs(src) do dst[key] = value end
end

-- Copies `src` into `dst`, reusing dst's tables. The target is shared,
-- since nothing the prediction does changes it.
function State.CopyInto(dst, src)
    for key, value in pairs(dst) do
        if type(value) ~= "table" and src[key] == nil then dst[key] = nil end
    end
    for key, value in pairs(src) do
        if type(value) ~= "table" then dst[key] = value end
    end

    for i, rune in ipairs(src.runes) do
        local copy = dst.runes[i] or {}
        dst.runes[i] = copy
        copy.type, copy.base, copy.readyAt = rune.type, rune.base, rune.readyAt
    end

    CopyAuras(dst.buffs, src.buffs)
    CopyAuras(dst.debuffs, src.debuffs)

    for key, cd in pairs(src.cooldowns) do
        local copy = dst.cooldowns[key] or {}
        dst.cooldowns[key] = copy
        copy.readyAt, copy.duration = cd.readyAt, cd.duration
    end

    CopyMap(dst.lastCast, src.lastCast)
    CopyMap(dst.readySince, src.readySince)
    CopyMap(dst.otherDots, src.otherDots)
    CopyMap(dst.otherDotsUntil, src.otherDotsUntil)
    CopyMap(dst.usable, src.usable)
    CopyMap(dst.queued, src.queued)
    CopyMap(dst.totemKey, src.totemKey)
    CopyMap(dst.totemExpires, src.totemExpires)
    wipe(dst.variables)
    dst.target = src.target
    return dst
end

State.CopyAuras = CopyAuras

-- A new, empty state with the tables CopyInto fills (for scratch copies).
function State.NewCopy()
    return { runes = {}, buffs = {}, debuffs = {}, cooldowns = {}, variables = {}, lastCast = {}, readySince = {},
        otherDots = {}, otherDotsUntil = {}, usable = {}, queued = {}, totemKey = {}, totemExpires = {} }
end

-- Returns the virtual state, freshly copied from the real one.
function State:Virtual()
    return State.CopyInto(self.virtual, self.real)
end

---------------------------------------------------------------------------
-- Events that change the state trigger a prompt refresh.
---------------------------------------------------------------------------
function State:OnUnitEvent(_, unit)
    if unit == "player" or unit == "target" then
        RH:Invalidate()
    end
end

-- 3.3.5 passes (unit, spellName, spellRank, ...) with no spell ID.
function State:OnSpellcastSucceeded(_, unit, spellName)
    if unit ~= "player" then return end
    local key = RH.classData.abilityByName[spellName]
    if key then self.real.lastCast[key] = GetTime() end
    RH:Invalidate()
end

function State:OnEnable()
    if not RH.classSupported then return end
    local invalidate = function() RH:Invalidate() end
    self:RegisterEvent("UNIT_AURA", "OnUnitEvent")
    self:RegisterEvent("UNIT_RUNIC_POWER", "OnUnitEvent")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "OnSpellcastSucceeded")
    self:RegisterEvent("RUNE_POWER_UPDATE", invalidate)
    self:RegisterEvent("RUNE_TYPE_UPDATE", invalidate)
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN", invalidate)
end
