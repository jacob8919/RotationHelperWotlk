local ADDON_NAME, ns = ...
local RH = ns.RH

-- The interrupt display (Hekili's "Interrupts"): one icon for the class's
-- interrupt (Death Knight: Mind Freeze), shown only while the hostile
-- target casts or channels something interruptible. It never takes a
-- rotation slot, and has its own position (display.interruptPoint) and
-- size (display.interruptSize); it moves while unlocked.
--
-- Hidden when the interrupt isn't known, or its cooldown won't be over
-- before the cast ends. Keybind, range and runic power tints and the
-- cooldown swipe work like the other icons.
local Interrupt = RH:NewModule("Interrupt", "AceEvent-3.0")
ns.Interrupt = Interrupt

local GetTime, UnitCastingInfo, UnitChannelInfo = GetTime, UnitCastingInfo, UnitChannelInfo
local max = math.max

local PREVIEW_CAST_SECONDS = 2

local entry = {} -- reused display entry

-- Seconds left on the target's interruptible cast or channel, or nil.
-- 3.3.5: notInterruptible is the 9th return for casts, the 8th for channels.
function Interrupt:TargetCastRemains(now)
    local name, _, _, _, _, endTime, _, _, notInterruptible = UnitCastingInfo("target")
    if not name then
        name, _, _, _, _, endTime, _, notInterruptible = UnitChannelInfo("target")
    end
    if not name or notInterruptible or not endTime then return nil end
    return max(0, endTime / 1000 - now)
end

-- The entry to show, or nil. `s` is the real state.
function Interrupt:GetEntry(s, now)
    local key = RH.classData.interrupt
    local ability = key and RH.classData.abilities[key]
    if not (ability and ns.Spec.known[key]) then return nil end
    if ability.requiresForm and s.form ~= ability.requiresForm then return nil end -- Pummel: Berserker Stance

    local castRemains
    if ns.Display.testMode or not ns.Display.db.locked then
        castRemains = PREVIEW_CAST_SECONDS -- sample, so it can be seen while positioning
    else
        local t = s.target
        if not (t.exists and t.canAttack and not t.dead) then return nil end
        castRemains = self:TargetCastRemains(now)
        if not castRemains then return nil end
    end

    local cd = s.cooldowns[key]
    local cdRemains = cd and max(0, cd.readyAt - s.now) or 0
    if cdRemains > castRemains then return nil end -- can't make it

    entry.name = key
    entry.spellId = ability.id
    entry.wait = cdRemains
    entry.lacksResources = s.power < ns.Abilities.RunicPowerCost(ability)
    return entry
end

function Interrupt:Create()
    local Display = ns.Display
    local f = CreateFrame("Frame", "RotationHelperInterruptDisplay", UIParent)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        Interrupt:SavePosition()
    end)
    f.SavePosition = function() Interrupt:SavePosition() end
    f:Hide()
    self.frame = f
    local b = Display.CreateButton(f, "RotationHelperInterruptButton")
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    self.button = b
    ns.Mover.Create(f, "Interrupts", ns.Mover.OpenDisplaySettings)
    self:Layout()
end

function Interrupt:SavePosition()
    local point, _, relPoint, x, y = self.frame:GetPoint(1)
    RH.db.profile.display.interruptPoint = { point, "UIParent", relPoint, x, y }
end

function Interrupt:Layout()
    local f, b, d = self.frame, self.button, RH.db.profile.display
    local size = d.interruptSize or d.iconSize
    f:ClearAllPoints()
    local p = d.interruptPoint
    f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
    f:SetScale(d.scale)
    f:SetWidth(size)
    f:SetHeight(size)
    f:EnableMouse(not d.locked)
    ns.Display.StyleButton(b, d)
    ns.Display.SetButtonSize(b, size)
    if d.locked then
        f.mover:Hide()
    else
        ns.Mover.Layout(f.mover, b, b, b, b, not d.interrupt)
        f.mover:Show()
    end
end

function Interrupt:Update(now)
    local Display = ns.Display
    if not Display.frame then return end
    if not self.button then self:Create() end
    local d = RH.db.profile.display
    local shownEntry = d.interrupt and (Display.frame:IsShown() or not d.locked)
        and self:GetEntry(ns.State.real, now)
    if shownEntry then
        Display:UpdateButton(self.button, shownEntry, true, now)
        self.frame:Show()
    else
        self.button:Hide()
        if d.locked then self.frame:Hide() end
    end
end

function Interrupt:OnEnable()
    if not RH.classSupported then return end
    -- Casts start and stop between regular updates; react right away.
    local function OnTargetCast(_, unit)
        if unit == "target" then RH:Invalidate() end
    end
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
        self:RegisterEvent(event, OnTargetCast)
    end
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", function()
        if not Interrupt.button then Interrupt:Create() end
        Interrupt:Layout()
        if not RH.db.profile.display.locked then Interrupt.frame:Show() end
    end)
    -- After the display, which decides whether the display is shown.
    RH:RegisterUpdater(function(_, now) Interrupt:Update(now) end, RH.UPDATE_ORDER.INTERRUPT,
        "interrupt icon", function() if Interrupt.button then Interrupt.button:Hide() end end)
end
