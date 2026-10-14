-- Version check: players tell each other their version; a newer one is
-- announced once (chat line + a box with the download link). Versions here
-- are relative to ours: 9.x is always newer, 0.1.0 always older.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local PREFIX = "RotHelperVer"
local NEWER, NEWEST, OLDER = "9.0.0", "9.1.0", "0.1.0"

-- Our version, read from the .toc like the addon does.
local OURS = (function()
    local f = assert(io.open("RotationHelper/RotationHelper.toc", "r"))
    local version = f:read("*a"):match("## Version: (%S+)")
    f:close()
    return version
end)()

-- For chat patterns.
local function Escaped(version) return (version:gsub("%.", "%%.")) end

local function Wait(s, seconds)
    for _ = 1, seconds * 10 do s:Tick(0.1) end
end

local function Messages(s, prefix)
    local out = {}
    for _, m in ipairs(s.addonMessages) do
        if m.prefix == prefix then out[#out + 1] = m.channel .. (m.target and (":" .. m.target) or "") .. " " .. m.text end
    end
    return table.concat(out, " | ")
end

local function Receive(s, text, sender)
    s:FireEvent("CHAT_MSG_ADDON", PREFIX, text, "GUILD", sender or "Someone")
end

local function Popups(s)
    local n = 0
    for _, p in ipairs(s.popups) do if p.which == "ROTATIONHELPER_UPDATE" then n = n + 1 end end
    return n
end

test("versions: parsing and comparing", function()
    local s = newAddon()
    local V = s.ns.VersionCheck
    truthy(V.IsNewer("1.36.1", "1.36.0"), "patch")
    truthy(V.IsNewer("1.37.0", "1.36.9"), "minor")
    truthy(V.IsNewer("2.0.0", "1.99.99"), "major")
    truthy(V.IsNewer("1.10.0", "1.9.0"), "numbers, not text")
    falsy(V.IsNewer("1.36.0", "1.36.0"), "same")
    falsy(V.IsNewer("dev", "1.0.0"), "not a version")
    eq(s.env.RotationHelper.version, OURS, "our version from the .toc")
    truthy(V.Parse(OURS), "a real version")
end)

test("at login: our version to the guild and the group", function()
    local s = newAddon()
    s.guild, s.party = true, 2
    Wait(s, 11)
    eq(Messages(s, PREFIX), "GUILD V:" .. OURS .. " | PARTY V:" .. OURS, "sent")
end)

test("group changes: sent once when they settle", function()
    local s = newAddon()
    Wait(s, 11)
    s.addonMessages = {}
    s.raid = 10
    s:FireEvent("RAID_ROSTER_UPDATE")
    s:FireEvent("RAID_ROSTER_UPDATE")
    s:FireEvent("PARTY_MEMBERS_CHANGED")
    Wait(s, 6)
    eq(Messages(s, PREFIX), "RAID V:" .. OURS, "once, to the raid")
end)

test("a newer version: told once, with the link", function()
    local s, RH = newAddon()
    s:ClearChat()
    Receive(s, "V:" .. NEWER)
    truthy(s:ChatContains("Version " .. Escaped(NEWER) .. " is available %(you have " .. Escaped(OURS) .. "%)"),
        "chat line")
    truthy(s:ChatContains("github.com/rynosuki/RotationHelperWotlk/releases"), "the link")
    eq(Popups(s), 1, "the link box")
    eq(RH.db.global.newestVersion, NEWER, "remembered")
    s:ClearChat()
    Receive(s, "V:" .. NEWEST, "Other")
    falsy(s:ChatContains("is available"), "not again this session")
    eq(Popups(s), 1, "no second box")
    eq(RH.db.global.newestVersion, NEWEST, "but the newest is remembered")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "version")
    truthy(s:ChatContains("You have " .. Escaped(OURS) .. "; " .. Escaped(NEWEST) .. " is available"), "/rh version")
end)

test("the link box waits until combat ends", function()
    local s = newAddon()
    s:FireEvent("PLAYER_REGEN_DISABLED")
    Receive(s, "V:" .. NEWER)
    eq(Popups(s), 0, "not in combat")
    s:FireEvent("PLAYER_REGEN_ENABLED")
    eq(Popups(s), 1, "after combat")
end)

test("the link box shows the URL ready to copy", function()
    local s = newAddon()
    local text, highlighted
    local box = { SetText = function(_, t) text = t end, HighlightText = function() highlighted = true end,
        SetFocus = function() end }
    s.env.StaticPopupDialogs.ROTATIONHELPER_UPDATE.OnShow({ editBox = box })
    eq(text, "https://github.com/rynosuki/RotationHelperWotlk/releases", "URL")
    truthy(highlighted, "selected")
end)

test("an older version: we whisper ours back, at most once a minute each", function()
    local s = newAddon()
    Receive(s, "V:" .. OLDER, "Oldie")
    Receive(s, "V:" .. OLDER, "Oldie")
    eq(Messages(s, PREFIX), "WHISPER:Oldie V:" .. OURS, "one reply")
    s.time = s.time + 61
    Receive(s, "V:" .. OLDER, "Oldie")
    eq(Messages(s, PREFIX), "WHISPER:Oldie V:" .. OURS .. " | WHISPER:Oldie V:" .. OURS, "again after a minute")
    Receive(s, "V:" .. OURS, "Same")
    eq(#s.addonMessages, 2, "same version: nothing")
end)

test("ignored: our own messages, other addons, junk", function()
    local s, RH = newAddon()
    Receive(s, "V:" .. NEWER, "Tester") -- the player
    s:FireEvent("CHAT_MSG_ADDON", "OtherAddon", "V:" .. NEWER, "GUILD", "Someone")
    Receive(s, "V:" .. NEWER .. " please click evil.link")
    Receive(s, "hello")
    eq(RH.db.global.newestVersion, nil, "nothing taken")
    eq(Popups(s), 0, "no box")
end)

test("turned off: nothing sent or shown", function()
    local s, RH = newAddon()
    RH.db.global.versionCheck = false
    s.guild = true
    Wait(s, 11)
    Receive(s, "V:" .. NEWER)
    eq(Messages(s, PREFIX), "", "nothing sent")
    eq(Popups(s), 0, "nothing shown")
    truthy(s.ns.Options:GetOptionsTable().args.general.args.versionCheck, "option")
end)

test("next login: a newer version seen before is mentioned; updating clears it", function()
    local s, RH = newAddon()
    RH.db.global.newestVersion = NEWER
    s:ClearChat()
    Wait(s, 11)
    truthy(s:ChatContains("Version " .. Escaped(NEWER) .. " is available"), "reminded")
    s, RH = newAddon()
    RH.db.global.newestVersion = OURS -- we have it now
    RH:GetModule("VersionCheck"):OnEnable()
    eq(RH.db.global.newestVersion, nil, "forgotten")
end)

test("no Blizzard UI globals are reassigned (that taints them: 'blocked from an action')", function()
    -- Adding entries (StaticPopupDialogs["X"] = ...) is fine; assigning the
    -- table itself (StaticPopupDialogs = StaticPopupDialogs or {}) is not.
    local GLOBALS = { "StaticPopupDialogs", "UISpecialFrames", "UIPanelWindows", "CloseSpecialWindows",
        "ToggleGameMenu", "StaticPopup_Show", "ChatFrame_OnEvent", "SlashCmdList" }
    local files = { "UI/VersionCheck.lua", "UI/APLShare.lua", "UI/Options.lua", "UI/Window.lua", "Core.lua" }
    for _, path in ipairs(files) do
        local text = io.open("RotationHelper/" .. path):read("*a")
        for _, name in ipairs(GLOBALS) do
            for line in text:gmatch("[^\n]+") do
                if not line:match("^%s*%-%-") and line:match("^%s*" .. name .. "%s*=[^=]") then
                    error(("%s assigns the global %s: %s"):format(path, name, line), 0)
                end
            end
        end
    end
end)
