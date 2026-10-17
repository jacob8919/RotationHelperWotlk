local ADDON_NAME, ns = ...
local RH = ns.RH

-- The separate cooldowns display (Hekili's "Cooldowns" display with the
-- cooldowns toggle set to "separate"): with display.separateCooldowns on,
-- major cooldowns leave the main queue and the next one to use shows here
-- as a single icon, with its own position (display.cooldownPoint) and
-- size (display.cooldownSize); it moves while unlocked.
--
-- It renders RH.cooldownRecommendation (Engine/Recommender.lua): the
-- first major cooldown the rotation would use with cooldowns on.
local CooldownDisplay = RH:NewModule("CooldownDisplay", "AceEvent-3.0")
ns.CooldownDisplay = CooldownDisplay

local GetTime = GetTime

local previewEntry = {}

function CooldownDisplay:CreateFrames()
    local Display = ns.Display
    local f = CreateFrame("Frame", "RotationHelperCooldownDisplay", UIParent)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        CooldownDisplay:SavePosition()
    end)
    f.SavePosition = function() CooldownDisplay:SavePosition() end
    self.frame = f
    local b = Display.CreateButton(f, "RotationHelperCooldownButton")
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    self.button = b
    ns.Mover.Create(f, "Cooldowns", ns.Mover.OpenDisplaySettings)
    f:Hide()
end

function CooldownDisplay:SavePosition()
    local point, _, relPoint, x, y = self.frame:GetPoint(1)
    RH.db.profile.display.cooldownPoint = { point, "UIParent", relPoint, x, y }
end

function CooldownDisplay:ApplySettings()
    local d, f, b = RH.db.profile.display, self.frame, self.button
    local size = d.cooldownSize or d.iconSize
    f:ClearAllPoints()
    local p = d.cooldownPoint
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
        ns.Mover.Layout(f.mover, b, b, b, b, not d.separateCooldowns)
        f.mover:Show()
    end
    self:Refresh()
end

-- A sample: the class's first known major cooldown.
function CooldownDisplay:GetPreview()
    local classData = RH.classData
    if not classData then return nil end
    for _, key in ipairs(classData.majorCooldowns or {}) do
        local ability = classData.abilities[key]
        if ability and ability.id and ns.Spec.known[key] then
            previewEntry.name, previewEntry.spellId, previewEntry.wait = key, ability.id, 0
            return previewEntry
        end
    end
    return nil
end

-- The entry to draw, or nil to hide.
function CooldownDisplay:GetEntry()
    local d, Display = RH.db.profile.display, ns.Display
    if Display.testMode or (not d.locked and RH.classSupported) then
        local rec = d.separateCooldowns and RH.cooldownRecommendation
        if not Display.testMode and RH:IsActive() and rec then return rec end
        return self:GetPreview()
    end
    if not d.separateCooldowns or not RH:IsActive() then return nil end
    if d.hideOutOfCombat and not RH.inCombat then return nil end
    return RH.cooldownRecommendation
end

function CooldownDisplay:Refresh()
    if not self.frame then return end
    local entry = self:GetEntry()
    if not entry then
        self.frame:Hide()
        return
    end
    ns.Display:UpdateButton(self.button, entry, true, GetTime())
    self.frame:Show()
end

function CooldownDisplay:OnEnable()
    self:CreateFrames()
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", "ApplySettings")
    self:RegisterMessage("ROTATIONHELPER_COMBAT_CHANGED", "Refresh")
    RH:RegisterUpdater(function() CooldownDisplay:Refresh() end, RH.UPDATE_ORDER.DISPLAY, "cooldown display")
    self:ApplySettings()
end
