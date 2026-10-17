local ADDON_NAME, ns = ...

-- Works out when an ability can next be used, given a state snapshot.
--
-- Abilities.ReadyAt(state, key) returns the absolute time the ability is
-- usable, or nil plus a reason if it can't be used at all with the current
-- resources. The time accounts for:
--   - the GCD (off-GCD abilities ignore it) and any cast in progress
--   - the ability's cooldown
--   - rune costs; death runes can pay for any rune type
--   - runic power or mana (neither is predicted to come back, so too little
--     means "never")
local Abilities = {}
ns.Abilities = Abilities

local RH = ns.RH
local Utils = ns.Utils
local ipairs, pairs, sort, min, max = ipairs, pairs, table.sort, math.min, math.max

local NUM_RUNES = 6
local function PowerAt(state, t) return ns.Resources.PowerAt(state, t) end

-- Scratch tables, reused to avoid garbage on every evaluation.
local readyCount = { blood = 0, unholy = 0, frost = 0, death = 0 }
local candidateTimes = {}

local function RunesSatisfied(state, cost, at)
    readyCount.blood, readyCount.unholy, readyCount.frost, readyCount.death = 0, 0, 0, 0
    for i = 1, NUM_RUNES do
        local rune = state.runes[i]
        if rune.readyAt <= at and readyCount[rune.type] then
            readyCount[rune.type] = readyCount[rune.type] + 1
        end
    end
    local missing = 0
    for runeType, needed in pairs(cost) do
        local have = readyCount[runeType]
        if have < needed then missing = missing + needed - have end
    end
    return missing <= readyCount.death
end

-- Earliest time >= `from` when the rune cost can be paid, or nil if the
-- runes that exist can never pay it.
function Abilities.RunesReadyAt(state, cost, from)
    local n = 1
    candidateTimes[1] = from
    for i = 1, NUM_RUNES do
        local readyAt = state.runes[i].readyAt
        if readyAt > from then
            n = n + 1
            candidateTimes[n] = readyAt
        end
    end
    for i = n + 1, #candidateTimes do candidateTimes[i] = nil end
    sort(candidateTimes)
    for i = 1, n do
        if RunesSatisfied(state, cost, candidateTimes[i]) then return candidateTimes[i] end
    end
    return nil
end

-- What an ability costs in the class's power: runic power (`rp`, `rpCost`)
-- or mana (`mana`, a percentage of base mana as in the tooltips; the real
-- cost read from the client, `manaCost`, when there is one).
-- `state` is optional: `manaFn(spec, state)` gives costs that depend on it
-- (Arcane Blast: more per stack).
local function BaseCost(ability, state)
    if ability.manaFn and state then return ability.manaFn(ns.Spec, state, RH.classData.baseMana or 0) end
    if ability.rpCost then return ability.rpCost(ns.Spec) end
    if ability.rageCost then return ability.rageCost(ns.Spec) end
    if ability.rage then return ability.rage end
    if ability.energyCost then return ability.energyCost(ns.Spec) end
    if ability.energy then return ability.energy end
    if ability.mana then
        return ability.manaCost or (ability.mana / 100 * (RH.classData.baseMana or 0))
    end
    return ability.rp and ability.rp > 0 and ability.rp or 0
end

local function AuraUp(state, key)
    local rec = key and state.buffs[key]
    return rec ~= nil and rec.expires > state.now
end

-- With a state, class-wide cost changes apply: a buff that makes the next
-- ability free (classData.freeCostAura, Clearcasting) and one that scales
-- costs (classData.costBuff = { aura, factor }, Berserk: half).
function Abilities.PowerCost(ability, state)
    local cost = BaseCost(ability, state)
    if not state or cost <= 0 then return cost end
    local classData = RH.classData
    if AuraUp(state, classData.freeCostAura) then return 0 end
    local costBuff = classData.costBuff
    if costBuff and AuraUp(state, costBuff.aura) then cost = cost * costBuff.factor end
    return cost
end

-- Power an ability generates (runic power).
function Abilities.PowerGain(ability)
    local gain = ability.rp and ability.rp < 0 and -ability.rp or 0
    if ability.rpGain then gain = gain + ability.rpGain(ns.Spec) end
    if ability.rageGain then gain = gain + ability.rageGain(ns.Spec) end
    if ability.energyGain then gain = gain + ability.energyGain(ns.Spec) end
    return gain
end

-- The Death Knight names, still used in places.
Abilities.RunicPowerCost = Abilities.PowerCost
Abilities.RunicPowerGain = Abilities.PowerGain

-- How long using an ability keeps you busy casting or channelling (0 for
-- instants): `castTime` or `channel`, in base seconds, shortened by spell
-- haste (state.hasteFactor, see Engine/Cooldowns.lua).
-- `castTimeFn(spec, state)` gives the base cast time when talents or buffs
-- change it (Missile Barrage: Arcane Missiles twice as fast), and
-- `instantWith` names a buff that makes it instant (Hot Streak: Pyroblast).
function Abilities.CastTime(state, ability)
    local base = ability.castTime or ability.channel
    if not base then return 0 end
    if ability.instantWith then
        local rec = state.buffs[ability.instantWith]
        if rec and rec.expires > state.now then return 0 end
    end
    if ability.castTimeFn then base = ability.castTimeFn(ns.Spec, state) end
    return base * (state.hasteFactor or 1)
end

-- The global cooldown an ability triggers: 0 off the GCD, else the (hasted)
-- GCD, shortened by gcdFn (Backdraft), never below 1 second.
local MIN_GCD = 1
function Abilities.Gcd(state, ability)
    if ability.offGcd then return 0 end
    local gcd = state.gcdDuration
    if ability.gcdFn then gcd = math.max(MIN_GCD, math.min(gcd, ability.gcdFn(ns.Spec, state, gcd))) end
    return gcd
end

-- The cooldown after using an ability, with talents and glyphs (cooldownFn).
function Abilities.CooldownDuration(ability)
    if ability.cooldownFn then return ability.cooldownFn(ns.Spec) end
    return ability.cooldown
end

local function BuffUpAt(state, key, at)
    local rec = state.buffs[key]
    return rec ~= nil and rec.expires > at
end

-- Returns readyAt, limitedBy ("gcd", "cooldown", "runes"), or nil, reason.
function Abilities.ReadyAt(state, key)
    local ability = RH.classData.abilities[key]
    if not ability then return nil, "unknown ability" end
    if not ns.Spec.known[key] then return nil, "not in spellbook" end
    if ability.requiresPet and not state.petAlive then return nil, "no pet" end
    if ability.consumable and state.consumablesAllowed == false then return nil, "consumables off" end
    -- Reactive abilities (Rune Strike after a dodge or parry) only while the game allows them.
    -- Stance or form (Overpower: Battle Stance; Pummel: Berserker Stance).
    if ability.requiresForm and state.form ~= ability.requiresForm then return nil, "wrong stance" end
    -- Reactive abilities (Rune Strike, Overpower) only while the game allows
    -- them, or while a buff that allows them is up (Taste for Blood).
    if ability.reactive and not (state.usable and state.usable[key])
        and not (ability.usableWith and BuffUpAt(state, ability.usableWith, state.now)) then
        return nil, "not usable"
    end
    -- Finishers need combo points.
    if ability.finisher and (state.comboPoints or 0) < 1 then return nil, "combo points" end
    -- On-next-swing attacks (Heroic Strike, Cleave): not again while one is queued.
    if ability.nextSwing and state.queued and state.queued[key] then return nil, "queued" end

    local t, limitedBy = state.now, nil
    local castEnd = state.castEnd or (state.now + (state.castRemains or 0))
    if castEnd > t then t, limitedBy = castEnd, "cast" end
    -- Casts and channels can't be started while moving.
    local cast = Abilities.CastTime(state, ability)
    if state.moving and cast > 0 then return nil, "moving" end
    if not ability.offGcd and state.gcdEnd > t then t, limitedBy = state.gcdEnd, "gcd" end

    -- A buff can let an ability skip its cooldown (Lock and Load: Explosive Shot).
    local cd = state.cooldowns[key]
    local skipsCooldown = ability.ignoreCooldownWith and BuffUpAt(state, ability.ignoreCooldownWith, t)
    if cd and cd.readyAt > t and not skipsCooldown then t, limitedBy = cd.readyAt, "cooldown" end
    -- A buff that forbids it (Tiger's Fury during Berserk): usable once it ends.
    if ability.blockedBy then
        local rec = state.buffs[ability.blockedBy]
        if rec and rec.expires > t then t, limitedBy = rec.expires, ability.blockedBy end
    end

    local cost = Abilities.PowerCost(ability, state)
    if cost > 0 and PowerAt(state, t) < cost then
        -- Rage and energy keep coming in: wait for them. Other power doesn't.
        local at = ns.Resources.TimeFor(state, cost)
        if at then
            t, limitedBy = at, state.powerType
        else
            return nil, state.powerType == "runic_power" and "runic power" or state.powerType
        end
    end

    if ability.runes and not (ability.freeWith and BuffUpAt(state, ability.freeWith, t)) then
        local runesAt = Abilities.RunesReadyAt(state, ability.runes, t)
        if not runesAt then return nil, "runes" end
        if runesAt > t then t, limitedBy = runesAt, "runes" end
    end
    -- A cast that would still be going when the next Auto Shot is due delays
    -- it (Steady Shot). Wait for the Auto Shot instead, when waiting costs
    -- less time than the delay would.
    if ability.avoidAutoClip and cast > 0 and state.autoShotNext then
        local shot = ns.AutoShot.NextAt(state, t)
        if shot and shot > t and shot < t + cast and (shot - t) < (t + cast - shot) then
            t, limitedBy = shot, "auto shot"
        end
    end
    return t, limitedBy
end

-- If using `key` at time `t` spends one of the class's notable procs
-- (classData.procs, e.g. Killing Machine), returns that aura key and when
-- it expires.
function Abilities.ProcUsed(state, key, t)
    local procs = RH.classData.procs
    if not procs then return nil end
    for _, proc in ipairs(procs) do
        local expires = Abilities.SpendsProc(state, key, proc, t)
        if expires then return proc, expires end
    end
    return nil
end

-- If using `key` at time `t` spends aura `proc` (it's up and the ability
-- consumes it or is free with it), returns when the proc expires.
-- An ability can spend several at once (Howling Blast: Rime and Killing Machine).
function Abilities.SpendsProc(state, key, proc, t)
    local rec = state.buffs[proc]
    if not (rec and rec.expires > t) then return nil end
    local ability = RH.classData.abilities[key]
    if ability.freeWith == proc or ability.instantWith == proc or ability.ignoreCooldownWith == proc
        or ability.usesStack == proc then
        return rec.expires
    end
    -- Clearcasting (classData.freeCostAura): any ability that costs something uses it.
    if proc == RH.classData.freeCostAura and BaseCost(ability, state) > 0 then return rec.expires end
    if ability.consumes then
        for _, consumed in ipairs(ability.consumes) do
            if consumed == proc then return rec.expires end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Simulation: what using an ability does to a (virtual) state.
---------------------------------------------------------------------------
-- Helpers for class handlers: ability.apply(state, spec, Effects).
-- Durations count from state.now.
local Effects = {}
Abilities.Effects = Effects

local function SetAura(list, key, now, duration, stacks)
    local rec = list[key]
    if not rec then
        rec = Utils.Acquire()
        list[key] = rec
    end
    rec.duration = duration
    rec.stacks = stacks or 1
    rec.expires = duration and (now + duration) or math.huge
end

function Effects.ApplyBuff(s, key, duration, stacks)
    SetAura(s.buffs, key, s.now, duration, stacks)
end

function Effects.ApplyDebuff(s, key, duration, stacks)
    SetAura(s.debuffs, key, s.now, duration, stacks)
end

function Effects.RemoveBuff(s, key)
    local rec = s.buffs[key]
    if rec then
        Utils.Release(rec)
        s.buffs[key] = nil
    end
end

-- Pestilence: every other enemy gets the target's spreadable dots (the
-- class's spreadDots) for `duration` seconds.
function Effects.SpreadDots(s, duration)
    local keys = RH.classData.spreadDots
    local others = (s.activeEnemies or 1) - 1
    if not keys or others <= 0 or not s.otherDots then return end
    local all = true
    for _, key in ipairs(keys) do
        if Effects.DebuffUp(s, key) then
            s.otherDots[key] = others
            s.otherDotsUntil[key] = s.now + duration
        else
            all = false
        end
    end
    if all then
        s.otherDiseased = others
        s.otherDiseasedUntil = s.now + duration
    end
end

-- Power regeneration `factor` times faster until `until` (Adrenaline Rush,
-- Overkill). Only one boosted window is modelled: overlapping boosts multiply
-- until the first one ends (a little less than the truth after that).
function Effects.BoostRegen(s, factor, untilTime)
    if s.regenBoostUntil and s.regenBoostUntil > s.now then
        s.regenBoost = (s.regenBoost or 1) * factor
        if untilTime < s.regenBoostUntil then s.regenBoostUntil = untilTime end
    else
        s.regenBoost, s.regenBoostUntil = factor, untilTime
    end
end

-- Uses one stack of a buff with charges (Backdraft); the last one removes it.
function Effects.ConsumeStack(s, key)
    local rec = s.buffs[key]
    if not (rec and rec.expires > s.now) then return end
    if rec.stacks > 1 then
        rec.stacks = rec.stacks - 1
    else
        Effects.RemoveBuff(s, key)
    end
end

-- Whether a buff with charges is up at the moment being checked.
function Effects.BuffUp(s, key)
    local rec = s.buffs[key]
    return rec ~= nil and rec.expires > s.now
end

function Effects.SummonPet(s)
    s.petAlive = true
end

function Effects.DebuffUp(s, key)
    local rec = s.debuffs[key]
    return rec ~= nil and rec.expires > s.now
end

-- Empower Rune Weapon: every rune is ready immediately.
function Effects.ActivateAllRunes(s)
    for i = 1, NUM_RUNES do
        if s.runes[i].readyAt > s.now then s.runes[i].readyAt = s.now end
    end
end

-- Blood Tap: a blood rune becomes a ready death rune. Prefers one that's
-- recharging, so a ready blood rune isn't wasted.
function Effects.BloodTap(s)
    local pick
    for i = 1, NUM_RUNES do
        local rune = s.runes[i]
        if rune.base == "blood" and rune.type == "blood" then
            if not pick or rune.readyAt > s.runes[pick].readyAt then pick = i end
        end
    end
    if pick then
        s.runes[pick].type = "death"
        s.runes[pick].readyAt = min(s.runes[pick].readyAt, s.now)
    end
end

-- Whether spending a rune of base `base` turns it into a death rune, e.g.
-- Blood of the North for Blood Strike. ability.convert = { runes = { blood = true },
-- talents = { "blood_of_the_north" } }: any listed talent at rank 3.
local function Converts(ability, base)
    local convert = ability.convert
    if not (convert and convert.runes[base]) then return false end
    for _, talent in ipairs(convert.talents) do
        if ns.Spec:TalentRank(talent) >= 3 then return true end
    end
    return false
end

local function SpendRune(s, i, ability)
    local rune = s.runes[i]
    rune.readyAt = s.now + s.runeRegen
    -- A spent death rune goes back to its slot's type, unless converted again.
    rune.type = Converts(ability, rune.base) and "death" or rune.base
end

-- Deterministic order: every type takes its own runes before death runes.
local RUNE_ORDER = { "blood", "unholy", "frost" }

local function FindReadyRune(s, runeType)
    for i = 1, NUM_RUNES do
        local rune = s.runes[i]
        if rune.type == runeType and rune.readyAt <= s.now then return i end
    end
end

local function SpendRunes(s, ability)
    for _, runeType in ipairs(RUNE_ORDER) do
        for _ = 1, ability.runes[runeType] or 0 do
            local i = FindReadyRune(s, runeType) or FindReadyRune(s, "death")
            if i then SpendRune(s, i, ability) end
        end
    end
end

-- Moves `s` to time `t` and applies using ability `key` there: GCD,
-- cooldown, runes, runic power, consumed procs, and the ability's own
-- effects (ability.apply). Procs that might happen (Killing Machine,
-- Rime) are random and not predicted.
function Abilities.Apply(s, key, t)
    local ability = RH.classData.abilities[key]
    s.now = t
    -- A cast or channel keeps you busy until it ends; its effects land then.
    local cast = Abilities.CastTime(s, ability)
    local landsAt = t + cast
    s.castRemains, s.castEnd = cast, landsAt
    -- An Auto Shot due during the cast fires when it ends instead.
    if cast > 0 and s.autoShotNext then
        local shot = ns.AutoShot.NextAt(s, t)
        if shot and shot > t and shot < landsAt then s.autoShotNext = landsAt end
    end
    if not ability.offGcd then s.gcdEnd = t + Abilities.Gcd(s, ability) end
    if ability.reactive and s.usable then s.usable[key] = false end -- queued / used up
    if ability.nextSwing and s.queued then s.queued[key] = true end

    local cd = s.cooldowns[key]
    -- Used with a buff that skips the cooldown: no cooldown, one charge used.
    local skipped = ability.ignoreCooldownWith and BuffUpAt(s, ability.ignoreCooldownWith, t)
    if skipped then
        Effects.ConsumeStack(s, ability.ignoreCooldownWith)
        cd = nil
    end
    if cd then
        -- A potion can't be used again in the same combat.
        cd.readyAt = ability.oncePerCombat and math.huge or landsAt + (cd.duration or ability.cooldown)
        if s.readySince then s.readySince[key] = nil end
        -- A shared cooldown (the Shaman shocks) starts for the whole group.
        local group = ability.cooldownGroup
        if group then
            for other, def in pairs(RH.classData.abilities) do
                local ocd = def.cooldownGroup == group and other ~= key and s.cooldowns[other]
                if ocd and ocd.readyAt < cd.readyAt then ocd.readyAt = cd.readyAt end
            end
        end
    end
    -- Totems: the element's totem is replaced (s.totemKey / s.totemExpires).
    if ability.totem and s.totemKey then
        s.totemKey[ability.totem] = key
        s.totemExpires[ability.totem] = t + ability.totemDuration
    end

    local free = ability.freeWith and BuffUpAt(s, ability.freeWith, t)
    if ability.runes and not free then SpendRunes(s, ability) end
    if free then Effects.RemoveBuff(s, ability.freeWith) end

    local cost = Abilities.PowerCost(ability, s)
    -- Clearcasting is used up by an ability that would have cost something.
    local freeAura = RH.classData.freeCostAura
    if freeAura and cost == 0 and BaseCost(ability, s) > 0 and AuraUp(s, freeAura) then
        Effects.RemoveBuff(s, freeAura)
    end
    s.power = max(0, min(s.powerMax, PowerAt(s, t) - cost + Abilities.PowerGain(ability)))
    s.powerTime = t
    -- Combo points: builders add them, finishers use them all (their effects
    -- can read how many: s.comboPointsSpent).
    if ability.finisher then
        s.comboPointsSpent, s.comboPoints = s.comboPoints or 0, 0
    elseif ability.comboGain then
        s.comboPoints = min(5, (s.comboPoints or 0) + ability.comboGain)
    end

    if ability.consumes then
        for _, aura in ipairs(ability.consumes) do Effects.RemoveBuff(s, aura) end
    end
    if ability.instantWith then Effects.RemoveBuff(s, ability.instantWith) end
    -- One charge of a buff with charges (Fingers of Frost).
    if ability.usesStack then Effects.ConsumeStack(s, ability.usesStack) end
    s.now = landsAt
    if ability.apply then ability.apply(s, ns.Spec, Effects) end
    s.now = t
    s.lastCast[key] = t
end
