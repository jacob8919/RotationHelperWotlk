local ADDON_NAME, ns = ...

-- Reads the GCD and ability cooldowns.
--
-- state.gcdRemains, state.gcdDuration
-- state.cooldowns[key] = { readyAt = time, duration = seconds }
--   for every ability in the class data with a cooldown.
local Cooldowns = {}
ns.Cooldowns = Cooldowns

local GetSpellCooldown, GetInventoryItemCooldown, GetItemCooldown =
    GetSpellCooldown, GetInventoryItemCooldown, GetItemCooldown
local abs, pairs = math.abs, pairs

local BASE_GCD = 1.5
local MAX_GCD = 1.5

-- On 3.3.5, GetSpellCooldown on a rune ability reports the rune recharge
-- when its runes are down. That isn't the ability's own cooldown, so ignore
-- cooldowns matching the current rune regen time on rune abilities.
local function IsRuneCooldown(ability, duration, state)
    return ability.runes ~= nil and state.runeRegen ~= nil and abs(duration - state.runeRegen) < 0.05
end

-- Spell haste as a factor on cast times (1 = none, 0.8 = 25% haste), from
-- the hasted cast time the client reports for classData.hasteProbe (an
-- ability with a fixed `castTime`, e.g. Mind Blast).
local GetSpellInfo = GetSpellInfo
local function HasteFactor(classData)
    local probe = classData.hasteProbe and classData.abilities[classData.hasteProbe]
    if not (probe and probe.name and probe.castTime) then return 1 end
    local _, _, _, _, _, _, castMs = GetSpellInfo(probe.name)
    if not castMs or castMs <= 0 then return 1 end
    return castMs / 1000 / probe.castTime
end

function Cooldowns.Read(state, classData, now)
    state.hasteFactor = HasteFactor(classData)
    local start, duration = GetSpellCooldown(classData.gcdSpellName)
    if start and start > 0 and duration and duration > 0 and duration <= MAX_GCD then
        state.gcdRemains = start + duration - now
        state.gcdDuration = duration
    else
        state.gcdRemains = 0
        -- Casters' GCD is shortened by spell haste, down to 1 second.
        -- baseGcd: 1 second for Rogues, per spec ({ feral_combat = 1 }), or a
        -- function of the state (Druids: 1 second in Cat Form, 1.5 in Bear Form).
        local baseGcd = classData.baseGcd
        if type(baseGcd) == "function" then
            baseGcd = baseGcd(state, ns.Spec)
        elseif type(baseGcd) == "table" then
            baseGcd = baseGcd[ns.Spec.key]
        end
        state.gcdDuration = state.buffs.unholy_presence and 1.0 or baseGcd
            or (classData.hasteProbe and math.max(1.0, BASE_GCD * state.hasteFactor)) or BASE_GCD
    end
    if state.gcdRemains < 0 then state.gcdRemains = 0 end
    state.gcdEnd = now + state.gcdRemains

    local list = state.cooldowns
    for key, ability in pairs(classData.abilities) do
        if ability.cooldown and ability.cooldown > 0 then
            local rec = list[key]
            if not rec then
                rec = {}
                list[key] = rec
            end
            local s, d, enabled
            if ability.itemSlot then
                s, d, enabled = GetInventoryItemCooldown("player", ability.itemSlot)
            elseif ability.potionItems then
                if ability.itemID then s, d, enabled = GetItemCooldown(ability.itemID) end
            elseif ability.name then
                s, d = GetSpellCooldown(ability.name)
            end
            if enabled == 0 then
                -- A used potion stays locked until combat ends.
                rec.readyAt = math.huge
                rec.duration = ability.cooldown
            elseif s and s > 0 and d and d > MAX_GCD and not IsRuneCooldown(ability, d, state) then
                rec.readyAt = s + d
                rec.duration = d
            else
                rec.readyAt = now
                rec.duration = ns.Abilities.CooldownDuration(ability)
            end
        end
    end
end

function Cooldowns.Remains(rec, now)
    if not rec then return 0 end
    local r = rec.readyAt - now
    return r > 0 and r or 0
end
