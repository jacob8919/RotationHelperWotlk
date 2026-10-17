-- The consumables toggle (POT): potions only when allowed, bosses only by default.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

-- In combat with a target, Bloodlust up (so the potion line wants to fire),
-- Potion of Speed in the bags, cooldowns on.
local function Fight()
    local s, RH = newAddon()
    s:Learn("Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
        "Horn of Winter", "Death Coil")
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    s:Slash("ACECONSOLE_RH", "lock")
    RH.db.profile.display.showStatus = true -- the CD and POT chips are checked
    RH.db.profile.toggles.cooldowns = true
    s.bags[40211] = 2
    s:FireEvent("BAG_UPDATE")
    s:AddAura("target", { name = "Frost Fever", spellId = 55095, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("target", { name = "Blood Plague", spellId = 55078, duration = 15, expires = s.time + 900, harmful = true })
    s:AddAura("player", { name = "Horn of Winter", spellId = 57623, duration = 120, expires = s.time + 900 })
    s:AddAura("player", { name = "Bloodlust", spellId = 2825, duration = 40, expires = s.time + 40 })
    return s, RH
end

local function First(s)
    s:Tick(0.1)
    local recs = s.env.RotationHelper.recommendations
    return recs and recs[1].name
end

local function Trash(s)
    s.target.level, s.target.classification = 80, "elite"
end

test("potions only against bosses by default", function()
    local s, RH = Fight()
    eq(First(s), "potion", "boss targeted (skull level)")
    Trash(s)
    falsy(First(s) == "potion", "trash pull: no potion")
    s.bossFrames = true
    eq(First(s), "potion", "an add targeted while boss frames are up")
    s.bossFrames = false
    s.target.level, s.target.classification = 83, "worldboss"
    eq(First(s), "potion", "worldboss classification")
end)

test("the toggle turns them off; 'only against bosses' can be turned off", function()
    local s, RH = Fight()
    s:Slash("ACECONSOLE_RH", "pots")
    eq(RH.db.profile.toggles.consumables, false, "/rh pots")
    falsy(First(s) == "potion", "off: no potion on the boss")
    s:Slash("ACECONSOLE_RH", "pots")
    Trash(s)
    local args = s.ns.Options:GetOptionsTable().args.general.args
    args.consumablesBossOnly.set(nil, false)
    falsy(First(s) == "potion", "the potion line is in the cooldowns list, which is for bosses only too")
    RH.db.profile.toggles.cooldownsBossOnly = false
    eq(First(s), "potion", "everywhere")
    truthy(s.env.BINDING_NAME_ROTATIONHELPER_TOGGLE_CONSUMABLES, "key binding")
end)

test("toggle.consumables in rotations", function()
    local s, RH = Fight()
    local resolve = s.ns.Expressions.CreateResolver(s.env.RotationHelper.classData)
    local fn = s.ns.APL.Compiler.CompileExpression("toggle.consumables", resolve)
    eq(fn(s.ns.State:Reset()), 1, "boss")
    Trash(s)
    eq(fn(s.ns.State:Reset()), 0, "trash")
end)

test("POT chip: green on a boss, yellow waiting for one, red when off; click toggles", function()
    local s, RH = Fight()
    local D = s.ns.Display
    First(s)
    eq(D.frame.potChip.text:GetText(), "|cff40ff40POT|r", "green")
    eq(D:GetStatusText(), "CD  POT", "status line")
    Trash(s)
    First(s)
    eq(D.frame.potChip.text:GetText(), "|cffffd100POT|r", "yellow")
    D.frame.potChip.scripts.OnClick(D.frame.potChip)
    First(s)
    eq(D.frame.potChip.text:GetText(), "|cffff4040POT|r", "red")
    s.bags[40211] = nil
    s:FireEvent("BAG_UPDATE")
    First(s)
    falsy(D.frame.potChip:IsShown(), "no potions: no chip")
end)

---------------------------------------------------------------------------
-- Known boss names
---------------------------------------------------------------------------
test("known bosses: a dungeon boss by name, ignoring case", function()
    local s, RH = Fight()
    s.target.level, s.target.classification = 82, "elite"
    s.target.name = "Ingvar the Plunderer"
    eq(First(s), "potion", "Utgarde Keep boss (level 82 elite)")
    s.target.name = "Sjonnir The Ironshaper"
    eq(First(s), "potion", "case doesn't matter")
    s.target.name = "Blood Prince Guard"
    falsy(First(s) == "potion", "an elite that isn't a boss")
end)

test("known bosses: every mob of a multi-boss encounter", function()
    local Bosses = select(1, Fight()).ns.Bosses
    for _, name in ipairs({ "Prince Valanar", "Prince Keleseth", "Prince Taldaram", "Steelbreaker",
        "Runemaster Molgeim", "Stormcaller Brundir", "Thane Korth'azz", "Lady Blaumeux", "Sir Zeliek",
        "Baron Rivendare", "Fjola Lightbane", "Eydis Darkbane", "Stalagg", "Feugen" }) do
        truthy(Bosses:IsKnown(name), name)
    end
    falsy(Bosses:IsKnown(nil), "no name")
    falsy(Bosses:IsKnown("Training Dummy"), "dummy")
end)

test("known bosses: extra names from the options; the options show the target", function()
    local s, RH = Fight()
    Trash(s)
    s.target.name = "Some Custom Boss"
    falsy(First(s) == "potion", "unknown")
    local args = s.ns.Options:GetOptionsTable().args.general.args
    truthy(args.bossTarget.name():find("Some Custom Boss (|cffffd100not a boss|r)", 1, true), "shown as not a boss")
    args.extraBosses.set(nil, "Another One,  some custom boss ")
    eq(First(s), "potion", "added (trimmed, any case)")
    truthy(args.bossTarget.name():find("counts as a boss", 1, true), "now a boss")
    args.extraBosses.set(nil, "")
    falsy(First(s) == "potion", "removed again")
end)

---------------------------------------------------------------------------
-- Cooldowns: bosses only too
---------------------------------------------------------------------------
test("big cooldowns only against bosses by default; the CD chip shows it", function()
    local s, RH = Fight()
    s.bags[40211] = nil
    s:FireEvent("BAG_UPDATE")
    s:Learn("Blood Fury") -- a big cooldown (no Unbreakable Armor talent here)
    local D = s.ns.Display
    eq(First(s), "blood_fury", "boss: cooldowns")
    eq(D.frame.cdChip.text:GetText(), "|cff40ff40CD|r", "green")
    Trash(s)
    s.target.name = "Ymirjar Deathbringer"
    falsy(First(s) == "blood_fury", "trash: none")
    eq(D.frame.cdChip.text:GetText(), "|cffffd100CD|r", "yellow: waiting for a boss")
    s.target.name = "Ingvar the Plunderer"
    eq(First(s), "blood_fury", "a known boss by name")
    s.target.name = "Ymirjar Deathbringer"
    s.ns.Options:GetOptionsTable().args.general.set({ "cooldownsBossOnly" }, false) -- the group's setter
    eq(RH.db.profile.toggles.cooldownsBossOnly, false, "option")
    eq(First(s), "blood_fury", "'only against bosses' off")
    s:Slash("ACECONSOLE_RH", "cd")
    falsy(First(s) == "blood_fury", "toggled off")
    eq(D.frame.cdChip.text:GetText(), "|cffff4040CD|r", "red")
end)

test("short cooldowns (Unbreakable Armor) are used on trash too, unless CD is off", function()
    local s, RH = Fight()
    s:Learn("Unbreakable Armor")
    Trash(s)
    s.target.name = "Ymirjar Deathbringer"
    eq(First(s), "unbreakable_armor", "trash: short cooldown")
    s:Slash("ACECONSOLE_RH", "cd")
    falsy(First(s) == "unbreakable_armor", "CD off: none")
end)

test("the review doesn't count cooldowns as unused on trash", function()
    local s, RH = Fight()
    s:Learn("Unbreakable Armor")
    Trash(s)
    s.target.name = "Ymirjar Deathbringer"
    for _ = 1, 250 do s:Tick(0.1) end
    s:FireEvent("PLAYER_REGEN_ENABLED")
    local review = RH.db.char.reviews[#RH.db.char.reviews]
    truthy(review, "reviewed")
    eq(#review.cooldowns, 0, "no unused cooldowns on trash")
end)
