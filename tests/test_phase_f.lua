-- F1-F3: rune bar, cooldown strip, timeline mode.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local function near(actual, expected, what, tolerance)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local SPELLS = { "Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
    "Horn of Winter", "Death Coil", "Unbreakable Armor", "Empower Rune Weapon", "Blood Tap", "Deathchill" }

-- In combat with a dummy, diseases and Horn up, display locked.
local function Fight()
    local s, RH = newAddon()
    s:Learn(unpack(SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    RH.db.profile.display.runeBar, RH.db.profile.display.cooldownStrip = true, true
    s:Slash("ACECONSOLE_RH", "lock")
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    s:Tick(0.1)
    return s, RH
end

local function Setting(s, RH, key, value)
    RH.db.profile.display[key] = value
    RH:OnConfigChanged()
    s:Tick(0.1)
end

---------------------------------------------------------------------------
-- F1 Rune bar
---------------------------------------------------------------------------
test("rune bar: current runes by type, recharging ones partly filled with seconds", function()
    local s, RH = Fight()
    local D = s.ns.Display
    local bar = D.frame.runeBar
    truthy(bar:IsShown(), "shown by default")
    local cell = bar.cells[1]
    eq(cell.fill.color, D.RUNE_COLORS.blood, "blood")
    eq(cell.fill.alpha, 1, "ready: full")
    eq(cell.text:GetText(), "", "no countdown")
    eq(bar.cells[3].fill.color, D.RUNE_COLORS.unholy, "unholy")
    eq(bar.cells[6].fill.color, D.RUNE_COLORS.frost, "frost")

    s.runes[2].type = 4 -- death
    s.runes[2].readyAt = s.time + 4
    s:Tick(0.1)
    cell = bar.cells[2]
    eq(cell.fill.color, D.RUNE_COLORS.death, "death rune")
    eq(cell.fill.alpha, 0.45, "recharging: dim")
    eq(cell.text:GetText(), "4", "seconds left")
    near(cell.fill:GetWidth(), (bar.cellWidth - 2) * 0.61, "fill by progress", 0.2)
end)

test("rune bar: the strip shows the runes after the queued abilities", function()
    local s, RH = Fight()
    local D = s.ns.Display
    local bar = D.frame.runeBar
    -- Only the blood runes are ready and there's no runic power: Blood
    -- Strike next, which (Blood of the North) makes a death rune.
    for i = 3, 6 do s.runes[i].readyAt = s.time + 9 end
    s.power.current = 0
    s:Tick(0.1)
    eq(RH.recommendations[1].name, "blood_strike", "Blood Strike next")
    local predicted = s.ns.Recommender.predictedRunes
    eq(predicted[1].type, "death", "becomes a death rune")
    eq(bar.cells[1].predicted.color, D.RUNE_COLORS.death, "strip: death")
    eq(bar.cells[1].predicted.alpha, 0.25, "strip: dim, the queue spends it")
    eq(bar.cells[1].fill.color, D.RUNE_COLORS.blood, "still blood now")
end)

test("rune bar: can be turned off", function()
    local s, RH = Fight()
    Setting(s, RH, "runeBar", false)
    falsy(s.ns.Display.frame.runeBar:IsShown(), "hidden")
    local strip = s.ns.Display.frame.cooldownStrip
    local _, rel = strip:GetPoint(1)
    eq(rel, s.ns.Display.buttons[1], "strip moves down to the icons")
end)

---------------------------------------------------------------------------
-- F2 Cooldown strip
---------------------------------------------------------------------------
test("cooldown strip: major cooldowns and trinkets with the time left", function()
    local s, RH = Fight()
    local strip = s.ns.Display.frame.cooldownStrip
    s.items[50000] = { "Some Trinket", "Interface\\Icons\\Trinket", "Some Use",
        tooltip = { "Some Trinket", "Use: Increases attack power by 1024 for 20 sec. (2 Min Cooldown)" } }
    s.equipped[13] = 50000
    s:FireEvent("PLAYER_EQUIPMENT_CHANGED")
    s.cooldowns["Unbreakable Armor"] = { s.time - 10, 60 }
    s.cooldowns["Empower Rune Weapon"] = { s.time - 10, 300 }
    s:Tick(0.1)
    truthy(strip:IsShown(), "shown")
    local keys = {}
    for _, b in ipairs(strip.icons) do
        if b:IsShown() then keys[#keys + 1] = b.key end
    end
    eq(table.concat(keys, " "), "unbreakable_armor empower_rune_weapon deathchill trinket1",
        "known cooldowns in class order, then trinkets (no Gargoyle: not learned)")
    local ua, erw, dc = strip.icons[1], strip.icons[2], strip.icons[3]
    eq(ua.text:GetText(), "50", "seconds")
    truthy(ua.icon.desaturated, "grey while on cooldown")
    near(ua.cooldown.cooldownStart, s.time - 10, "swipe start", 0.2)
    eq(ua.cooldown.cooldownDuration, 60, "swipe length")
    eq(erw.text:GetText(), "5m", "minutes")
    eq(dc.text:GetText(), "", "ready")
    falsy(dc.icon.desaturated, "ready: in color")
    eq(strip.icons[4].icon:GetTexture(), "Interface\\Icons\\Trinket", "trinket icon")
end)

test("cooldown strip: can be turned off", function()
    local s, RH = Fight()
    Setting(s, RH, "cooldownStrip", false)
    falsy(s.ns.Display.frame.cooldownStrip:IsShown(), "hidden")
end)

---------------------------------------------------------------------------
-- F3 Timeline
---------------------------------------------------------------------------
test("timeline: queued icons placed by time; waits show as gaps", function()
    local s, RH = Fight()
    local D = s.ns.Display
    local d = RH.db.profile.display
    RH.db.profile.display.numIcons = 4
    -- One Obliterate now, the next runes much later.
    s.runes[4].readyAt, s.runes[6].readyAt = s.time + 8, s.time + 8
    s.runes[1].readyAt, s.runes[2].readyAt = s.time + 8, s.time + 8
    s.power.current = 0
    Setting(s, RH, "timeline", true)
    local recs = RH.recommendations
    local step = d.queueSize + d.spacing
    local gcd = s.ns.State.real.gcdDuration
    local perSecond = step / gcd
    local origin = recs[1].wait + gcd
    local x = 0
    for i = 2, #recs do
        local b = D.buttons[i]
        x = math.max(x, (recs[i].wait - origin) * perSecond)
        local point, rel, relPoint, offset = b:GetPoint(1)
        eq(point .. " " .. relPoint, "LEFT RIGHT", "anchored " .. i)
        eq(rel, D.buttons[1], "to the main icon " .. i)
        near(offset, d.spacing + x, "position " .. i, 0.51)
        truthy(b.hold:IsShown(), "time label " .. i)
        eq(b.hold:GetText(), ("%.1f"):format(recs[i].wait), "label " .. i)
        x = x + step
    end
    -- Obliterate now, then nothing until the runes are back.
    truthy(recs[2].wait - recs[1].wait > gcd + 1, "there is a wait in the queue")
    local _, _, _, offset2 = D.buttons[2]:GetPoint(1)
    local _, _, _, offset3 = D.buttons[3]:GetPoint(1)
    truthy(offset2 > d.spacing + 50, "a visible gap")
    near(offset3 - offset2, step, "back-to-back GCDs touch", 0.51)
    truthy(D.frame.axis:IsShown(), "axis")
    truthy(D.frame.ticks[1]:IsShown(), "second ticks")
end)

test("timeline: off-GCD cooldowns at the same time sit side by side", function()
    local s, RH = Fight()
    local D = s.ns.Display
    RH.db.profile.toggles.cooldowns = true
    Setting(s, RH, "timeline", true)
    local recs = RH.recommendations
    near(recs[2].wait, recs[1].wait, "same time (off the GCD)", 0.01)
    local _, _, _, offset2 = D.buttons[2]:GetPoint(1)
    local _, _, _, offset3 = D.buttons[3]:GetPoint(1)
    truthy(offset3 >= offset2 + D.buttons[2]:GetWidth(), "no overlap")
end)

test("timeline off: back to the normal queue", function()
    local s, RH = Fight()
    local D = s.ns.Display
    Setting(s, RH, "timeline", true)
    Setting(s, RH, "timeline", false)
    falsy(D.buttons[2].hold:IsShown(), "no time labels")
    falsy(D.frame.axis:IsShown(), "no axis")
    local _, rel = D.buttons[3]:GetPoint(1)
    eq(rel, D.buttons[2], "chained again")
end)

test("the extras create no garbage", function()
    local s, RH = Fight()
    RH.db.profile.toggles.cooldowns = true
    s.cooldowns["Unbreakable Armor"] = { s.time, 60 }
    Setting(s, RH, "timeline", true)
    local function Step(i)
        s.runes[(i % 6) + 1].readyAt = s.time + 3 + (i % 5)
        s:Tick(0.1)
    end
    for i = 1, 200 do Step(i) end -- warm up the text caches
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    for i = 1, 300 do Step(i) end
    local perUpdate = (collectgarbage("count") - before) * 1024 / 300
    collectgarbage("restart")
    truthy(perUpdate < 16, ("%.1f bytes of garbage per update"):format(perUpdate))
end)
