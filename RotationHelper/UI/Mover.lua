local ADDON_NAME, ns = ...
local RH = ns.RH

-- Hekili's unlocked look: each display gets a dark box over its icons
-- with a border in your class color and the display's name across it.
-- Drag the box to move the display; right-click opens the display
-- settings. Locked, the box is hidden and the display is click-through.
local Mover = {}
ns.Mover = Mover

local CreateFrame, GameTooltip, UnitClass = CreateFrame, GameTooltip, UnitClass

local WHITE = "Interface\\Buttons\\WHITE8X8"
local PAD = 2
local HEADER_FONT = "Fonts\\FRIZQT__.TTF"
local HEADER_SIZE = 18
local INACTIVE = { 0.5, 0.5, 0.5, 0.5 }

function Mover.ClassColor()
    local _, class = UnitClass("player")
    local color = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    return 1, 0.82, 0
end

-- Creates the box as a child of `frame` (the movable display frame), named
-- `title`. `onSettings` opens the display's settings on a right-click.
function Mover.Create(frame, title, onSettings)
    local m = CreateFrame("Frame", nil, frame)
    m:SetFrameLevel(frame:GetFrameLevel() + 12)
    m:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 } })
    m:SetBackdropColor(0, 0, 0, 0.8)
    m.title = title

    m.header = m:CreateFontString(nil, "OVERLAY")
    m.header:SetFont(HEADER_FONT, HEADER_SIZE, "OUTLINE")
    m.header:SetTextColor(1, 0.82, 0)
    m.header:SetAllPoints(m)
    m.header:SetJustifyH("CENTER")
    m.header:SetJustifyV("MIDDLE")
    m.header:SetText(title)

    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m:SetScript("OnDragStart", function() frame:StartMoving() end)
    m:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        if frame.SavePosition then frame:SavePosition() end
    end)
    m:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and onSettings then onSettings() end
    end)
    m:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("RotationHelper: " .. title)
        GameTooltip:AddLine("Left-click and hold to move.", 1, 1, 1)
        GameTooltip:AddLine("Right-click to open the display settings.", 1, 1, 1)
        if self.inactive then GameTooltip:AddLine("This display is not currently active.", 0.5, 0.5, 0.5) end
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m:Hide()
    frame.mover = m
    return m
end

-- Fits the box around the display: `left`, `right`, `top` and `bottom`
-- are the outermost icons (any can be the same frame). `inactive` greys
-- the border, for a display that wouldn't show while locked.
function Mover.Layout(m, left, right, top, bottom, inactive)
    m:ClearAllPoints()
    m:SetPoint("LEFT", left, "LEFT", -PAD, 0)
    m:SetPoint("RIGHT", right, "RIGHT", PAD, 0)
    m:SetPoint("TOP", top, "TOP", 0, PAD)
    m:SetPoint("BOTTOM", bottom, "BOTTOM", 0, -PAD)
    m.inactive = inactive
    if inactive then
        m:SetBackdropBorderColor(INACTIVE[1], INACTIVE[2], INACTIVE[3], INACTIVE[4])
    else
        local r, g, b = Mover.ClassColor()
        m:SetBackdropBorderColor(r, g, b, 1)
    end
end

function Mover.OpenDisplaySettings()
    ns.Options:Open("display")
end
