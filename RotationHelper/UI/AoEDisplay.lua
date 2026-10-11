local ADDON_NAME, ns = ...
local RH = ns.RH

-- The dual display's second display (like Hekili's "AOE" display): the
-- rotation's suggestions as if there were 3 or more enemies, shown at all
-- times next to the main display, which then shows single target. You
-- glance at whichever fits the pull.
--
-- It renders RH.aoeRecommendations (set by Recommender:Update) with the
-- main display's buttons, spacing, direction and colors, but its own size
-- (aoeScale, aoeIconSize, aoeQueueScale, aoeNumIcons) and position
-- (display.aoePoint); it moves while unlocked.
local AoEDisplay = RH:NewModule("AoEDisplay", "AceEvent-3.0")
ns.AoEDisplay = AoEDisplay

local GetTime = GetTime

local MAX_ICONS = 5
local GROW = {
    RIGHT = { "LEFT", "RIGHT", 1, 0 },
    LEFT = { "RIGHT", "LEFT", -1, 0 },
    UP = { "BOTTOM", "TOP", 0, 1 },
    DOWN = { "TOP", "BOTTOM", 0, -1 },
}

function AoEDisplay:CreateFrames()
    local Display = ns.Display
    local f = CreateFrame("Frame", "RotationHelperAoEDisplay", UIParent)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        AoEDisplay:SavePosition()
    end)

    -- "AoE" tag so the two displays can't be mixed up.
    f.tag = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.tag:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 2)
    f.tag:SetText("AoE")

    self.frame = f
    self.buttons = {}
    for i = 1, MAX_ICONS do
        self.buttons[i] = Display.CreateButton(f, "RotationHelperAoEButton" .. i, i == 1)
    end
    f:Hide()
end

function AoEDisplay:SavePosition()
    local point, _, relPoint, x, y = self.frame:GetPoint(1)
    RH.db.profile.display.aoePoint = { point, "UIParent", relPoint, x, y }
end

function AoEDisplay:ApplySettings()
    local d, f = RH.db.profile.display, self.frame
    f:ClearAllPoints()
    local p = d.aoePoint
    f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
    local iconSize = d.aoeIconSize or d.iconSize
    f:SetScale(d.aoeScale or d.scale)
    f:SetWidth(iconSize)
    f:SetHeight(iconSize)
    f:EnableMouse(not d.locked)
    f.tag:SetText(d.locked and "AoE" or "AoE: drag to move")

    -- Laid out like the main display's queue (the timeline option, which
    -- places icons by time, isn't applied here).
    local grow = GROW[d.direction] or GROW.RIGHT
    local queueSize = iconSize * (d.aoeQueueScale or d.queueScale)
    for i, b in ipairs(self.buttons) do
        b:ClearAllPoints()
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            ns.Display.SetButtonSize(b, iconSize)
        else
            b:SetPoint(grow[1], self.buttons[i - 1], grow[2], grow[3] * d.spacing, grow[4] * d.spacing)
            ns.Display.SetButtonSize(b, queueSize)
        end
        b.tint = nil
    end
    self:Refresh()
end

-- The entries to draw, or nil to hide: the same rules as the main display.
function AoEDisplay:GetEntries()
    local d, Display = RH.db.profile.display, ns.Display
    if not d.dualDisplay then return nil end
    if Display.testMode or (not d.locked and RH.classSupported) then
        local recs = RH.aoeRecommendations
        if not Display.testMode and RH:IsActive() and recs and #recs > 0 then return recs end
        return Display:GetPreview()
    end
    if not RH:IsActive() then return nil end
    if d.hideOutOfCombat and not RH.inCombat then return nil end
    local recs = RH.aoeRecommendations
    if recs and #recs > 0 then return recs end
end

function AoEDisplay:Refresh()
    if not self.frame then return end
    local entries = self:GetEntries()
    if not entries then
        self.frame:Hide()
        return
    end
    local d = RH.db.profile.display
    local Display, now, count = ns.Display, GetTime(), d.aoeNumIcons or d.numIcons
    for i, b in ipairs(self.buttons) do
        local entry = i <= count and entries[i]
        if entry then
            Display:UpdateButton(b, entry, i == 1, now)
        else
            b:Hide()
        end
    end
    self.frame:Show()
end

function AoEDisplay:OnEnable()
    self:CreateFrames()
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", "ApplySettings")
    self:RegisterMessage("ROTATIONHELPER_COMBAT_CHANGED", "Refresh")
    RH:RegisterUpdater(function() AoEDisplay:Refresh() end, RH.UPDATE_ORDER.DISPLAY, "aoe display")
    self:ApplySettings()
end
