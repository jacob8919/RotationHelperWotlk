local T = require("testlib")
local test, eq, truthy, falsy, newAddon = T.test, T.eq, T.truthy, T.falsy, T.newAddon

local ALL_SPELLS = {
    "Icy Touch", "Plague Strike", "Obliterate", "Frost Strike", "Howling Blast", "Blood Strike",
    "Pestilence", "Horn of Winter", "Death Coil",
}

local function Fight()
    local s, RH = newAddon()
    s:Learn(unpack(ALL_SPELLS))
    s.hasTarget = true
    s:FireEvent("PLAYER_REGEN_DISABLED")
    RH.db.profile.toggles.cooldowns = false
    return s, RH
end

local function Options(s) return s.ns.Options end
local function Args(s, tab) return Options(s):GetOptionsTable().args[tab].args end

local function First(s)
    local st = s.ns.State:Reset()
    local action = s.ns.Recommender:Evaluate(st)
    return action and action.name
end

-- Registers a fake AceConfigDialog that records what was opened, and a fake
-- AceGUI whose containers count ReleaseChildren calls.
local function StubDialog(s)
    local gui = s.env.LibStub:NewLibrary("AceGUI-3.0", 99999)
    function gui:Create(widgetType)
        local c = { type = widgetType, frame = s.env.CreateFrame("Frame"), children = {}, released = 0 }
        function c:SetLayout() end
        function c:SetWidth(w) self.width = w end
        function c:SetHeight(h) self.height = h end
        function c:DoLayout() end
        function c:ReleaseChildren() self.released = self.released + 1 end
        function c:SetAutoAdjustHeight(adjust) self.noAutoHeight = not adjust end
        return c
    end

    local dialog = s.env.LibStub:NewLibrary("AceConfigDialog-3.0", 99999)
    dialog.opened, dialog.containers = {}, {}
    function dialog:Open(app, container)
        self.opened[#self.opened + 1] = app
        self.containers[#self.containers + 1] = container
    end
    function dialog:SelectGroup(app, group) self.selected = group end
    return dialog
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
test("the options table passes AceConfig validation", function()
    local s = newAddon()
    local registry = s.env.LibStub("AceConfigRegistry-3.0")
    local ok, err = pcall(registry.ValidateOptionsTable, registry, Options(s):GetOptionsTable(), "RotationHelper")
    truthy(ok, tostring(err))
    truthy(registry:GetOptionsTable("RotationHelper"), "registered")
end)

test("/rh opens our window with the options drawn into it", function()
    local s = newAddon()
    local dialog = StubDialog(s)
    s:Slash("ACECONSOLE_RH", "")
    local Window = s.ns.OptionsWindow
    truthy(Window.frame:IsShown(), "window shown")
    eq(dialog.opened[1], "RotationHelper", "options drawn")
    eq(dialog.containers[1], Window.container, "into our container")
    eq(Window.frame.strata, "FULLSCREEN_DIALOG", "same strata as AceGUI windows")
    eq(s.env.UISpecialFrames[1], "RotationHelperOptionsWindow", "Escape closes it")
    s:Slash("ACECONSOLE_RH", "apl")
    eq(dialog.selected, "rotation", "rotation tab")
end)

test("the options fill the window, also after resizing", function()
    local s = newAddon()
    StubDialog(s)
    s:Slash("ACECONSOLE_RH", "")
    local Window = s.ns.OptionsWindow
    -- 820x660 window, minus 10+10 at the sides and 44 above, 14 below.
    eq(Window.container.width, 800, "width")
    eq(Window.container.height, 602, "height")
    eq(Window.container.noAutoHeight, true, "doesn't shrink to its content")
    Window.frame:SetWidth(700)
    Window.frame:SetHeight(500)
    Window.frame.scripts.OnSizeChanged(Window.frame)
    eq(Window.container.width, 680, "width after resize")
    eq(Window.container.height, 442, "height after resize")
end)

test("closing the window gives the widgets back to AceGUI", function()
    local s = newAddon()
    StubDialog(s)
    s:Slash("ACECONSOLE_RH", "")
    local Window = s.ns.OptionsWindow
    Window.closeButton.scripts.OnClick(Window.closeButton)
    falsy(Window.frame:IsShown(), "hidden")
    eq(Window.container.released, 1, "children released")
end)

test("slash commands redraw the open window", function()
    local s = newAddon()
    local dialog = StubDialog(s)
    s:Slash("ACECONSOLE_RH", "")
    local before = #dialog.opened
    s:Slash("ACECONSOLE_RH", "cd")
    s:Tick(0.05)
    eq(#dialog.opened, before + 1, "redrawn once")
    s:Tick(0.05)
    eq(#dialog.opened, before + 1, "not again")
    s.ns.OptionsWindow:Close()
    s:Slash("ACECONSOLE_RH", "cd")
    s:Tick(0.05)
    eq(#dialog.opened, before + 1, "closed: no redraw")
end)

test("Interface > AddOns has a launcher for the window", function()
    local Mock = require("wowmock")
    local s = Mock.NewSession()
    local categories = {}
    s.env.InterfaceOptions_AddCategory = function(panel) categories[#categories + 1] = panel end
    s.env.InterfaceOptionsFrame = s.env.CreateFrame("Frame")
    s.env.GameMenuFrame = s.env.CreateFrame("Frame")
    s:LoadAddon()
    eq(categories[1].name, "RotationHelper", "category")
    StubDialog(s)
    local button
    for _, f in ipairs(s.frames) do
        if f.parent == categories[1] and f.frameType == "Button" then button = f end
    end
    button.scripts.OnClick(button)
    truthy(s.ns.OptionsWindow.frame:IsShown(), "window opened")
    falsy(s.env.InterfaceOptionsFrame:IsShown(), "Blizzard options closed")
end)

test("/rh without the dialog prints help instead", function()
    local s = newAddon()
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "")
    truthy(s:ChatContains("/rh apl"), "help")
end)

test("the rotation tab is hidden for classes without data", function()
    local s = newAddon({ class = "MONK" })
    truthy(Options(s):GetOptionsTable().args.rotation.hidden(), "hidden")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "apl")
    truthy(s:ChatContains("No rotation support for MONK"), "message")
end)

test("general and display settings write to the profile", function()
    local s, RH = newAddon()
    local general = Options(s):GetOptionsTable().args.general
    general.set({ "general", "cooldowns" }, false)
    eq(RH.db.profile.toggles.cooldowns, false, "cooldowns")
    general.set({ "general", "aoeMode" }, "aoe")
    eq(general.get({ "general", "aoeMode" }), "aoe", "aoe mode")

    local display = Options(s):GetOptionsTable().args.display
    display.set({ "display", "numIcons" }, 2)
    eq(RH.db.profile.display.numIcons, 2, "icons")
    display.set({ "display", "direction" }, "UP")
    local point, _, relPoint = s.ns.Display.buttons[2]:GetPoint(1)
    eq(point .. "/" .. relPoint, "BOTTOM/TOP", "layout updated")

    RH.db.profile.display.point = { "TOPLEFT", "UIParent", "TOPLEFT", 5, 5 }
    Args(s, "display").resetPosition.func()
    eq(RH.db.profile.display.point[1] .. RH.db.profile.display.point[5], "CENTER-225", "position reset (Hekili's spot)")
end)

---------------------------------------------------------------------------
-- Rotation editor
---------------------------------------------------------------------------
test("the editor shows the default rotation", function()
    local s = Fight()
    local text = Args(s, "rotation").text.get()
    truthy(text:find("actions%+=/obliterate"), "default text")
    truthy(Options(s):RotationStatus("frost"):find("Frost %(default%)"), "status")
end)

test("a rotation with errors isn't saved; the draft and errors stay", function()
    local s, RH = Fight()
    local rotation = Args(s, "rotation")
    rotation.text.set(nil, "actions=obliterate\nactions+=/frost_strik,if=runic_power>")
    eq((RH.db.profile.customAPLs.DEATHKNIGHT or {}).frost, nil, "not saved")
    truthy(rotation.text.get():find("frost_strik"), "draft kept in the editor")
    local result = rotation.result.name()
    truthy(result:find("Not saved: 2 problem"), "summary")
    truthy(result:find("line 2, col 11: unknown action 'frost_strik'"), "unknown action")
    truthy(result:find("line 2, col 38: if: expected a value"), "syntax error")
    eq(First(s), "icy_touch", "default rotation still active")
end)

test("a valid rotation is saved and used right away", function()
    local s, RH = Fight()
    local rotation = Args(s, "rotation")
    rotation.text.set(nil, "# just obliterate\nactions=obliterate")
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.frost, "# just obliterate\nactions=obliterate", "saved")
    truthy(rotation.result.name():find("Saved and active: 1 actions in 1 lists"), "result")
    eq(First(s), "obliterate", "custom rotation active")
    truthy(Options(s):RotationStatus("frost"):find("Frost %(custom%)"), "status")
    falsy(rotation.revert.disabled(), "revert enabled")
end)

test("revert, empty text and unchanged default all use the default", function()
    local s, RH = Fight()
    local rotation = Args(s, "rotation")
    rotation.text.set(nil, "actions=obliterate")
    rotation.revert.func()
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.frost, nil, "reverted")
    eq(First(s), "icy_touch", "default active")
    truthy(rotation.revert.disabled(), "nothing to revert")

    rotation.text.set(nil, "actions=obliterate")
    rotation.text.set(nil, "   \n")
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.frost, nil, "empty text reverts")

    local default = rotation.text.get()
    rotation.text.set(nil, default)
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.frost, nil, "the default's own text isn't stored")
end)

test("the option works in plain text; the editor widget does the escaping", function()
    local s, RH = Fight()
    local rotation = Args(s, "rotation")
    eq(rotation.text.dialogControl, "RotationHelper-APLEditor", "our editor")
    truthy(rotation.text.get():find("buff%.killing_machine%.up|runic_power"), "plain '|'")
    rotation.text.set(nil, "actions=obliterate,if=runes.frost=2|runes.unholy=2")
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.frost, "actions=obliterate,if=runes.frost=2|runes.unholy=2", "stored as given")
end)

test("a spec without a default can get a custom rotation", function()
    local s, RH = Fight()
    s.ns.APLs.DEATHKNIGHT.blood = nil -- as if Blood had no rotation
    s.talentTabs[1].talents[1][2] = 51
    s:FireEvent("PLAYER_TALENT_UPDATE")
    eq(First(s), nil, "blood: nothing")
    local rotation = Args(s, "rotation")
    eq(Options(s):EditSpec(), "blood", "editor follows the current spec")
    truthy(Options(s):RotationStatus("blood"):find("no rotation yet"), "status")
    rotation.text.set(nil, "actions=plague_strike\nactions+=/obliterate")
    eq(First(s), "plague_strike", "blood custom rotation")
end)

test("the spec picker edits other specs", function()
    local s, RH = Fight()
    local rotation = Args(s, "rotation")
    local specs = rotation.spec.values()
    eq(specs.blood .. "," .. specs.frost .. "," .. specs.unholy, "Blood,Frost,Unholy", "choices")
    rotation.spec.set(nil, "blood")
    rotation.text.set(nil, "actions=blood_strike")
    eq(RH.db.profile.customAPLs.DEATHKNIGHT.blood, "actions=blood_strike", "saved for blood")
    eq(First(s), "icy_touch", "frost rotation unchanged")
end)

test("a saved rotation that no longer compiles falls back to the default", function()
    local s, RH = Fight()
    RH.db.profile.customAPLs.DEATHKNIGHT = { frost = "actions=removed_ability" }
    s.ns.Recommender:Reset()
    s:ClearChat()
    eq(First(s), "icy_touch", "default used")
    truthy(s:ChatContains("using the default until it's fixed"), "warning")
    truthy(s:ChatContains("unknown action 'removed_ability'"), "error listed")
end)

test("custom rotations are per profile", function()
    local s, RH = Fight()
    Args(s, "rotation").text.set(nil, "actions=obliterate")
    eq(First(s), "obliterate", "custom")
    local original = RH.db:GetCurrentProfile()
    RH.db:SetProfile("Other")
    eq(First(s), "icy_touch", "new profile uses the default")
    RH.db:SetProfile(original)
    eq(First(s), "obliterate", "back to the custom one")
end)

test("profiles tab: new, switch, copy and delete work", function()
    local s, RH = newAddon()
    local profiles = Options(s):GetOptionsTable().args.profiles
    -- Calls an option the way AceConfigDialog does: method names on the group's handler.
    local function Set(key, value)
        local option = profiles.args[key]
        local info = { "profiles", key, handler = profiles.handler, option = option, options = profiles, arg = option.arg }
        local fn = option.set or profiles.set
        if type(fn) == "string" then return profiles.handler[fn](profiles.handler, info, value) end
        return fn(info, value)
    end
    eq(profiles.args.new.type, "input", "'New' is a text box: type a name, press Enter")
    Set("new", "Raid")
    eq(RH.db:GetCurrentProfile(), "Raid", "created and switched")
    RH.db.profile.display.scale = 1.7
    Set("choose", "Default")
    eq(RH.db.profile.display.scale, 1, "back on Default's settings")
    Set("copyfrom", "Raid")
    eq(RH.db.profile.display.scale, 1.7, "copied from Raid")
    Set("delete", "Raid")
    eq(table.concat(RH.db:GetProfiles(), ","), "Default", "deleted")
end)

test("/rh snapshot names the active rotation", function()
    local s = Fight()
    Args(s, "rotation").text.set(nil, "actions=obliterate")
    s:ClearChat()
    s:Slash("ACECONSOLE_RH", "snapshot")
    truthy(s:ChatContains("rotation: Frost %(custom%)"), "spec line")
end)

test("the rotation help speaks your class's language", function()
    local s = newAddon()
    local help = s.ns.Options.SyntaxHelp()
    truthy(help:find("runes.blood", 1, true), "Death Knight: runes")
    s = newAddon({ class = "MAGE" })
    help = s.ns.Options.SyntaxHelp()
    falsy(help:find("rune", 1, true), "Mage: no runes")
    truthy(help:find("mana(.pct", 1, true), "Mage: mana")
    truthy(help:find("buff.hot_streak.up", 1, true), "Mage: an example with a proc")
    s = newAddon({ class = "ROGUE" })
    truthy(s.ns.Options.SyntaxHelp():find("combo_points", 1, true), "Rogue: combo points")
end)
