-- Rotation settings (Engine/APLOptions.lua): declared with a default
-- rotation, read as option.KEY / option.KEY.VALUE, set on the Rotation tab.
local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local function Fury(rage)
    local s, RH = newAddon({ class = "WARRIOR" })
    s.talentTabs = {
        { name = "Arms", talents = { { "Improved Heroic Strike", 3 } } },
        { name = "Fury", talents = { { "Bloodsurge", 3 }, { "Death Wish", 1 }, { "Bloodthirst", 1 }, { "Titan's Grip", 1 } } },
        { name = "Protection", talents = { { "Shield Specialization", 2 } } },
    }
    s.power = { type = 1, current = rage or 40, max = 100 }
    s.form = 3
    s:Learn("Bloodthirst", "Whirlwind", "Slam", "Execute", "Heroic Strike", "Cleave", "Battle Shout", "Bloodrage",
        "Berserker Rage")
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    s:AddAura("player", { name = "Battle Shout", spellId = 47436, duration = 120, expires = s.time + 120 })
    return s, RH
end

local function Destruction()
    local s, RH = newAddon({ class = "WARLOCK" })
    s.talentTabs = {
        { name = "Affliction", talents = { { "Improved Curse of Agony", 2 } } },
        { name = "Demonology", talents = { { "Demonic Embrace", 3 } } },
        { name = "Destruction", talents = { { "Bane", 5 }, { "Backdraft", 3 }, { "Conflagrate", 1 }, { "Chaos Bolt", 1 },
            { "Ruin", 5 } } },
    }
    s.power = { type = 0, current = 20000, max = 20000 }
    s:Learn("Immolate", "Conflagrate", "Chaos Bolt", "Incinerate", "Curse of Doom", "Curse of Agony",
        "Curse of the Elements", "Corruption", "Shadow Bolt", "Life Tap", "Fel Armor")
    s.hasTarget = true
    s:FireEvent("PLAYER_TALENT_UPDATE")
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    s:AddAura("player", { name = "Fel Armor", spellId = 47893, duration = 1800, expires = s.time + 1800 })
    s:AddAura("target", { name = "Immolate", spellId = 47811, duration = 15, expires = s.time + 12, harmful = true })
    s.cooldowns["Conflagrate"] = { s.time, 10 }
    s.cooldowns["Chaos Bolt"] = { s.time, 12 }
    return s, RH
end

local function First(s)
    s:Tick(0.1)
    local e = (s.env.RotationHelper.recommendations or {})[1]
    return e and e.name
end

local function Errors(s, text, specKey)
    local apl = s.ns.Recommender:Compile(text, specKey)
    local out = {}
    for i, err in ipairs(apl.errors) do out[i] = s.ns.APL.Compiler.FormatError(err) end
    return table.concat(out, "\n")
end

test("every default rotation compiles with its settings", function()
    for class, specs in pairs({ WARRIOR = { "fury", "arms" }, WARLOCK = { "affliction", "destruction", "demonology" },
        ROGUE = { "assassination", "subtlety" }, DRUID = { "feral_combat" }, MAGE = { "arcane" },
        DEATHKNIGHT = { "blood", "unholy" }, HUNTER = { "beast_mastery", "marksmanship", "survival" } }) do
        local s = newAddon({ class = class })
        for _, spec in ipairs(specs) do
            truthy(#s.ns.APLOptions.Declared(spec) > 0, class .. " " .. spec .. " has settings")
            eq(Errors(s, s.ns.APLs[class][spec].text, spec), "", class .. " " .. spec)
        end
    end
end)

test("wrong option names are compile errors that say what's known", function()
    local s = Fury()
    truthy(Errors(s, "actions=bloodthirst,if=option.nope>1", "fury"):find("unknown setting 'nope' (known: hs_rage, cleave_rage)", 1, true),
        "unknown")
    truthy(Errors(s, "actions=bloodthirst,if=option.hs_rage.high", "fury"):find("is a number", 1, true), "number with a value")
    local w = Destruction()
    truthy(Errors(w, "actions=incinerate,if=option.curse", "destruction"):find("use option.curse.VALUE", 1, true), "select alone")
    truthy(Errors(w, "actions=incinerate,if=option.curse.tongues", "destruction")
        :find("unknown value 'tongues' for option.curse (agony, auto, doom, elements, none)", 1, true), "bad value")
    eq(Errors(w, "actions=incinerate,if=option.curse.doom", "destruction"), "", "good value")
    -- Specs without settings say so.
    local dk = newAddon()
    truthy(Errors(dk, "actions=obliterate,if=option.x", "frost"):find("has no settings", 1, true), "none")
end)

test("a range setting applies right away", function()
    local s = Fury(40)
    eq(s.ns.APLOptions.Get("fury", "hs_rage"), 50, "default")
    falsy(First(s) == "heroic_strike", "40 rage: no Heroic Strike at the default 50")
    s.ns.APLOptions.Set("fury", "hs_rage", 30)
    eq(First(s), "heroic_strike", "at 30")
    eq(s.env.RotationHelper.db.profile.aplOptions.WARRIOR.fury.hs_rage, 30, "saved")
    -- Setting the default stores nothing.
    s.ns.APLOptions.Set("fury", "hs_rage", 50)
    eq(s.env.RotationHelper.db.profile.aplOptions.WARRIOR.fury.hs_rage, nil, "default not stored")
    falsy(s.ns.APLOptions.Changed("fury"), "nothing changed")
end)

test("a select setting picks the curse; reset goes back", function()
    local s = Destruction()
    eq(First(s), "curse_of_doom", "auto: Doom on a long fight")
    s.ns.APLOptions.Set("destruction", "curse", "elements")
    eq(First(s), "curse_of_the_elements", "Elements")
    s.ns.APLOptions.Set("destruction", "curse", "agony")
    eq(First(s), "curse_of_agony", "Agony")
    s.ns.APLOptions.Set("destruction", "curse", "none")
    eq(First(s), "incinerate", "no curse")
    truthy(s.ns.APLOptions.Changed("destruction"), "changed")
    eq(s.ns.APLOptions.Describe("destruction"), "curse=none", "described")
    s.ns.APLOptions.Reset("destruction")
    eq(First(s), "curse_of_doom", "back to auto")
    eq(s.ns.APLOptions.Describe("destruction"), "defaults", "described")
end)

test("a custom rotation can read the settings", function()
    local s = Fury(40)
    truthy(s.ns.Options:SaveRotation("fury", "actions=heroic_strike,if=rage>=option.hs_rage\nactions+=/bloodthirst"),
        "saved")
    eq(First(s), "bloodthirst", "40 < 50")
    s.ns.APLOptions.Set("fury", "hs_rage", 40)
    eq(First(s), "heroic_strike", "40 >= 40")
end)

test("the Rotation tab shows the edited spec's settings", function()
    local s = Fury()
    local args = s.ns.Options:GetOptionsTable().args.rotation.args
    local hs = args.setting_fury_hs_rage
    truthy(hs, "Fury Heroic Strike setting")
    eq(hs.type, "range", "a slider")
    falsy(hs.hidden(), "shown for Fury")
    truthy(args.setting_arms_hs_rage.hidden(), "Arms' hidden")
    falsy(args.settingsHeader.hidden(), "header shown")
    truthy(args.settingsReset.disabled(), "nothing to reset")
    hs.set(nil, 70)
    eq(hs.get(), 70, "set")
    falsy(args.settingsReset.disabled(), "can reset")
    args.settingsReset.func()
    eq(hs.get(), 50, "reset")
    s.ns.Options.editSpec = "protection"
    truthy(args.settingsHeader.hidden(), "no settings for a spec without them")
end)

test("the name picker and the report include the settings", function()
    local s = Destruction()
    local found = {}
    for _, entry in ipairs(s.ns.APLText.Names(s.env.RotationHelper.classData, "destruction")) do found[entry.text] = true end
    truthy(found["option.curse.elements"] and found["option.curse.auto"], "picker")
    s.ns.APLOptions.Set("destruction", "curse", "elements")
    truthy(s.ns.Report.Build():find("Rotation settings: curse=elements", 1, true), "report")
end)

test("bad declarations are caught when the rotation registers", function()
    local s = newAddon()
    local ok, err = pcall(s.ns.RegisterAPL, "DEATHKNIGHT", "test", "Test", "actions=obliterate",
        { { key = "x", name = "X", type = "select", default = "a", values = { b = "B" } } })
    falsy(ok, "rejected")
    truthy(tostring(err):find("default not in values", 1, true), err)
end)

test("/rh set: a macro can flip a toggle, set a number or pick a value", function()
    local s, RH = Fury(40)
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "set hs_rage 30")
    truthy(s:ChatContains("Heroic Strike at rage: 30"), "says the new value")
    eq(s.ns.APLOptions.Get("fury", "hs_rage"), 30, "set")
    eq(s.ns.Notifications.frame.text:GetText(), "Heroic Strike at rage: 30", "announced on screen")
    eq(First(s), "heroic_strike", "applies right away")
    s:Slash("ACECONSOLE_RH", "set hs_rage 500")
    eq(s.ns.APLOptions.Get("fury", "hs_rage"), 100, "clamped to the range")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "set hs_rage lots")
    truthy(s:ChatContains("Usage: /rh set hs_rage <20%-100>"), "usage for a bad number")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "set nope")
    truthy(s:ChatContains("Unknown setting 'nope'"), "unknown key")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "set")
    truthy(s:ChatContains("Heroic Strike at rage: 100 %(hs_rage%)"), "lists the settings with their keys")

    s, RH = Destruction()
    s:Slash("ACECONSOLE_RH", "set curse elements")
    eq(First(s), "curse_of_the_elements", "a select value")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "set curse frogs")
    truthy(s:ChatContains("Usage: /rh set curse <"), "usage lists the values")

    -- A toggle flips without a value (the macro case), or takes on/off.
    local d, RH2 = newAddon({ class = "DRUID" })
    d.talentTabs = {
        { name = "Balance", talents = {} },
        { name = "Feral Combat", talents = { { "Ferocity", 5 }, { "Mangle", 1 } } },
        { name = "Restoration", talents = {} },
    }
    d:Learn("Cat Form", "Shred", "Mangle (Cat)")
    d:FireEvent("PLAYER_TALENT_UPDATE")
    eq(d.ns.Spec.key, "feral_combat", "feral")
    d:Slash("ACECONSOLE_RH", "set not_behind")
    eq(d.ns.APLOptions.Get("feral_combat", "not_behind"), true, "flipped on")
    eq(d.ns.Notifications.frame.text:GetText(), "Not behind the target: ON", "announced")
    d:Slash("ACECONSOLE_RH", "set not_behind")
    eq(d.ns.APLOptions.Get("feral_combat", "not_behind"), false, "flipped off")
    d:Slash("ACECONSOLE_RH", "set not_behind on")
    eq(d.ns.APLOptions.Get("feral_combat", "not_behind"), true, "on")
    d:Slash("ACECONSOLE_RH", "set not_behind off")
    eq(d.ns.APLOptions.Get("feral_combat", "not_behind"), false, "off")
    d:ClearChat()
    d:Slash("ACECONSOLE_RH", "set not_behind sideways")
    truthy(d:ChatContains("Usage: /rh set not_behind %[on|off%]"), "usage")
end)
