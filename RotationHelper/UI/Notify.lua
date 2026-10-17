local ADDON_NAME, ns = ...
local RH = ns.RH

-- Hekili's notification panel: when a toggle changes ("Cooldowns: ON"),
-- the text shows in gold at the middle of the screen and fades out over
-- a few seconds. Movable while the display is unlocked.
local Notify = RH:NewModule("Notify", "AceEvent-3.0")
ns.Notifications = Notify

local CreateFrame, GetTime = CreateFrame, GetTime

local WIDTH, HEIGHT = 600, 40
local FONT = "Fonts\\ARIALN.TTF"
local FONT_SIZE = 20
Notify.DURATION = 3

function Notify:CreateFrames()
    local f = CreateFrame("Frame", "RotationHelperNotification", UIParent)
    f:SetWidth(WIDTH)
    f:SetHeight(HEIGHT)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f.text = f:CreateFontString("RotationHelperNotificationText", "OVERLAY")
    f.text:SetFont(FONT, FONT_SIZE, "OUTLINE")
    f.text:SetAllPoints(f)
    f.text:SetJustifyH("CENTER")
    f.text:SetJustifyV("MIDDLE")
    f.text:SetTextColor(1, 0.8, 0, 1)
    f.text:SetAlpha(0)
    f.SavePosition = function(frame)
        local point, _, relPoint, x, y = frame:GetPoint(1)
        RH.db.profile.display.notifyPoint = { point, "UIParent", relPoint, x, y }
    end
    -- Fades the text out over DURATION seconds after Show().
    f:SetScript("OnUpdate", function(frame)
        if not frame.fadeStart then return end
        local t = GetTime() - frame.fadeStart
        local duration = frame.fadeDuration or Notify.DURATION
        if t >= duration then
            frame.text:SetAlpha(0)
            frame.fadeStart = nil
        else
            frame.text:SetAlpha(1 - t / duration)
        end
    end)
    ns.Mover.Create(f, "Notifications", ns.Mover.OpenDisplaySettings)
    self.frame = f
end

function Notify:ApplySettings()
    local d, f = RH.db.profile.display, self.frame
    f:ClearAllPoints()
    local p = d.notifyPoint
    f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
    if d.locked or not d.notifications then
        f.mover:Hide()
    else
        ns.Mover.Layout(f.mover, f, f, f, f)
        f.mover:Show()
    end
    if d.notifications then f:Show() else f:Hide() end
end

-- Shows `text` for `duration` seconds (3 by default). Returns true when
-- it was shown (notifications on). Also reachable as ns.Notify(text).
function Notify:Show(text, duration)
    local f = self.frame
    if not f or not RH.db.profile.display.notifications then return false end
    f.text:SetText(text)
    f.text:SetAlpha(1)
    f.fadeStart = GetTime()
    f.fadeDuration = duration or Notify.DURATION
    return true
end

function ns.Notify(text, duration)
    return Notify:Show(text, duration)
end

function Notify:OnEnable()
    self:CreateFrames()
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", "ApplySettings")
    self:ApplySettings()
end
