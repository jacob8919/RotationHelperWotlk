local ADDON_NAME, ns = ...
local RH = ns.RH

-- "A newer version is available". WoW addons can't go online, so, like DBM
-- and BigWigs, players running RotationHelper tell each other their version
-- with addon messages: to the guild at login, to the group when it changes.
-- Seeing a newer version prints a note once per session and shows the
-- download link in a box to copy from (after combat). Seeing an older one
-- whispers ours back, so news of a new version spreads. The newest version
-- seen is remembered for the next login.
local VersionCheck = RH:NewModule("VersionCheck", "AceEvent-3.0", "AceTimer-3.0")
ns.VersionCheck = VersionCheck

local SendAddonMessage, UnitName, IsInGuild = SendAddonMessage, UnitName, IsInGuild
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers
local tonumber, GetTime = tonumber, GetTime

VersionCheck.PREFIX = "RotHelperVer" -- at most 16 characters
VersionCheck.URL = "https://github.com/rynosuki/RotationHelperWotlk/releases"
local LOGIN_DELAY = 10    -- seconds after login before telling the guild
local GROUP_DELAY = 5     -- group changes come in bursts: wait for them to settle
local REPLY_COOLDOWN = 60 -- seconds between whispers to the same player

-- "1.36.0" -> 1, 36, 0 (nil for anything else, e.g. "dev" builds).
function VersionCheck.Parse(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

-- Whether version `a` is newer than version `b`.
function VersionCheck.IsNewer(a, b)
    local a1, a2, a3 = VersionCheck.Parse(a)
    local b1, b2, b3 = VersionCheck.Parse(b)
    if not (a1 and b1) then return false end
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

local function Enabled()
    return RH.db.global.versionCheck and VersionCheck.Parse(RH.version) ~= nil
end

function VersionCheck:Send(channel, target)
    SendAddonMessage(self.PREFIX, "V:" .. RH.version, channel, target)
end

function VersionCheck:SendToGroup()
    self.groupTimer = nil
    if not Enabled() then return end
    if GetNumRaidMembers() > 0 then
        self:Send("RAID")
    elseif GetNumPartyMembers() > 0 then
        self:Send("PARTY")
    end
end

function VersionCheck:SendAtLogin()
    if not Enabled() then return end
    if IsInGuild() then self:Send("GUILD") end
    self:SendToGroup()
end

function VersionCheck:OnGroupChanged()
    if self.groupTimer then return end
    self.groupTimer = self:ScheduleTimer("SendToGroup", GROUP_DELAY)
end

-- 3.3.5 args: prefix, message, channel, sender.
function VersionCheck:OnAddonMessage(_, prefix, message, _, sender)
    if prefix ~= self.PREFIX or not sender or sender == UnitName("player") then return end
    if not Enabled() then return end
    local version = type(message) == "string" and message:match("^V:(%d+%.%d+%.%d+)$")
    if not version then return end
    if VersionCheck.IsNewer(version, RH.version) then
        self:FoundNewer(version)
    elseif VersionCheck.IsNewer(RH.version, version) then
        -- They're behind: tell them (at most once a minute each).
        local now = GetTime()
        self.replied = self.replied or {}
        if not self.replied[sender] or now - self.replied[sender] >= REPLY_COOLDOWN then
            self.replied[sender] = now
            self:Send("WHISPER", sender)
        end
    end
end

function VersionCheck:FoundNewer(version)
    local global = RH.db.global
    if not global.newestVersion or VersionCheck.IsNewer(version, global.newestVersion) then
        global.newestVersion = version
    end
    self:Notify()
end

-- Once per session: a chat line now, the link box when out of combat.
function VersionCheck:Notify()
    if self.notified then return end
    local newest = RH.db.global.newestVersion
    if not (newest and VersionCheck.IsNewer(newest, RH.version)) then return end
    self.notified = true
    RH:Print(("Version %s is available (you have %s). Download it from %s"):format(newest, RH.version, self.URL))
    if RH.inCombat then
        self.popupAfterCombat = true
    else
        self:ShowPopup()
    end
end

function VersionCheck:ShowPopup()
    self.popupAfterCombat = nil
    StaticPopup_Show("ROTATIONHELPER_UPDATE", RH.db.global.newestVersion, RH.version)
end

-- Only add our entry: assigning the global itself (StaticPopupDialogs =
-- StaticPopupDialogs or {}) taints Blizzard's popups, and then protected
-- actions in them get blocked ("RotationHelper has been blocked from an
-- action only available to the Blizzard UI").
StaticPopupDialogs["ROTATIONHELPER_UPDATE"] = {
    text = "RotationHelper %s is available (you have %s).\nCopy the download link (Ctrl+C):",
    button1 = OKAY or "OK",
    hasEditBox = 1,
    editBoxWidth = 350,
    OnShow = function(self)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        editBox:SetText(VersionCheck.URL)
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

-- /rh version
function RH:PrintVersion()
    local newest = self.db.global.newestVersion
    if newest and VersionCheck.IsNewer(newest, self.version) then
        self:Print(("You have %s; %s is available from %s"):format(self.version, newest, VersionCheck.URL))
    else
        self:Print(("Version %s, the newest seen."):format(self.version))
    end
end

function VersionCheck:OnEnable()
    local global = RH.db.global
    -- Updated since a newer version was seen: forget it.
    if global.newestVersion and not VersionCheck.IsNewer(global.newestVersion, RH.version) then
        global.newestVersion = nil
    end
    self:RegisterEvent("CHAT_MSG_ADDON", "OnAddonMessage")
    self:RegisterEvent("PARTY_MEMBERS_CHANGED", "OnGroupChanged")
    self:RegisterEvent("RAID_ROSTER_UPDATE", "OnGroupChanged")
    self:RegisterMessage("ROTATIONHELPER_COMBAT_CHANGED", function(_, inCombat)
        if not inCombat and VersionCheck.popupAfterCombat then VersionCheck:ShowPopup() end
    end)
    self:ScheduleTimer(function()
        VersionCheck:SendAtLogin()
        -- A newer version seen on an earlier login: remind once.
        if Enabled() then VersionCheck:Notify() end
    end, LOGIN_DELAY)
end
