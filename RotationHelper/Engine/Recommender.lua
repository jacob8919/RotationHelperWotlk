local ADDON_NAME, ns = ...
local RH = ns.RH

-- Produces RH.recommendations on every update: takes a state snapshot,
-- runs the APL for the current spec and hands the result to the display.
local Recommender = RH:NewModule("Recommender", "AceEvent-3.0")
ns.Recommender = Recommender

local Compiler, Runner = ns.APL.Compiler, ns.APL.Runner
local State, Abilities = ns.State, ns.Abilities

local wipe, ipairs, IsSpellInRange = wipe, ipairs, IsSpellInRange

local context = {
    ReadyAt = function(s, key) return Abilities.ReadyAt(s, key) end,
    LastUsed = function(s, key) return s.lastCast[key] end,
}

-- For the out-of-range alternative: the same, but abilities that are out
-- of range of the target are unusable. Abilities without a range (Horn of
-- Winter, self buffs) report nil and count as in range.
local function InRange(key)
    local name = RH.classData.abilities[key].name
    return not (name and IsSpellInRange(name, "target") == 0)
end

local rangedContext = {
    ReadyAt = function(s, key)
        if not InRange(key) then return nil, "out of range" end
        return Abilities.ReadyAt(s, key)
    end,
    LastUsed = context.LastUsed,
}

local alternativeEntry = {}

-- What the display needs to show an ability: a spell ID, or for item
-- abilities (trinkets, potions) the item ID, name and icon.
local function SetAbility(entry, ability)
    entry.spellId = ability.id
    entry.itemID = ability.itemID
    entry.itemName = ability.itemID and ability.name or nil
    entry.icon = ability.icon
end

Recommender.context = context -- for the simulator

local MAX_PREDICTIONS = 5
Recommender.predictedRunes = {} -- [slot] = { type, readyAt } after the predicted actions

-- Reused so updates don't create garbage. The AoE set is for the dual
-- display's second display, the cooldown set for the separate cooldowns
-- display.
local function NewPool()
    local pool = {}
    for i = 1, MAX_PREDICTIONS do pool[i] = {} end
    return pool
end
local recommendations, entries = {}, NewPool()
local aoeRecommendations, aoeEntries = {}, NewPool()
local cdRecommendations, cdEntries = {}, NewPool()

function Recommender:OnEnable()
    self.compiled = {} -- spec key -> compiled APL, or false if there is none
    if not RH.classSupported then return end
    self.resolver = ns.Expressions.CreateResolver(RH.classData)
    -- After an error, clear the icons: stale advice is worse than none.
    RH:RegisterUpdater(function(_, now) Recommender:Update(now) end, RH.UPDATE_ORDER.RECOMMEND,
        "recommendations", function()
            RH.recommendations, RH.alternative, RH.aoeRecommendations, RH.cooldownRecommendation = nil, nil, nil, nil
        end)
    -- A profile switch can change the custom rotations.
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", "Reset")
    -- A spell that just landed (see ApplyLanded).
    self.playerGUID = UnitGUID("player")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "OnSpellcastSucceeded")
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "OnCombatLog")
end

-- Forgets compiled APLs, e.g. after a custom rotation was saved.
function Recommender:Reset()
    wipe(self.compiled)
    RH:Invalidate()
end

-- The rotation for a spec: the profile's custom text if there is one, else
-- the default. Returns source ({ name, text, custom }) and the default (or nil).
function Recommender:GetSource(specKey)
    local defaults = ns.APLs[RH.playerClass]
    local default = defaults and defaults[specKey]
    local customs = RH.db.profile.customAPLs[RH.playerClass]
    local text = customs and customs[specKey]
    if text then
        local treeName = ns.Spec.trees[specKey] or specKey
        return { name = treeName .. " (custom)", text = text, custom = true }, default
    end
    return default, default
end

-- Compiles `text` for a spec (default: the current one), whose rotation
-- settings it can read as option.KEY.
function Recommender:Compile(text, specKey)
    local abilities, resolver = RH.classData.abilities, self.resolver
    specKey = specKey or ns.Spec.key
    return Compiler.CompileAPL(text, {
        resolve = function(name)
            if name:find("^option%.") then return ns.APLOptions.Getter(specKey, name) end
            return resolver(name)
        end,
        isAction = function(name) return abilities[name] ~= nil end,
    })
end

local function PrintErrors(apl)
    for _, err in ipairs(apl.errors) do
        print("  " .. Compiler.FormatError(err))
    end
end

-- Compiles (once per spec) and returns the APL for the current spec.
function Recommender:GetAPL()
    local specKey = ns.Spec.key
    if not specKey then return nil end
    local cached = self.compiled[specKey]
    if cached ~= nil then return cached or nil end

    local source, default = self:GetSource(specKey)
    if not source then
        self.compiled[specKey] = false
        return nil
    end

    local apl = self:Compile(source.text, specKey)
    apl.name, apl.custom = source.name, source.custom
    if #apl.errors > 0 then
        if source.custom and default then
            -- Saved rotations are checked when saved, so this means something
            -- changed since (e.g. an addon update). Don't run half a rotation.
            RH:Print(("Your custom rotation '%s' has %d problem(s); using the default until it's fixed (/rh apl):")
                :format(apl.name, #apl.errors))
            PrintErrors(apl)
            apl = self:Compile(default.text, specKey)
            apl.name = default.name
        else
            RH:Print(("%d problem(s) in action list '%s' (those lines are skipped):"):format(#apl.errors, apl.name))
            PrintErrors(apl)
        end
    end
    self.compiled[specKey] = apl
    return apl
end

-- Runs the APL against state `s`. Out of combat the precombat list goes
-- first; the main list needs a living hostile target.
-- Returns action, readyAt, limitedBy (or nil).
-- `ctx` defaults to the normal context and `apl` to the current spec's.
function Recommender:Evaluate(s, trace, ctx, apl)
    apl = apl or self:GetAPL()
    if not apl then return nil end
    ctx = ctx or context

    local action, readyAt, limitedBy
    if not s.inCombat and apl.lists.precombat then
        action, readyAt, limitedBy = Runner.Run(apl, s, ctx, "precombat", trace)
    end
    local t = s.target
    if not action and t.exists and t.canAttack and not t.dead then
        action, readyAt, limitedBy = Runner.Run(apl, s, ctx, "default", trace)
    end
    return action, readyAt, limitedBy
end

-- When the main recommendation is out of range of the target: the best
-- thing that is in range (Icy Touch, Howling Blast, Death Coil, ...), or nil.
function Recommender:Alternative(recs, n)
    if n == 0 or not RH.db.profile.display.alternative then return nil end
    local s = State.real
    local t = s.target
    if not (t.exists and t.canAttack and not t.dead) or InRange(recs[1].name) then return nil end
    local action, readyAt, limitedBy = self:Evaluate(s, nil, rangedContext)
    if not action or action.name == recs[1].name then return nil end
    local e = alternativeEntry
    e.name = action.name
    SetAbility(e, RH.classData.abilities[action.name])
    e.wait = readyAt - s.now
    e.lacksResources = limitedBy == "runes"
    e.action, e.limitedBy = action, limitedBy
    return e
end

-- Whether `proc` is *why* this line was picked, not just spent by it: the
-- line's condition would be false without it (e.g. frost_strike,if=
-- buff.killing_machine.up), or the ability is only affordable thanks to it
-- (Rime's free Howling Blast). Checked by hiding the proc for a moment.
-- Returns the proc key or nil.
local function ProcIsReason(v, action, proc, readyAt)
    local rec = v.buffs[proc]
    local expires, now = rec.expires, v.now
    rec.expires = 0
    v.now = readyAt
    local reason = action.condition ~= nil and action.condition(v) == 0
    if not reason and RH.classData.abilities[action.name].freeWith == proc then
        local t = Abilities.ReadyAt(v, action.name)
        reason = not t or t > readyAt + 0.01
    end
    rec.expires, v.now = expires, now
    return reason and proc or nil
end

-- Channels with `ticks` (Mind Flay, Drain Soul, Hurricane) can be cut
-- short after any tick. For a channel of ability `key` running from
-- `startedAt` to s.castEnd: at each tick still to come, would the rotation
-- (with the channel ending there) pick something else, usable right then?
-- That means a line above the channel wants to go (a ready Mind Blast, a
-- DoT to refresh), since a tie goes to the higher line and the channel
-- itself could simply go on. The channel then ends at that tick
-- (s.castEnd / s.castRemains); otherwise it runs to the end.
local CLIP_EPSILON = 0.01

function Recommender:ClipChannel(s, key, startedAt, ctx, apl)
    local ability = RH.classData.abilities[key]
    local ticks = ability and ability.ticks
    if not ticks then return end
    local fullEnd, fullRemains = s.castEnd, s.castRemains
    local interval = (fullEnd - startedAt) / ticks
    if interval <= 0 then return end
    local base = s.now
    for k = 1, ticks - 1 do
        local tick = startedAt + k * interval
        if tick > base + CLIP_EPSILON then
            s.castEnd, s.castRemains = tick, tick - base
            local action, readyAt = self:Evaluate(s, nil, ctx, apl)
            if action and action.name ~= key and readyAt <= tick + CLIP_EPSILON then return end
        end
    end
    s.castEnd, s.castRemains = fullEnd, fullRemains
end

-- The ability being channelled for real, if it has ticks: its key, or nil.
local channelKeys = {} -- spell name -> ability key
local function ChannelKey(name)
    if not name then return nil end
    local key = channelKeys[name]
    if key == nil then
        key = false
        for k, ability in pairs(RH.classData.abilities) do
            if ability.ticks and ability.name == name then key = k end
        end
        channelKeys[name] = key
    end
    return key or nil
end

-- The ability being cast for real (not channelled): its key, or nil.
local castKeys = {} -- spell name -> ability key
local function CastKey(name)
    if not name then return nil end
    local key = castKeys[name]
    if key == nil then
        key = false
        for k, ability in pairs(RH.classData.abilities) do
            if ability.name == name and (ability.castTime or ability.castTimeFn) and not ability.channel then key = k end
        end
        castKeys[name] = key
    end
    return key or nil
end

-- A cast in progress hasn't done anything yet: the game starts its
-- cooldown, spends its cost and puts its DoT up when it lands. So the
-- prediction uses it up front, landing when the real cast ends; otherwise
-- the Lava Burst being cast would be suggested again right after it, or the
-- Immolate being cast before its DoT is up. The GCD, the cast's end and the
-- power reading stay as read.
function Recommender:ApplyCurrentCast(v)
    local key = not v.channelName and CastKey(v.castName)
    if not key or v.castRemains <= 0 then return end
    local now, gcdEnd, castEnd, castRemains, powerTime = v.now, v.gcdEnd, v.castEnd, v.castRemains, v.powerTime
    local ability = RH.classData.abilities[key]
    -- Started so that it lands when the real cast ends.
    local start = math.min(now, castEnd - Abilities.CastTime(v, ability))
    Abilities.Apply(v, key, start)
    v.now, v.gcdEnd, v.castEnd, v.castRemains, v.powerTime = now, gcdEnd, castEnd, castRemains, powerTime
    -- Its cooldown runs from when it lands.
    local cd = v.cooldowns[key]
    if cd and cd.readyAt < math.huge then
        cd.readyAt = castEnd + (cd.duration or Abilities.CooldownDuration(ability) or 0)
    end
end

---------------------------------------------------------------------------
-- Just landed: between a spell landing (UNIT_SPELLCAST_SUCCEEDED) and the
-- game showing its DoT on the target (or its travel time, Haunt) there's a
-- moment where the prediction would suggest it again. So the last spell to
-- land keeps counting as applied on the target for up to LANDED_GRACE
-- seconds: until the combat log shows it hit (the game's own state has it
-- then), or right away when it missed (resist, immune, ...), so a missed
-- DoT is suggested again at once.
---------------------------------------------------------------------------
local LANDED_GRACE = 1
local CONFIRM_DELAY = 0.1 -- after the combat log's hit, for the aura update to arrive
local landed = { key = nil, name = nil, at = 0, confirmedAt = nil }
local scratch -- a state copy to apply the landed spell to (State.NewCopy)

local spellKeys = {} -- spell name -> ability key (spells that aren't channels)
local function SpellKey(name)
    if not name then return nil end
    local key = spellKeys[name]
    if key == nil then
        key = false
        for k, ability in pairs(RH.classData.abilities) do
            if ability.id and ability.name == name and not ability.channel then key = k end
        end
        spellKeys[name] = key
    end
    return key or nil
end

function Recommender:OnSpellcastSucceeded(_, unit, spellName)
    if unit ~= "player" then return end
    local key = SpellKey(spellName)
    if not key then return end
    landed.key, landed.name, landed.at, landed.confirmedAt = key, spellName, GetTime(), nil
end

-- 3.3.5 args: timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, spellId, spellName
function Recommender:OnCombatLog(_, _, subevent, srcGUID, _, _, _, _, _, _, spellName)
    if not landed.key or spellName ~= landed.name or srcGUID ~= self.playerGUID then return end
    if subevent == "SPELL_MISSED" then
        landed.key = nil
        RH:Invalidate()
    elseif subevent ~= "SPELL_CAST_START" and subevent ~= "SPELL_CAST_SUCCESS" and subevent ~= "SPELL_CAST_FAILED"
        and not landed.confirmedAt then
        landed.confirmedAt = GetTime()
    end
end

-- The landed spell's effect on the target and its cooldown, on state `v`.
-- Applied to a scratch copy so nothing else (mana, procs used) counts twice:
-- the game has already done those.
function Recommender:ApplyLanded(v)
    local key = landed.key
    if not key then return end
    local now = v.now
    if now - landed.at > LANDED_GRACE or (landed.confirmedAt and now - landed.confirmedAt > CONFIRM_DELAY) then
        landed.key = nil
        return
    end
    scratch = scratch or State.NewCopy()
    State.CopyInto(scratch, v)
    Abilities.Apply(scratch, key, math.min(now, landed.at))
    State.CopyAuras(v.debuffs, scratch.debuffs)
    local cd, applied = v.cooldowns[key], scratch.cooldowns[key]
    if cd and applied and applied.readyAt > cd.readyAt then cd.readyAt = applied.readyAt end
end

-- Predicts the next `count` actions from the current real state: pick an
-- action, simulate using it on a virtual copy of the state, and repeat.
-- Fills and returns the shared recommendations list (entries:
-- { name, spellId, wait, lacksResources, action, limitedBy, usesProc,
-- procExpires, procReason }, wait counted from now; action is the APL line
-- that chose it), and the number of entries. `trace` collects the decision trace of the first pick.
--
-- For the dual display's AoE icons, `enemies` overrides the enemy count and
-- the results go to the AoE tables (the rune prediction is left alone).
-- `cooldowns` = false turns the cooldown toggles off (both the boss-only
-- one and the short cooldowns) to keep major cooldowns out of the main
-- queue for the separate cooldowns display, which gets its own run with
-- them as toggled (`which` = "cd").
function Recommender:Predict(count, trace, enemies, cooldowns, which)
    local out, pool = recommendations, entries
    if enemies then out, pool = aoeRecommendations, aoeEntries end
    if which == "cd" then out, pool = cdRecommendations, cdEntries end
    local now = State.real.now
    local v = State:Virtual()
    if enemies then v.activeEnemies = enemies end
    if cooldowns == false then v.cooldownsEnabled, v.shortCooldownsEnabled = false, false end
    local n = 0
    -- Channelling for real: maybe cut it after the next tick. Ticks are
    -- counted from its start, shifted like its end by the lookahead.
    local channelKey = ChannelKey(v.channelName)
    if channelKey and v.castStart then
        self:ClipChannel(v, channelKey, v.castStart - (v.lookahead or 0))
    end
    self:ApplyLanded(v)
    self:ApplyCurrentCast(v)
    for i = 1, math.min(count, MAX_PREDICTIONS) do
        local action, readyAt, limitedBy = self:Evaluate(v, i == 1 and trace or nil)
        if not action then break end
        n = i
        local entry = pool[i]
        entry.name = action.name
        SetAbility(entry, RH.classData.abilities[action.name])
        entry.wait = readyAt - now
        entry.lacksResources = limitedBy == "runes"
        -- For the tooltip (A6) and the proc glow (A7).
        entry.action = action
        entry.limitedBy = limitedBy
        entry.usesProc, entry.procExpires = Abilities.ProcUsed(v, action.name, readyAt)
        entry.procReason = entry.usesProc and ProcIsReason(v, action, entry.usesProc, readyAt) or nil
        out[i] = entry
        Abilities.Apply(v, action.name, readyAt)
        self:ClipChannel(v, action.name, readyAt)
    end
    for i = n + 1, #out do out[i] = nil end
    if enemies or which == "cd" then return out, n end
    -- The runes once the predicted actions are used (the rune bar, F1).
    local predicted = self.predictedRunes
    for i, rune in ipairs(v.runes) do
        local p = predicted[i] or {}
        predicted[i] = p
        p.type, p.readyAt = rune.type, rune.readyAt
    end
    return recommendations, n
end

-- With the separate cooldowns display: the first major cooldown the
-- rotation would use with cooldowns on, or nil.
function Recommender:CooldownRecommendation()
    local lists = RH.classData.majorCooldowns
    if not lists or not (State.real.cooldownsEnabled or State.real.shortCooldownsEnabled) then return nil end
    local recs, n = self:Predict(MAX_PREDICTIONS, nil, nil, true, "cd")
    for i = 1, n do
        local name = recs[i].name
        for _, key in ipairs(lists) do
            if key == name then return recs[i] end
        end
    end
    return nil
end

function Recommender:Update(now)
    State:Reset(now)
    local d = RH.db.profile.display
    local t = State.real.target
    local hostile = t.exists and t.canAttack and not t.dead
    now = now or State.real.now
    -- The enemies around, before the AoE mode's say (for the icons' counts).
    RH.detectedEnemies = ns.Targets:ActiveEnemies(now, "auto", hostile)
    -- Separate cooldowns display: major cooldowns leave the main queue.
    local separate = d.separateCooldowns and (State.real.cooldownsEnabled or State.real.shortCooldownsEnabled)
    local cooldowns = nil
    if separate then cooldowns = false end
    local recs, n = self:Predict(d.numIcons, nil, nil, cooldowns)
    RH.recommendations = n > 0 and recs or nil
    RH.alternative = self:Alternative(recs, n)
    RH.aoeRecommendations = nil
    if d.dualDisplay then
        -- The real count when there are more, but at least 3.
        local enemies = ns.Targets:ActiveEnemies(now, "aoe", hostile)
        local aoe, an = self:Predict(d.aoeNumIcons or d.numIcons, nil, enemies, cooldowns)
        RH.aoeRecommendations = an > 0 and aoe or nil
    end
    RH.cooldownRecommendation = separate and self:CooldownRecommendation() or nil
end
