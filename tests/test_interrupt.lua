local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local MIND_FREEZE_ICON = "i"

-- In combat with a dummy, display locked, Mind Freeze learned and bound.
local function Fight()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Mind Freeze")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    s:Slash("ACECONSOLE_RH", "lock")
    s:PlaceSpell(7, 47528, "ACTIONBUTTON7", "SHIFT-Q")
    s.power.current = 50
    return s, RH
end

local function Button(s) return s.ns.Interrupt.button end

test("shown while the target casts something interruptible", function()
    local s = Fight()
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "no cast: hidden")
    s.targetCast = { name = "Shadow Bolt", endsIn = 2 }
    s:FireEvent("UNIT_SPELLCAST_START", "target")
    s:Tick(0.05)
    truthy(Button(s):IsShown(), "shown")
    eq(Button(s).icon:GetTexture(), MIND_FREEZE_ICON, "Mind Freeze")
    eq(Button(s).key:GetText(), "SQ", "keybind")
    s.targetCast = nil
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "cast over: hidden")
end)

test("hidden for casts that can't be interrupted", function()
    local s = Fight()
    s.targetCast = { name = "Shielded Bolt", endsIn = 2, notInterruptible = true }
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "hidden")
end)

test("channels count too (notInterruptible is their 8th return)", function()
    local s = Fight()
    s.targetChannel = { name = "Drain Life", endsIn = 4 }
    s:Tick(0.1)
    truthy(Button(s):IsShown(), "interruptible channel")
    s.targetChannel.notInterruptible = true
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "shielded channel")
end)

test("cooldown: shown with a swipe if it's back in time, hidden if not", function()
    local s = Fight()
    s.targetCast = { name = "Shadow Bolt", endsIn = 2 }
    s.cooldowns["Mind Freeze"] = { s.time - 9, 10 } -- 1s left
    s:Tick(0.1)
    truthy(Button(s):IsShown(), "back before the cast ends")
    truthy(Button(s).cooldown:IsShown(), "swipe")
    s.cooldowns["Mind Freeze"] = { s.time - 5, 10 } -- 5s left
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "can't make it")
end)

test("tinted for range and runic power", function()
    local s = Fight()
    s.targetCast = { name = "Shadow Bolt", endsIn = 2 }
    s.range["Mind Freeze"] = 0
    s:Tick(0.1)
    eq(Button(s).icon.vertexColor[2], 0, "red: out of range")
    s.range["Mind Freeze"] = 1
    s.power.current = 10
    s:Tick(0.1)
    eq(Button(s).icon.vertexColor[3], 0.4, "grey: not enough runic power")
    eq(Button(s).icon.vertexColor[1], 0.4, "grey (r)")
end)

test("hidden when not learned, for friendly targets, or turned off", function()
    local s, RH = Fight()
    s.targetCast = { name = "Shadow Bolt", endsIn = 2 }
    s.target.canAttack = false
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "friendly target")
    s.target.canAttack = true
    RH.db.profile.display.interrupt = false
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "turned off")
    RH.db.profile.display.interrupt = true
    s.known["Mind Freeze"] = nil
    s:FireEvent("LEARNED_SPELL_IN_TAB")
    s:Tick(0.1)
    falsy(Button(s):IsShown(), "not learned")
end)

test("a sample is shown while the display is unlocked, in its own movable display", function()
    local s, RH = Fight()
    s:Slash("ACECONSOLE_RH", "lock") -- unlock again
    s:Tick(0.1)
    truthy(Button(s):IsShown(), "sample shown")
    local f = s.ns.Interrupt.frame
    eq(f:GetName(), "RotationHelperInterruptDisplay", "its own frame")
    truthy(f:IsShown() and f.mover:IsShown(), "with the box to drag it by")
    eq(f.mover.header:GetText(), "Interrupts", "named like Hekili's")
    local point, _, relPoint, x, y = f:GetPoint(1)
    eq(point .. "/" .. relPoint .. " " .. x .. "," .. y, "CENTER/CENTER -55,-225", "left of the main display, like Hekili's")
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", s.env.UIParent, "TOPLEFT", 10, -20)
    f.mover.scripts.OnDragStop(f.mover)
    eq(table.concat(RH.db.profile.display.interruptPoint, ","), "TOPLEFT,UIParent,TOPLEFT,10,-20", "position saved")
    s:Slash("ACECONSOLE_RH", "lock")
    s:Tick(0.1)
    falsy(f.mover:IsShown(), "box gone once locked")
    falsy(f:IsShown(), "and nothing to interrupt")
end)

test("the interrupt icon never flashes (only the main icon does)", function()
    local s = Fight()
    s.targetCast = { name = "Shadow Bolt", endsIn = 2 }
    s.cooldowns["Mind Freeze"] = { s.time - 9.8, 10 }
    s:Tick(0.1)
    for _ = 1, 10 do s:Tick(0.05) end
    falsy(Button(s).flashStart, "no flash state")
    falsy(Button(s).flash:IsShown(), "no flash")
end)
