-- The Hekili look: icons with a border outside, Arial Narrow corner text,
-- cooldown swipes on every icon, the enemy count and delay on the main
-- icon, the autocast shine, the unlock boxes, notifications, presets, the
-- reactive AoE display and the separate cooldowns display.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon
local Mock = require("wowmock")

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

-- A Frost DK in combat with a dummy, diseases and Horn up, display locked.
local function Fight(opts)
    opts = opts or {}
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
        "Horn of Winter", "Death Coil", "Unbreakable Armor", "Mind Freeze")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = opts.cooldowns or false
    if not opts.unlocked then s:Slash("ACECONSOLE_RH", "lock") end
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    return s, RH
end

local function Main(s) return s.ns.Display.buttons[1] end

local function Hit(s, guid)
    s:CombatLog("SPELL_DAMAGE", Mock.PLAYER_GUID, Mock.FLAGS_ME, guid, Mock.FLAGS_HOSTILE_NPC)
end

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
test("defaults are Hekili's stock display", function()
    local s, RH = newAddon()
    local d = RH.db.defaults.profile.display
    eq(d.numIcons .. "/" .. d.iconSize .. "/" .. d.queueSize .. "/" .. d.spacing, "3/50/50/5", "3 icons of 50px, 5px apart")
    eq(d.zoom, 30, "30% zoom trims the icon borders")
    eq(d.border .. "," .. table.concat(d.borderColor, ","), "1,0,0,0,1", "1px black border")
    eq(d.fontSize, 12, "12pt text")
    eq(d.glowMode, "autocast", "autocast shine")
    eq(d.delayType, "TEXT", "delay in seconds")
    truthy(d.keybindQueued and d.targetCount and d.highlightCurrent and d.notifications, "Hekili's features on")
    eq(table.concat(d.point, ","), "CENTER,UIParent,CENTER,0,-225", "Hekili's primary position")
    eq(table.concat(d.aoePoint, ","), "CENTER,UIParent,CENTER,0,-170", "Hekili's AOE position")
    eq(table.concat(d.interruptPoint, ","), "CENTER,UIParent,CENTER,-55,-225", "Hekili's interrupts position")
    eq(table.concat(d.cooldownPoint, ","), "CENTER,UIParent,CENTER,0,-280", "Hekili's cooldowns position")
    for _, key in ipairs({ "showStatus", "pressFlash", "castSlot", "procBadge", "holdIndicator", "alternative",
        "warningBorders", "runeBar", "cooldownStrip", "timeline", "separateCooldowns", "dualDisplay", "reactiveAoE" }) do
        falsy(d[key], key .. " off by default")
    end
    eq(table.concat(d.colors.outOfRange, ","), "1,0,0", "Hekili's out-of-range red")
    eq(table.concat(d.colors.noResources, ","), "0.4,0.4,0.4", "Hekili's unusable grey")
end)

---------------------------------------------------------------------------
-- The button
---------------------------------------------------------------------------
test("button: the icon fills it, the border sits outside and under it, zoomed 30%", function()
    local s, RH = Fight()
    s:Tick(0.1)
    local b = Main(s)
    eq(b:GetWidth(), 50, "icon size")
    eq(b.icon.points[1][1], "ALL", "the icon fills the button")
    eq(b.border:GetWidth(), 52, "border frame: icon + 1px each side")
    eq(b.border.backdrop.edgeSize, 1, "1px edge")
    eq(table.concat(b.border.backdropBorderColor, ","), "0,0,0,1", "black")
    truthy(b.border:IsShown(), "shown")
    truthy(b.border.frameLevel < b:GetFrameLevel(), "under the icon")
    near(b.icon.texCoord[1], 0.075, "zoom: left coordinate")
    near(b.icon.texCoord[2], 0.925, "zoom: right coordinate")
    eq(s.ns.Display.buttons[2]:GetWidth(), 50, "queued icons the same size by default")
    local _, rel, relPoint, x = s.ns.Display.buttons[2]:GetPoint(1)
    eq(rel, b, "chained to the main icon")
    eq(relPoint .. x, "RIGHT5", "5px to the right")
end)

test("button: the border follows its settings (thickness, class color, none)", function()
    local s, RH = Fight()
    local d = RH.db.profile.display
    d.border, d.borderClassColor = 2, true
    RH:OnConfigChanged()
    local b = Main(s)
    eq(b.border:GetWidth(), 54, "2px each side")
    eq(b.border.backdrop.edgeSize, 2, "edge")
    near(b.border.backdropBorderColor[1], 0.77, "Death Knight red")
    d.border = 0
    RH:OnConfigChanged()
    falsy(b.border:IsShown(), "no border")
    eq(b.border.backdrop, nil, "backdrop cleared")
    d.zoom = 0
    RH:OnConfigChanged()
    eq(b.icon.texCoord[1] .. "," .. b.icon.texCoord[2], "0,1", "no zoom")
end)

test("button: Arial Narrow outlined text in Hekili's corners, keybinds on queued icons too", function()
    local s, RH = Fight()
    s:PlaceSpell(2, 51425, "ACTIONBUTTON2", "SHIFT-2")
    s:PlaceSpell(3, 55268, "ACTIONBUTTON3", "3") -- Frost Strike
    s.power.current = 100 -- Frost Strike queued after Obliterate
    s:Tick(0.1)
    local D = s.ns.Display
    local b = D.buttons[1]
    local font, size, flags = b.key:GetFont()
    eq(font .. " " .. size .. " " .. flags, "Fonts\\ARIALN.TTF 12 OUTLINE", "keybind font")
    local point, rel, relPoint, x, y = b.key:GetPoint(1)
    eq(point .. "/" .. relPoint .. " " .. x .. "," .. y, "TOPRIGHT/TOPRIGHT 1,-1", "keybind top right")
    eq(rel, b, "on the button")
    eq((b.delay:GetPoint(1)), "TOPLEFT", "delay top left")
    eq((b.targets:GetPoint(1)), "BOTTOMRIGHT", "enemy count bottom right")
    eq((b.hold:GetPoint(1)), "BOTTOM", "caption at the bottom")
    eq(RH.recommendations[1].name .. "/" .. RH.recommendations[2].name, "obliterate/frost_strike", "the queue")
    eq(b.key:GetText(), "S2", "main keybind")
    eq(D.buttons[2].key:GetText(), "3", "queued keybind")
    RH.db.profile.display.keybindQueued = false
    RH:OnConfigChanged()
    s:Tick(0.1)
    eq(D.buttons[2].key:GetText(), "", "queued keybinds off")
    RH.db.profile.display.fontSize = 16
    RH:OnConfigChanged()
    eq(select(2, b.key:GetFont()), 16, "font size setting")
    eq(select(2, b.targets:GetFont()), 16, "for every corner")
end)

---------------------------------------------------------------------------
-- Cooldown swipes
---------------------------------------------------------------------------
test("queued icons show their spell's real cooldown, GCD included", function()
    local s, RH = Fight()
    s.cooldowns["Death Coil"] = { s.time - 0.5, 1.5 } -- the GCD, 1s left
    s.cooldowns["Frost Strike"] = { s.time - 0.5, 1.5 }
    s.power.current = 100 -- Frost Strike queued after Obliterate
    s:Tick(0.1)
    local D = s.ns.Display
    local index
    for i, e in ipairs(RH.recommendations) do
        if i > 1 and e.name == "frost_strike" and not index then index = i end
    end
    truthy(index, "Frost Strike queued")
    local cd = D.buttons[index].cooldown
    truthy(cd:IsShown(), "swipe on the queued icon")
    near(cd.cooldownStart, s.time - 0.6, "from the real cooldown's start")
    eq(cd.cooldownDuration, 1.5, "its duration")
    s.cooldowns["Frost Strike"] = nil
    s:Tick(0.1)
    falsy(cd:IsShown(), "no cooldown: no swipe")
end)

test("the main icon's swipe runs from the GCD's start to the predicted press time (Hekili's extend)", function()
    local s, RH = Fight()
    s.cooldowns["Death Coil"] = { s.time - 0.5, 1.5 } -- the GCD started 0.5s ago
    s:Tick(0.1)
    local b = Main(s)
    local wait = RH.recommendations[1].wait
    near(wait, 0.9, "ready when the GCD ends", 0.15)
    truthy(b.cooldown:IsShown(), "swipe")
    near(b.cooldown.cooldownStart, s.time - 0.6, "from the GCD's start", 0.01)
    near(b.cooldown.cooldownStart + b.cooldown.cooldownDuration, s.time + wait, "to the press time", 0.01)
end)

test("the main icon's swipe runs from the ability's own cooldown when that's what it waits on", function()
    local s, RH = Fight()
    for i = 1, 6 do s.runes[i].readyAt = s.time + 100 end -- no runes: Horn of Winter (cooldown 20s) is next
    s.cooldowns["Horn of Winter"] = { s.time - 15, 20 }
    s.auras.player = {} -- Horn missing, so it's due
    s:Tick(0.1)
    eq(RH.recommendations[1].name, "horn_of_winter", "Horn next")
    local b = Main(s)
    near(b.cooldown.cooldownStart, s.time - 15.1, "from the cooldown's start", 0.01)
    near(b.cooldown.cooldownDuration, 20, "the whole cooldown", 0.15)
end)

---------------------------------------------------------------------------
-- Delay and enemy count
---------------------------------------------------------------------------
test("delay: seconds in the top-left corner when the wait is beyond the cooldown shown", function()
    local s, RH = Fight()
    local b = Main(s)
    s:Tick(0.1)
    eq(b.delay:GetText(), "", "everything ready: no delay")
    for i = 1, 6 do s.runes[i].readyAt = s.time + 3.1 end
    s:Tick(0.1)
    eq(b.delay:GetText(), "3.0", "waiting on runes: the seconds")
    falsy(b.delayIcon:IsShown(), "no dot in text mode")
    s.cooldowns["Death Coil"] = { s.time, 1.5 } -- a GCD wait alone is what the swipe shows
    for i = 1, 6 do s.runes[i].readyAt = s.time end
    s:Tick(0.1)
    eq(b.delay:GetText(), "", "just the GCD: no delay")
    s.cooldowns["Death Coil"] = nil
    for i = 1, 6 do s.runes[i].readyAt = s.time + 20 end
    s:Tick(0.1)
    eq(b.delay:GetText(), "20", "whole seconds from 10s on")
end)

test("delay: the colored dot, or nothing", function()
    local s, RH = Fight()
    local b = Main(s)
    RH.db.profile.display.delayType = "ICON"
    for i = 1, 6 do s.runes[i].readyAt = s.time + 3 end
    s:Tick(0.1)
    truthy(b.delayIcon:IsShown(), "dot shown")
    eq(b.delayIcon.vertexColor[1] .. b.delayIcon.vertexColor[2], "10", "red: 1.5s or more")
    eq(b.delay:GetText(), "", "no text")
    for i = 1, 6 do s.runes[i].readyAt = s.time + 1 end
    s:Tick(0.1)
    eq(b.delayIcon.vertexColor[1] .. b.delayIcon.vertexColor[2], "11", "yellow: under 1.5s")
    for i = 1, 6 do s.runes[i].readyAt = s.time + 0.3 end
    s:Tick(0.1)
    eq(b.delayIcon.vertexColor[1] .. b.delayIcon.vertexColor[2], "01", "green: under 0.5s")
    RH.db.profile.display.delayType = "NONE"
    s:Tick(0.1)
    falsy(b.delayIcon:IsShown(), "off")
    eq(b.delay:GetText(), "", "off")
end)

test("enemy count: like Hekili, 1 in single-target mode, the count when more, red or blue when forced", function()
    local s, RH = Fight()
    local b = Main(s)
    s:Tick(0.1)
    eq(b.targets:GetText(), "", "auto, one enemy: nothing")
    Hit(s, s.target.guid)
    Hit(s, "mob2")
    Hit(s, "mob3")
    s:Tick(0.1)
    eq(b.targets:GetText(), "3", "auto: the count")
    RH.db.profile.toggles.aoeMode = "single"
    s:Tick(0.1)
    eq(b.targets:GetText(), "|cFF00C0FF1|r", "forced single with 3 around: 1 in blue")
    s.ns.Targets:OnCombatEnded()
    RH.db.profile.toggles.aoeMode = "aoe"
    s:Tick(0.1)
    eq(b.targets:GetText(), "|cFFFF00003|r", "forced AoE with 1 around: 3 in red")
    RH.db.profile.toggles.aoeMode = "auto"
    RH.db.profile.display.targetCount = false
    s:Tick(0.1)
    eq(b.targets:GetText(), "", "turned off")
end)

test("enemy count with the dual display: 1 on the main display, 3+ on the AoE one", function()
    local s, RH = Fight()
    s:Slash("ACECONSOLE_RH", "dual")
    s:Tick(0.1)
    eq(Main(s).targets:GetText(), "1", "main: single target")
    eq(s.ns.AoEDisplay.buttons[1].targets:GetText(), "|cFFFF00003|r", "AoE: 3 assumed, 1 around")
    Hit(s, s.target.guid)
    Hit(s, "mob2")
    Hit(s, "mob3")
    Hit(s, "mob4")
    s:Tick(0.1)
    eq(Main(s).targets:GetText(), "|cFF00C0FF1|r", "main: 1 in blue with 4 around")
    eq(s.ns.AoEDisplay.buttons[1].targets:GetText(), "4", "AoE: the real count")
end)

---------------------------------------------------------------------------
-- Highlight and glow
---------------------------------------------------------------------------
test("the main icon is highlighted while its spell is the one being cast", function()
    local s, RH = Fight()
    local b = Main(s)
    s:Tick(0.1)
    falsy(b.highlight:IsShown(), "not casting")
    s.current["Obliterate"] = true
    s:Tick(0.1)
    truthy(b.highlight:IsShown(), "highlighted")
    eq(b.highlight:GetTexture(), "Interface\\Buttons\\ButtonHilight-Square", "the action button highlight")
    RH.db.profile.display.highlightCurrent = false
    s:Tick(0.1)
    falsy(b.highlight:IsShown(), "off")
end)

local function Buff(s, name, spellId, remains)
    s:AddAura("player", { name = name, spellId = spellId, duration = 30, expires = s.time + remains })
end

test("glow styles: autocast shine, pixel glow, the action button glow; color and queued options", function()
    local s, RH = Fight()
    local d = RH.db.profile.display
    for i = 1, 6 do s.runes[i].readyAt = s.time + 5 end
    Buff(s, "Freezing Fog", 59052, 10) -- Rime: free Howling Blast glows
    s:Tick(0.1)
    local b = Main(s)
    eq(RH.recommendations[1].name, "howling_blast", "Howling Blast")
    truthy(b.glowing and b.glowMode == "autocast", "autocast shine")
    local shine = b.glowFrames.autocast
    truthy(shine:IsShown(), "shown")
    eq(#shine.textures, 16, "four rings of four sparkles")
    eq(shine.textures[1]:GetTexture(), "Interface\\ItemSocketingFrame\\UI-ItemSockets", "the glint texture")
    near(shine.textures[1].vertexColor[1], 0.95, "Hekili's yellow")
    eq(shine.textures[1]:GetWidth(), 7, "the biggest sparkles first")
    eq(shine.textures[16]:GetWidth(), 4, "the smallest last")
    -- The sparkles move around the edge.
    shine.scripts.OnUpdate(shine, 0.5)
    local p1 = { shine.textures[1]:GetPoint(1) }
    shine.scripts.OnUpdate(shine, 0.5)
    local p2 = { shine.textures[1]:GetPoint(1) }
    truthy(p1[4] ~= p2[4] or p1[5] ~= p2[5] or p1[3] ~= p2[3], "orbiting")

    d.glowMode = "pixel"
    RH:OnConfigChanged()
    s:Tick(0.1)
    truthy(b.glowMode == "pixel" and b.glowFrames.pixel:IsShown(), "pixel glow")
    falsy(shine:IsShown(), "the shine is gone")
    local shownLines = 0
    for _, line in ipairs(b.glowFrames.pixel.lines) do
        if line[1]:IsShown() then shownLines = shownLines + 1 end
    end
    eq(shownLines, 8, "eight lines")

    d.glowMode, d.glowClassColor = "button", true
    RH:OnConfigChanged()
    s:Tick(0.1)
    truthy(b.glowMode == "button" and b.glowFrames.button:IsShown(), "button glow")
    eq(b.glowFrames.button:GetWidth(), 70, "1.4 times the icon, like the action bars")
    near(b.glowFrames.button.ring.vertexColor[1], 0.77, "class colored")

    d.glowQueued = true
    for i = 1, 6 do s.runes[i].readyAt = s.time end
    s.power.current = 100
    Buff(s, "Killing Machine", 51124, 10)
    RH:OnConfigChanged()
    s:Tick(0.1)
    local glowingQueued = false
    for i = 2, 4 do
        if s.ns.Display.buttons[i].glowing then glowingQueued = true end
    end
    truthy(glowingQueued, "a queued icon spending a proc glows too")

    d.glowMode = "none"
    RH:OnConfigChanged()
    s:Tick(0.1)
    falsy(b.glowing, "no glow")
end)

---------------------------------------------------------------------------
-- Unlocked: the boxes
---------------------------------------------------------------------------
test("unlocked: a dark box with a class-colored border and the name over each display", function()
    local s, RH = Fight({ unlocked = true })
    RH:OnConfigChanged() -- lays the box out for the harness's 4 icons
    s:Tick(0.1)
    local D = s.ns.Display
    local m = D.frame.mover
    truthy(m:IsShown(), "shown")
    eq(m.header:GetText(), "Primary", "name")
    eq(select(3, m.header:GetFont()), "OUTLINE", "outlined")
    eq(table.concat(m.backdropColor, ","), "0,0,0,0.8", "dark")
    near(m.backdropBorderColor[1], 0.77, "class color")
    -- Around the three icons: left edge from the main icon, right edge from the last.
    local points = {}
    for i = 1, 4 do
        local point, rel, _, x = m:GetPoint(i)
        points[point] = { rel, x }
    end
    eq(points.LEFT[1], D.buttons[1], "left: the main icon")
    eq(points.LEFT[2], -2, "2px out")
    eq(points.RIGHT[1], D.buttons[RH.db.profile.display.numIcons], "right: the last icon")
    eq(points.TOP[1], D.buttons[1], "top: the main icon (the biggest)")
    truthy(m:IsMouseEnabled(), "takes the mouse")
    -- Dragging the box moves the display and saves the position.
    m.scripts.OnDragStart(m)
    truthy(D.frame.moving, "the display moves")
    D.frame:ClearAllPoints()
    D.frame:SetPoint("TOPLEFT", s.env.UIParent, "TOPLEFT", 100, -50)
    m.scripts.OnDragStop(m)
    eq(table.concat(RH.db.profile.display.point, ","), "TOPLEFT,UIParent,TOPLEFT,100,-50", "saved")
    -- Right-click opens the display settings.
    local opened
    s.ns.OptionsWindow.Open = function(_, tab) opened = tab return true end
    m.scripts.OnMouseUp(m, "RightButton")
    eq(opened, "display", "settings opened")
    -- The other displays have theirs, greyed out when they're off.
    truthy(s.ns.Notifications.frame.mover:IsShown(), "notifications box")
    eq(s.ns.Notifications.frame.mover.header:GetText(), "Notifications", "its name")
    truthy(s.ns.AoEDisplay.frame.mover:IsShown(), "AoE box")
    truthy(s.ns.AoEDisplay.frame.mover.inactive, "greyed: the dual display is off")
    eq(table.concat(s.ns.AoEDisplay.frame.mover.backdropBorderColor, ","), "0.5,0.5,0.5,0.5", "grey border")
    truthy(s.ns.CooldownDisplay.frame.mover:IsShown(), "cooldowns box")
    eq(s.ns.CooldownDisplay.frame.mover.header:GetText(), "Cooldowns", "its name")
    eq(s.ns.CooldownDisplay.button.icon:GetTexture() ~= nil, true, "with a sample cooldown")
    s:Slash("ACECONSOLE_RH", "lock")
    s:Tick(0.1)
    falsy(m:IsShown(), "locked: gone")
    falsy(s.ns.Notifications.frame.mover:IsShown(), "all of them")
    falsy(s.ns.CooldownDisplay.frame:IsShown(), "the cooldowns display is off")
end)

test("unlocked: the box grows with the queue direction", function()
    local s, RH = Fight({ unlocked = true })
    RH.db.profile.display.direction = "UP"
    RH.db.profile.display.queueSize = 60 -- bigger than the main icon
    RH:OnConfigChanged()
    local D = s.ns.Display
    local points = {}
    for i = 1, 4 do
        local point, rel = D.frame.mover:GetPoint(i)
        points[point] = rel
    end
    eq(points.TOP, D.buttons[4], "top: the last queued icon")
    eq(points.BOTTOM, D.buttons[1], "bottom: the main icon")
    eq(points.LEFT, D.buttons[2], "left: a queued icon, the widest")
end)

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------
test("toggles are announced in the middle of the screen and fade out", function()
    local s, RH = Fight()
    local f = s.ns.Notifications.frame
    eq(f:GetName(), "RotationHelperNotification", "frame")
    eq(f:GetWidth() .. "x" .. f:GetHeight(), "600x40", "Hekili's panel size")
    local font, size, flags = f.text:GetFont()
    eq(font .. " " .. size .. " " .. flags, "Fonts\\ARIALN.TTF 20 OUTLINE", "font")
    eq(f.text:GetAlpha(), 0, "nothing yet")
    s:Slash("ACECONSOLE_RH", "cd")
    eq(f.text:GetText(), "Cooldowns: ON", "the toggle")
    eq(f.text:GetAlpha(), 1, "shown")
    near(f.text.textColor[2], 0.8, "gold")
    s:Tick(1.5)
    near(f.text:GetAlpha(), 0.5, "fading", 0.05)
    s:Tick(2)
    eq(f.text:GetAlpha(), 0, "gone after 3s")
    s:Slash("ACECONSOLE_RH", "aoe")
    eq(f.text:GetText(), "Mode: Single Target", "the mode")
    s:Slash("ACECONSOLE_RH", "pots")
    eq(f.text:GetText(), "Potions: OFF", "potions")
    s:Slash("ACECONSOLE_RH", "pause")
    eq(f.text:GetText(), "PAUSED", "pause")
    truthy(s:ChatContains("Paused"), "chat still says so")
    RH.db.profile.display.notifications = false
    RH:OnConfigChanged()
    falsy(f:IsShown(), "turned off")
    falsy(s.ns.Notify("Cooldowns: OFF"), "nothing shown")
end)

---------------------------------------------------------------------------
-- Presets
---------------------------------------------------------------------------
test("presets: grambam's compact layout, then back to stock; values stay editable", function()
    local s, RH = Fight()
    local d = RH.db.profile.display
    s:Slash("ACECONSOLE_RH", "preset grambam")
    eq(d.iconSize .. "/" .. d.queueSize .. "/" .. d.spacing .. "/" .. d.numIcons, "32/30/1/3", "compact sizes")
    eq(table.concat(d.point, ","), "CENTER,UIParent,CENTER,-25,-140", "position")
    eq(d.aoeIconSize .. "/" .. d.aoeQueueSize .. "/" .. d.aoeNumIcons, "30/30/3", "AoE display sizes")
    eq(table.concat(d.aoePoint, ","), "CENTER,UIParent,CENTER,91,-140", "AoE display to the right")
    truthy(d.dualDisplay and d.reactiveAoE, "dual display, reactive")
    eq(table.concat(d.interruptPoint, ","), "CENTER,UIParent,CENTER,-149,-203", "interrupts position")
    truthy(s:ChatContains("preset 'grambam' applied"), "says so")
    eq(Main(s):GetWidth(), 32, "applied to the icons")
    eq(s.ns.Display.buttons[2]:GetWidth(), 30, "queue")
    -- Editable afterwards.
    d.iconSize = 40
    RH:OnConfigChanged()
    eq(Main(s):GetWidth(), 40, "edited")
    s:Slash("ACECONSOLE_RH", "preset hekili")
    eq(d.iconSize .. "/" .. d.queueSize .. "/" .. d.spacing, "50/50/5", "stock again")
    falsy(d.dualDisplay, "single display")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "preset nope")
    truthy(s:ChatContains("Usage: /rh preset"), "unknown preset")
    -- From the options too.
    local args = s.ns.Options:GetOptionsTable().args.display.args
    args.presetGrambam.func()
    eq(d.iconSize, 32, "options button")
    args.presetHekili.func()
    eq(d.iconSize, 50, "and back")
    -- The preset tables aren't shared with the profile.
    d.point[5] = -999
    eq(s.ns.Display.PRESETS.hekili.point[5], -225, "preset untouched")
end)

---------------------------------------------------------------------------
-- Reactive AoE display and the separate cooldowns display
---------------------------------------------------------------------------
test("reactive: the AoE display only appears with 3 or more enemies", function()
    local s, RH = Fight()
    local d = RH.db.profile.display
    d.dualDisplay, d.reactiveAoE = true, true
    RH:OnConfigChanged()
    s:Tick(0.1)
    local f = s.ns.AoEDisplay.frame
    falsy(f:IsShown(), "one enemy: hidden")
    Hit(s, s.target.guid)
    Hit(s, "mob2")
    s:Tick(0.1)
    falsy(f:IsShown(), "two: hidden")
    Hit(s, "mob3")
    s:Tick(0.1)
    truthy(f:IsShown(), "three: shown")
    d.reactiveAoE = false
    s.ns.Targets:OnCombatEnded()
    s:Tick(0.1)
    truthy(f:IsShown(), "not reactive: always shown")
end)

test("separate cooldowns display: major cooldowns leave the queue for their own icon", function()
    local s, RH = Fight({ cooldowns = true })
    s:Tick(0.1)
    eq(RH.recommendations[1].name, "unbreakable_armor", "inline by default")
    falsy(s.ns.CooldownDisplay.frame:IsShown(), "no cooldowns display")
    RH.db.profile.display.separateCooldowns = true
    RH:OnConfigChanged()
    s:Tick(0.1)
    for i, e in ipairs(RH.recommendations) do falsy(e.name == "unbreakable_armor", "out of the queue " .. i) end
    eq(RH.cooldownRecommendation.name, "unbreakable_armor", "the cooldown to use")
    local CD = s.ns.CooldownDisplay
    truthy(CD.frame:IsShown(), "shown")
    eq(CD.button.icon:GetTexture(), s.env.GetSpellInfo(51271) and select(3, s.env.GetSpellInfo(51271)), "its icon")
    eq(CD.frame:GetWidth(), 50, "Hekili's 50px")
    local point, _, _, x, y = CD.frame:GetPoint(1)
    eq(point .. x .. "," .. y, "CENTER0,-280", "below the main display")
    s.cooldowns["Unbreakable Armor"] = { s.time, 60 }
    s:Tick(0.1)
    eq(RH.cooldownRecommendation, nil, "used: nothing to show")
    falsy(CD.frame:IsShown(), "hidden")
    s:Slash("ACECONSOLE_RH", "cd")
    s:Tick(0.1)
    eq(RH.cooldownRecommendation, nil, "cooldowns off: nothing")
end)

test("options: the display tab has the Hekili sections", function()
    local s = newAddon()
    local args = s.ns.Options:GetOptionsTable().args.display.args
    for _, key in ipairs({ "zoom", "border", "borderClassColor", "borderColor", "fontSize", "keybindQueued",
        "targetCount", "delayType", "highlightCurrent", "glowMode", "glowColor", "glowQueued", "reactiveAoE",
        "interruptSize", "separateCooldowns", "cooldownSize", "notifications", "warningBorders", "presetHekili",
        "presetGrambam", "queueSize" }) do
        truthy(args[key], "option " .. key)
    end
    eq(args.queueScale, nil, "the queue scale is gone (pixels now)")
    truthy(args.glowMode.disabled == nil or not args.glowMode.disabled(), "glow style available")
end)
