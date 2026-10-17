local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local function near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-6 then
        error(("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)), 2)
    end
end

local function Fight()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Blood Strike", "Horn of Winter")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    return s, RH
end

---------------------------------------------------------------------------
test("lookahead: latency, custom lag tolerance, fixed, off, capped", function()
    local s, RH = newAddon()
    local State = s.ns.State
    s.latencyMs = 120
    local seconds, source = State:Lookahead()
    near(seconds, 0.12, "latency")
    eq(source, "latency", "source")

    s.cvars.reducedLagTolerance = "1"
    s.cvars.MaxSpellStartRecoveryOffset = "80"
    seconds, source = State:Lookahead()
    near(seconds, 0.08, "custom lag tolerance wins")
    eq(source, "custom lag tolerance", "source")

    RH.db.profile.latency.mode = "fixed"
    RH.db.profile.latency.fixedMs = 150
    near((State:Lookahead()), 0.15, "fixed")
    RH.db.profile.latency.mode = "off"
    eq((State:Lookahead()), 0, "off")

    RH.db.profile.latency.mode = "auto"
    s.cvars.reducedLagTolerance = "0"
    s.latencyMs = 2000
    near((State:Lookahead()), 0.4, "a lag spike is capped at 400 ms")
end)

test("the GCD ends early by the lookahead; runes don't", function()
    local s = Fight()
    s.latencyMs = 100
    s.cooldowns["Death Coil"] = { s.time - 1.42, 1.5 } -- 0.08s of GCD left
    local st = s.ns.State:Reset()
    eq(st.gcdRemains, 0, "GCD counts as over")
    local action, t = s.ns.Recommender:Evaluate(st)
    eq(action.name, "obliterate", "recommendation")
    near(t - st.now, 0, "press now: it gets queued")

    s.cooldowns["Death Coil"] = nil
    for i = 3, 6 do s.runes[i].readyAt = s.time + 0.08 end
    s.cooldowns["Horn of Winter"] = { s.time, 20 }
    for i = 1, 2 do s.runes[i].readyAt = s.time + 5 end
    st = s.ns.State:Reset()
    action, t = s.ns.Recommender:Evaluate(st)
    near(t - st.now, 0.08, "a rune 0.08s away still waits: early presses are refused")
end)

test("no latency, no change", function()
    local s = Fight()
    s.cooldowns["Death Coil"] = { s.time - 1, 1.5 }
    local st = s.ns.State:Reset()
    near(st.gcdRemains, 0.5, "full GCD")
    eq(st.lookahead, 0, "no lookahead")
end)

test("/rh snapshot shows the lookahead", function()
    local s = Fight()
    s.latencyMs = 90
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "snapshot")
    truthy(s:ChatContains("Lookahead: 90 ms %(latency%)"), "line")
end)

---------------------------------------------------------------------------
-- Press-now flash
---------------------------------------------------------------------------
-- Locked display, all runes down for `seconds`, so the main icon counts down.
local function CountingDown(seconds)
    local s, RH = Fight()
    s:Slash("ACECONSOLE_RH", "lock")
    RH.db.profile.display.pressFlash = true
    for i = 1, 6 do s.runes[i].readyAt = s.time + seconds end
    s.cooldowns["Horn of Winter"] = { s.time, 20 }
    return s, RH
end

test("the main icon flashes when its ability becomes ready", function()
    local s = CountingDown(0.5)
    local b = s.ns.Display.buttons[1]
    s:Tick(0.1)
    truthy(b.readyAt, "counting down")
    falsy(b.flash:IsShown(), "no flash yet")
    for _ = 1, 9 do s:Tick(0.05) end -- past the ready time
    truthy(b.flash:IsShown(), "flashing")
    truthy(b.flash.alpha > 0 and b.flash.alpha <= 0.55, "fading")
    for _ = 1, 8 do s:Tick(0.05) end
    falsy(b.flash:IsShown(), "flash over")
end)

test("no flash when turned off", function()
    local s, RH = CountingDown(0.5)
    RH.db.profile.display.pressFlash = false
    for _ = 1, 12 do s:Tick(0.05) end
    falsy(s.ns.Display.buttons[1].flash:IsShown(), "no flash")
end)

test("no flash when a different ability takes the main spot", function()
    local s = CountingDown(0.5)
    local b = s.ns.Display.buttons[1]
    s:Tick(0.1)
    -- Something else becomes the recommendation, ready at once.
    s.ns.Display:UpdateButton(b, { spellId = 57623, wait = 0 }, true, s.time)
    falsy(b.flashStart, "no flash for a replacement")
end)
