-- Minimal WoW 3.3.5a API mock for running the addon offline under Lua 5.1.
-- Each call to Mock.NewSession() builds an isolated global environment, so
-- tests can load the addon several times (e.g. as different classes).

local Mock = {}

local ADDON_DIR = "RotationHelper"

-- Load order for the offline harness. AceGUI and AceConfigDialog draw
-- frames, so they're only syntax-checked; tests stub the dialog if needed.
local LIB_FILES = {
    "Libs/LibStub/LibStub.lua",
    "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "Libs/AceAddon-3.0/AceAddon-3.0.lua",
    "Libs/AceEvent-3.0/AceEvent-3.0.lua",
    "Libs/AceConsole-3.0/AceConsole-3.0.lua",
    "Libs/AceTimer-3.0/AceTimer-3.0.lua",
    "Libs/AceDB-3.0/AceDB-3.0.lua",
    "Libs/AceDBOptions-3.0/AceDBOptions-3.0.lua",
    "Libs/AceConfig-3.0/AceConfigRegistry-3.0/AceConfigRegistry-3.0.lua",
}

-- Addon files come from the TOC, so the harness can't drift from the game.
local function ReadToc(root)
    local files, meta = {}, {}
    for line in io.lines(root .. "/" .. ADDON_DIR .. "/" .. ADDON_DIR .. ".toc") do
        line = line:gsub("\r", "")
        local key, value = line:match("^##%s*([%w%-]+):%s*(.-)%s*$")
        if key then
            meta[key] = value
        elseif line:match("%.lua$") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files, meta
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
-- Methods shared by frames, textures and font strings.
local RegionMethods = {}

function RegionMethods:SetPoint(point, rel, relPoint, x, y)
    -- Normalize the short forms SetPoint("TOPLEFT", x, y) and SetPoint("CENTER").
    if type(rel) == "number" or rel == nil then
        rel, relPoint, x, y = self.parent, point, rel or 0, relPoint or 0
    end
    -- Like the client, setting a point that's already set moves it.
    for _, p in ipairs(self.points) do
        if p[1] == point then
            p[2], p[3], p[4], p[5] = rel, relPoint, x, y
            return
        end
    end
    self.points[#self.points + 1] = { point, rel, relPoint, x, y }
end
function RegionMethods:GetPoint(i)
    local p = self.points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
end
function RegionMethods:ClearAllPoints() for i = #self.points, 1, -1 do self.points[i] = nil end end
function RegionMethods:SetAllPoints(rel) self.points = { { "ALL", rel or self.parent } } end
function RegionMethods:SetWidth(w) self.width = w end
function RegionMethods:SetHeight(h) self.height = h end
function RegionMethods:GetWidth() return self.width or 0 end
function RegionMethods:GetHeight() return self.height or 0 end
function RegionMethods:Show()
    self.shown = true
    if self.scripts and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function RegionMethods:Hide()
    self.shown = false
    if self.scripts and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function RegionMethods:IsShown() return self.shown end
function RegionMethods:IsVisible()
    local r = self
    while r do
        if not r.shown then return false end
        r = r.parent
    end
    return true
end
function RegionMethods:SetAlpha(a) self.alpha = a end
function RegionMethods:GetAlpha() return self.alpha or 1 end
function RegionMethods:GetName() return self.name end
function RegionMethods:GetParent() return self.parent end
function RegionMethods:GetObjectType() return self.objectType end

local TextureMethods = setmetatable({}, { __index = RegionMethods })
TextureMethods.__index = TextureMethods
-- SetTexture(path) or SetTexture(r, g, b, a) for a solid color.
function TextureMethods:SetTexture(t, g, b, a)
    if type(t) == "number" then
        self.texture, self.color = nil, { t, g, b, a }
    else
        self.texture, self.color = t, nil
    end
end
function TextureMethods:GetTexture() return self.texture end
function TextureMethods:SetDesaturated(d) self.desaturated = d end
function TextureMethods:SetTexCoord(...) self.texCoord = { ... } end
function TextureMethods:SetVertexColor(r, g, b, a) self.vertexColor = { r, g, b, a } end
function TextureMethods:SetDrawLayer(layer) self.layer = layer end
function TextureMethods:SetBlendMode() end

local FontStringMethods = setmetatable({}, { __index = RegionMethods })
FontStringMethods.__index = FontStringMethods
function FontStringMethods:SetText(t) self.text = t end
function FontStringMethods:GetText() return self.text end
local DEFAULT_FONT = { "Fonts\\FRIZQT__.TTF", 12, "" }
function FontStringMethods:SetFont(...) self.font = { ... } end
function FontStringMethods:GetFont() return unpack(self.font or DEFAULT_FONT) end
function FontStringMethods:SetFontObject(f) self.fontObject = f end
function FontStringMethods:GetFontObject() return self.fontObject end
function FontStringMethods:SetTextColor(...) self.textColor = { ... } end
function FontStringMethods:GetTextColor()
    if self.textColor then return unpack(self.textColor) end
    return 1, 1, 1, 1
end
function FontStringMethods:SetJustifyH(j) self.justifyH = j end
function FontStringMethods:GetStringWidth()
    local plain = (self.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #plain * 6
end
function FontStringMethods:SetJustifyV(j) self.justifyV = j end
function FontStringMethods:SetShadowOffset() end

local function NewFrameFactory(session)
    local FrameMethods = setmetatable({}, { __index = RegionMethods })
    FrameMethods.__index = FrameMethods

    local function AddRegion(frame, region)
        frame.regions = frame.regions or {}
        frame.regions[#frame.regions + 1] = region
        if region.name then session.env[region.name] = region end
        return region
    end
    function FrameMethods:CreateTexture(name, layer)
        return AddRegion(self, setmetatable({ name = name, parent = self, layer = layer, points = {}, shown = true,
            objectType = "Texture" }, TextureMethods))
    end
    function FrameMethods:CreateFontString(name, layer, template)
        return AddRegion(self, setmetatable({ name = name, parent = self, layer = layer, template = template,
            points = {}, shown = true, objectType = "FontString" }, FontStringMethods))
    end
    function FrameMethods:GetRegions() return unpack(self.regions or {}) end
    function FrameMethods:SetBackdrop(b) self.backdrop = b end
    function FrameMethods:GetBackdrop() return self.backdrop end
    function FrameMethods:SetBackdropColor(...) self.backdropColor = { ... } end
    function FrameMethods:GetBackdropColor() return unpack(self.backdropColor or {}) end
    function FrameMethods:SetBackdropBorderColor(...) self.backdropBorderColor = { ... } end
    function FrameMethods:GetBackdropBorderColor() return unpack(self.backdropBorderColor or {}) end
    -- Font methods for edit boxes.
    function FrameMethods:SetFont(...) self.font = { ... } end
    function FrameMethods:GetFont() return unpack(self.font or DEFAULT_FONT) end
    function FrameMethods:GetFontObject() return self.fontObject end
    function FrameMethods:SetTextColor(...) self.textColor = { ... } end
    function FrameMethods:SetFontObject(f) self.fontObject = f end
    -- Sliders and buttons.
    function FrameMethods:SetThumbTexture(path)
        self.thumb = self.thumb or self:CreateTexture()
        self.thumb:SetTexture(path)
    end
    function FrameMethods:GetThumbTexture() return self.thumb end
    function FrameMethods:GetHighlightTexture() return self.highlightTexture end
    function FrameMethods:SetHighlightTexture(path)
        self.highlightTexture = self.highlightTexture or self:CreateTexture()
        self.highlightTexture:SetTexture(path)
    end
    function FrameMethods:SetNormalTexture() end
    function FrameMethods:RegisterForClicks(...) self.clicks = { ... } end
    function FrameMethods:SetPushedTexture() end
    function FrameMethods:GetFontString() return self.fontString end
    function FrameMethods:SetText(text) self.text = text end
    -- Edit boxes. Text is kept raw; the cursor is a raw position.
    function FrameMethods:GetText() return self.text or "" end
    function FrameMethods:SetText(text)
        self.text = text
        self.cursor = math.min(self.cursor or 0, #text)
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
    end
    function FrameMethods:SetMultiLine(m) self.multiLine = m end
    function FrameMethods:SetAutoFocus() end
    function FrameMethods:SetTextInsets() end
    function FrameMethods:SetMaxLetters() end
    function FrameMethods:GetCursorPosition() return self.cursor or 0 end
    function FrameMethods:SetCursorPosition(pos) self.cursor = pos end
    function FrameMethods:HighlightText() self.highlighted = true end
    function FrameMethods:SetFocus() self.focused = true end
    function FrameMethods:ClearFocus() self.focused = false end
    function FrameMethods:HasFocus() return self.focused end
    -- Typing: inserts at the cursor like the player would (user input).
    function FrameMethods:Insert(text)
        local current, pos = self.text or "", self.cursor or 0
        self.text = current:sub(1, pos) .. text .. current:sub(pos + 1)
        self.cursor = pos + #text
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, true) end
    end
    function FrameMethods:EnableMouseWheel() end
    function FrameMethods:SetScrollChild(child) self.scrollChild = child end
    function FrameMethods:GetVerticalScroll() return self.verticalScroll or 0 end
    function FrameMethods:SetVerticalScroll(v) self.verticalScroll = v end
    -- Buttons.
    function FrameMethods:Enable() self.disabled = false end
    function FrameMethods:Disable() self.disabled = true end
    function FrameMethods:IsEnabled() return not self.disabled end
    function FrameMethods:Raise() end
    -- Window behavior.
    function FrameMethods:SetResizable(r) self.resizable = r end
    function FrameMethods:SetMinResize(w, h) self.minResize = { w, h } end
    function FrameMethods:SetToplevel() end
    function FrameMethods:StartSizing() self.sizing = true end
    function FrameMethods:GetFrameStrata() return self.strata or "MEDIUM" end
    function FrameMethods:SetScale(s) self.scale = s end
    function FrameMethods:GetScale() return self.scale or 1 end
    function FrameMethods:EnableMouse(e) self.mouseEnabled = e and true or false end
    function FrameMethods:IsMouseEnabled() return self.mouseEnabled end
    function FrameMethods:SetMovable(m) self.movable = m end
    function FrameMethods:RegisterForDrag(...) self.dragButtons = { ... } end
    function FrameMethods:StartMoving() self.moving = true end
    function FrameMethods:StopMovingOrSizing() self.moving = false end
    function FrameMethods:SetFrameLevel(l) self.frameLevel = l end
    function FrameMethods:GetFrameLevel() return self.frameLevel or 1 end
    -- Scanning tooltips (GameTooltipTemplate): lines come from
    -- session.items[id].tooltip and are readable as <name>TextLeft<i>.
    function FrameMethods:SetOwner(owner, anchor) self.owner = owner end
    function FrameMethods:ClearLines() self.numLines = 0 end
    function FrameMethods:NumLines() return self.numLines or 0 end
    function FrameMethods:SetInventoryItem(unit, slot)
        local id = session.env.GetInventoryItemID(unit, slot)
        local item = id and session.items[id]
        local lines = item and (item.tooltip or { item[1] }) or {}
        self.numLines = #lines
        for i, line in ipairs(lines) do
            session.env[self.name .. "TextLeft" .. i] = { GetText = function() return line end }
        end
    end
    -- Cooldown frames
    function FrameMethods:SetCooldown(start, duration) self.cooldownStart, self.cooldownDuration = start, duration end

    function FrameMethods:RegisterEvent(e) self.events[e] = true end
    function FrameMethods:UnregisterEvent(e) self.events[e] = nil end
    function FrameMethods:UnregisterAllEvents() self.events = {} end
    function FrameMethods:IsEventRegistered(e) return self.events[e] or false end
    function FrameMethods:SetScript(name, fn) self.scripts[name] = fn end
    function FrameMethods:GetScript(name) return self.scripts[name] end
    function FrameMethods:HookScript(name, fn)
        local old = self.scripts[name]
        self.scripts[name] = function(...)
            if old then old(...) end
            fn(...)
        end
    end
    function FrameMethods:SetAttribute(name, value)
        self.attributes = self.attributes or {}
        self.attributes[name] = value
    end
    function FrameMethods:GetAttribute(name) return self.attributes and self.attributes[name] end
    function FrameMethods:SetClampedToScreen() end
    function FrameMethods:SetFrameStrata(strata) self.strata = strata end
    function FrameMethods:SetParent(p) self.parent = p end

    return function(frameType, name, parent, template)
        local f = setmetatable({
            frameType = frameType, name = name, parent = parent, template = template,
            events = {}, scripts = {}, points = {}, shown = true,
        }, FrameMethods)
        session.frames[#session.frames + 1] = f
        if name then session.env[name] = f end
        return f
    end
end

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------
function Mock.NewSession(opts)
    opts = opts or {}
    local root = opts.root or "."
    local session = { frames = {}, chat = {}, time = 1000, class = opts.class or "DEATHKNIGHT" }

    local env = {}
    setmetatable(env, { __index = _G }) -- standard Lua library
    env._G = env
    session.env = env

    -- WoW's global string/table aliases
    env.strfind, env.strsub, env.strmatch, env.gsub = string.find, string.sub, string.match, string.gsub
    env.strlower, env.strupper, env.strlen, env.strrep = string.lower, string.upper, string.len, string.rep
    env.strbyte, env.strchar, env.format, env.gmatch = string.byte, string.char, string.format, string.gmatch
    env.strtrim = function(s, chars)
        chars = chars and ("[" .. chars .. "]") or "%s"
        return (s:gsub("^" .. chars .. "+", ""):gsub(chars .. "+$", ""))
    end
    env.strsplit = function(sep, s, limit)
        local out, pos, n = {}, 1, 0
        while true do
            n = n + 1
            if limit and n >= limit then out[#out + 1] = s:sub(pos); break end
            local a, b = s:find(sep, pos, true)
            if not a then out[#out + 1] = s:sub(pos); break end
            out[#out + 1] = s:sub(pos, a - 1)
            pos = b + 1
        end
        return unpack(out)
    end
    env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
    env.tinsert, env.tremove, env.tconcat, env.sort = table.insert, table.remove, table.concat, table.sort
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.table = setmetatable({ wipe = env.wipe }, { __index = table })
    env.floor, env.ceil, env.abs, env.max, env.min = math.floor, math.ceil, math.abs, math.max, math.min
    env.mod = math.fmod

    -- WoW's bit library (Lua 5.1 has none).
    env.bit = {
        band = function(a, b)
            local result, bitValue = 0, 1
            while a > 0 and b > 0 do
                local ra, rb = a % 2, b % 2
                if ra == 1 and rb == 1 then result = result + bitValue end
                a, b, bitValue = (a - ra) / 2, (b - rb) / 2, bitValue * 2
            end
            return result
        end,
    }

    -- Errors inside Ace callbacks (module OnEnable, messages) go through
    -- this handler; raising from it would be swallowed by xpcall, so they
    -- are recorded and printed instead (testlib fails a load that had any).
    session.luaErrors = {}
    env.geterrorhandler = function()
        return function(err)
            session.luaErrors[#session.luaErrors + 1] = tostring(err)
            print("  LUA ERROR  " .. tostring(err))
            return err
        end
    end
    env.seterrorhandler = function() end
    env.debugstack = function() return debug.traceback() end
    env.issecurevariable = function() return true end
    env.hooksecurefunc = function(tbl, name, fn)
        if type(tbl) == "string" then tbl, name, fn = env, tbl, name end
        local old = tbl[name]
        tbl[name] = function(...) local r = { old(...) }; fn(...); return unpack(r) end
    end

    -- Chat output
    local function capture(msg) session.chat[#session.chat + 1] = tostring(msg) end
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        capture(table.concat(parts, " "))
    end
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) capture(msg) end }
    env.SlashCmdList = {}
    env.hash_SlashCmdList = {}

    -- Game state
    env.GetTime = function() return session.time end
    env.GetLocale = function() return "enUS" end
    env.GetRealmName = function() return "Whitemane" end
    env.UnitName = function() return "Tester" end
    env.UnitClass = function() return session.class:sub(1, 1) .. session.class:sub(2):lower(), session.class end
    env.UnitRace = function() return "Human", "Human" end
    env.UnitFactionGroup = function() return "Alliance", "Alliance" end
    env.IsLoggedIn = function() return session.loggedIn end
    env.InCombatLockdown = function() return session.inCombat or false end
    env.GetCurrentRegion = nil

    -- Spells: id -> { name, icon }. Tests may add more via session.spells.
    session.spells = {
        [51425] = { "Obliterate", "Interface\\Icons\\Spell_DeathKnight_ClassIcon" },
        [55268] = { "Frost Strike", "Interface\\Icons\\Spell_DeathKnight_EmpowerRuneBlade2" },
        [51411] = { "Howling Blast", "Interface\\Icons\\Spell_Frost_ArcticWinds" },
        [49909] = { "Icy Touch", "Interface\\Icons\\Spell_DeathKnight_IceTouch" },
        [49921] = { "Plague Strike", "Interface\\Icons\\Spell_DeathKnight_EmpowerRuneBlade" },
        [57623] = { "Horn of Winter", "Interface\\Icons\\INV_Misc_Horn_02" },
        [57330] = { "Horn of Winter", "Interface\\Icons\\INV_Misc_Horn_02" },
        [49930] = { "Blood Strike", "i" }, [50842] = { "Pestilence", "i" }, [49941] = { "Blood Boil", "i" },
        [49938] = { "Death and Decay", "i" }, [49895] = { "Death Coil", "i" }, [49924] = { "Death Strike", "i" },
        [45529] = { "Blood Tap", "i" }, [51271] = { "Unbreakable Armor", "i" },
        [47568] = { "Empower Rune Weapon", "i" }, [49796] = { "Deathchill", "i" },
        [42650] = { "Army of the Dead", "i" }, [46584] = { "Raise Dead", "i" }, [47528] = { "Mind Freeze", "i" },
        [55095] = { "Frost Fever", "i" }, [55078] = { "Blood Plague", "i" }, [51124] = { "Killing Machine", "i" },
        [59052] = { "Freezing Fog", "i" }, [48266] = { "Blood Presence", "i" }, [48263] = { "Frost Presence", "i" },
        [48265] = { "Unholy Presence", "i" }, [2825] = { "Bloodlust", "i" }, [32182] = { "Heroism", "i" },
        [55271] = { "Scourge Strike", "i" }, [63560] = { "Ghoul Frenzy", "i" },
        [49206] = { "Summon Gargoyle", "i" }, [49222] = { "Bone Shield", "i" }, [66803] = { "Desolation", "i" },
        [20572] = { "Blood Fury", "i" }, [26297] = { "Berserking", "i" }, [50613] = { "Arcane Torrent", "i" },
        [53908] = { "Speed", "i" },
        -- Paladin
        [35395] = { "Crusader Strike", "i" }, [53385] = { "Divine Storm", "i" }, [20271] = { "Judgement of Light", "i" },
        [53408] = { "Judgement of Wisdom", "i" }, [53407] = { "Judgement of Justice", "i" }, [48819] = { "Consecration", "i" },
        [48801] = { "Exorcism", "i" }, [48806] = { "Hammer of Wrath", "i" }, [48817] = { "Holy Wrath", "i" },
        [31884] = { "Avenging Wrath", "i" }, [54428] = { "Divine Plea", "i" }, [31801] = { "Seal of Vengeance", "i" },
        [53736] = { "Seal of Corruption", "i" }, [20375] = { "Seal of Command", "i" }, [21084] = { "Seal of Righteousness", "i" },
        [20165] = { "Seal of Light", "i" }, [20166] = { "Seal of Wisdom", "i" }, [20164] = { "Seal of Justice", "i" },
        [59578] = { "The Art of War", "i" }, [53489] = { "The Art of War", "i" }, [19740] = { "Blessing of Might", "i" },
        -- Warrior
        [23881] = { "Bloodthirst", "i" }, [1680] = { "Whirlwind", "i" }, [47475] = { "Slam", "i" }, [47471] = { "Execute", "i" },
        [47450] = { "Heroic Strike", "i" }, [47520] = { "Cleave", "i" }, [47436] = { "Battle Shout", "i" },
        [47440] = { "Commanding Shout", "i" }, [2687] = { "Bloodrage", "i" }, [18499] = { "Berserker Rage", "i" },
        [12292] = { "Death Wish", "i" }, [1719] = { "Recklessness", "i" }, [6552] = { "Pummel", "i" },
        [34428] = { "Victory Rush", "i" }, [1715] = { "Hamstring", "i" }, [46916] = { "Slam!", "i" },
        [48932] = { "Blessing of Might", "i" }, [48934] = { "Greater Blessing of Might", "i" },
        [47486] = { "Mortal Strike", "i" }, [47465] = { "Rend", "i" }, [7384] = { "Overpower", "i" },
        [46924] = { "Bladestorm", "i" }, [12328] = { "Sweeping Strikes", "i" }, [60503] = { "Taste for Blood", "i" },
        [52437] = { "Sudden Death", "i" },
        -- Shaman
        [17364] = { "Stormstrike", "i" }, [60103] = { "Lava Lash", "i" }, [49231] = { "Earth Shock", "i" },
        [49233] = { "Flame Shock", "i" }, [49236] = { "Frost Shock", "i" }, [49238] = { "Lightning Bolt", "i" },
        [49271] = { "Chain Lightning", "i" }, [61657] = { "Fire Nova", "i" }, [58734] = { "Magma Totem", "i" },
        [58704] = { "Searing Totem", "i" }, [49281] = { "Lightning Shield", "i" }, [324] = { "Lightning Shield", "i" },
        [51533] = { "Feral Spirit", "i" }, [30823] = { "Shamanistic Rage", "i" }, [57994] = { "Wind Shear", "i" },
        [53817] = { "Maelstrom Weapon", "i" },
        [49276] = { "Lesser Healing Wave", "i" }, [60043] = { "Lava Burst", "i" }, [59159] = { "Thunderstorm", "i" },
        [16166] = { "Elemental Mastery", "i" }, [57722] = { "Totem of Wrath", "i" }, [2894] = { "Fire Elemental Totem", "i" },
        [57960] = { "Water Shield", "i" },
        -- Druid
        [48461] = { "Wrath", "i" }, [48465] = { "Starfire", "i" }, [48463] = { "Moonfire", "i" },
        [48468] = { "Insect Swarm", "i" }, [770] = { "Faerie Fire", "i" }, [16857] = { "Faerie Fire (Feral)", "i" },
        [53201] = { "Starfall", "i" }, [33831] = { "Force of Nature", "i" }, [48467] = { "Hurricane", "i" },
        [24858] = { "Moonkin Form", "i" }, [53308] = { "Entangling Roots", "i" }, [48518] = { "Eclipse (Lunar)", "i" },
        [48517] = { "Eclipse (Solar)", "i" }, [1126] = { "Mark of the Wild", "i" },
        -- Rogue
        [48638] = { "Sinister Strike", "i" }, [6774] = { "Slice and Dice", "i" }, [48672] = { "Rupture", "i" },
        [48668] = { "Eviscerate", "i" }, [51690] = { "Killing Spree", "i" }, [13750] = { "Adrenaline Rush", "i" },
        [13877] = { "Blade Flurry", "i" }, [1766] = { "Kick", "i" }, [1752] = { "Sinister Strike", "i" },
        [48666] = { "Mutilate", "i" }, [57993] = { "Envenom", "i" }, [51662] = { "Hunger for Blood", "i" },
        [63848] = { "Hunger For Blood", "i" }, [14177] = { "Cold Blood", "i" }, [57970] = { "Deadly Poison", "i" },
        [43104] = { "Deep Wounds", "i" }, [48676] = { "Garrote", "i" }, [48574] = { "Rake", "i" }, [49800] = { "Rip", "i" },
        [48568] = { "Lacerate", "i" },
        [26889] = { "Vanish", "i" }, [58427] = { "Overkill", "i" }, [1784] = { "Stealth", "i" },
        [48660] = { "Hemorrhage", "i" }, [48657] = { "Backstab", "i" }, [48691] = { "Ambush", "i" },
        [14183] = { "Premeditation", "i" }, [51713] = { "Shadow Dance", "i" },
        [768] = { "Cat Form", "i" }, [48566] = { "Mangle (Cat)", "i" }, [48564] = { "Mangle (Bear)", "i" },
        [46857] = { "Trauma", "i" }, [48572] = { "Shred", "i" }, [52610] = { "Savage Roar", "i" },
        [48577] = { "Ferocious Bite", "i" }, [50213] = { "Tiger's Fury", "i" }, [50334] = { "Berserk", "i" },
        [62078] = { "Swipe (Cat)", "i" }, [9634] = { "Dire Bear Form", "i" }, [5487] = { "Bear Form", "i" },
        [48564] = { "Mangle (Bear)", "i" }, [48568] = { "Lacerate", "i" }, [48562] = { "Swipe (Bear)", "i" },
        [48480] = { "Maul", "i" }, [48560] = { "Demoralizing Roar", "i" }, [47437] = { "Demoralizing Shout", "i" },
        [5229] = { "Enrage", "i" }, [61336] = { "Survival Instincts", "i" }, [22812] = { "Barkskin", "i" },
        [22842] = { "Frenzied Regeneration", "i" },
        [16870] = { "Clearcasting", "i" },
        -- Hunter
        [49052] = { "Steady Shot", "i" }, [49045] = { "Arcane Shot", "i" }, [53209] = { "Chimera Shot", "i" },
        [49050] = { "Aimed Shot", "i" }, [49048] = { "Multi-Shot", "i" }, [49001] = { "Serpent Sting", "i" },
        [61006] = { "Kill Shot", "i" }, [53338] = { "Hunter's Mark", "i" }, [34490] = { "Silencing Shot", "i" },
        [3045] = { "Rapid Fire", "i" }, [23989] = { "Readiness", "i" }, [34026] = { "Kill Command", "i" },
        [61847] = { "Aspect of the Dragonhawk", "i" }, [34074] = { "Aspect of the Viper", "i" }, [75] = { "Auto Shot", "i" },
        [1130] = { "Hunter's Mark", "i" },
        [60053] = { "Explosive Shot", "i" }, [63672] = { "Black Arrow", "i" }, [56453] = { "Lock and Load", "i" },
        [19574] = { "Bestial Wrath", "i" }, [34471] = { "The Beast Within", "i" },
        -- Priest
        [48160] = { "Vampiric Touch", "i" }, [48125] = { "Shadow Word: Pain", "i" }, [48300] = { "Devouring Plague", "i" },
        [48127] = { "Mind Blast", "i" }, [48156] = { "Mind Flay", "i" }, [53023] = { "Mind Sear", "i" },
        [48158] = { "Shadow Word: Death", "i" }, [34433] = { "Shadowfiend", "i" }, [47585] = { "Dispersion", "i" },
        [15473] = { "Shadowform", "i" }, [48168] = { "Inner Fire", "i" }, [15286] = { "Vampiric Embrace", "i" },
        [15487] = { "Silence", "i" }, [15258] = { "Shadow Weaving", "i" }, [1243] = { "Power Word: Fortitude", "i" },
        -- Mage
        [42833] = { "Fireball", "i" }, [42891] = { "Pyroblast", "i" }, [55360] = { "Living Bomb", "i" },
        [42859] = { "Scorch", "i" }, [42873] = { "Fire Blast", "i" }, [42926] = { "Flamestrike", "i" },
        [11129] = { "Combustion", "i" }, [55342] = { "Mirror Image", "i" }, [12051] = { "Evocation", "i" },
        [43046] = { "Molten Armor", "i" }, [2139] = { "Counterspell", "i" }, [48108] = { "Hot Streak", "i" },
        [22959] = { "Improved Scorch", "i" }, [12579] = { "Winter's Chill", "i" }, [17800] = { "Shadow Mastery", "i" },
        [1459] = { "Arcane Intellect", "i" },
        [42897] = { "Arcane Blast", "i" }, [36032] = { "Arcane Blast", "i" }, [42846] = { "Arcane Missiles", "i" },
        [44401] = { "Missile Barrage", "i" }, [44781] = { "Arcane Barrage", "i" }, [12042] = { "Arcane Power", "i" },
        [12043] = { "Presence of Mind", "i" },
        [42842] = { "Frostbolt", "i" }, [47610] = { "Frostfire Bolt", "i" }, [42914] = { "Ice Lance", "i" },
        [44572] = { "Deep Freeze", "i" }, [74396] = { "Fingers of Frost", "i" }, [57761] = { "Fireball!", "i" },
        [12472] = { "Icy Veins", "i" }, [11958] = { "Cold Snap", "i" }, [31687] = { "Summon Water Elemental", "i" },
        -- Warlock
        [59164] = { "Haunt", "i" }, [47813] = { "Corruption", "i" }, [47843] = { "Unstable Affliction", "i" },
        [47864] = { "Curse of Agony", "i" }, [47865] = { "Curse of the Elements", "i" }, [47809] = { "Shadow Bolt", "i" },
        [47855] = { "Drain Soul", "i" }, [47836] = { "Seed of Corruption", "i" }, [47815] = { "Searing Pain", "i" },
        [57946] = { "Life Tap", "i" }, [47893] = { "Fel Armor", "i" }, [687] = { "Demon Skin", "i" },
        [60433] = { "Earth and Moon", "i" }, [51735] = { "Ebon Plague", "i" },
        [47811] = { "Immolate", "i" }, [17962] = { "Conflagrate", "i" }, [59172] = { "Chaos Bolt", "i" },
        [47838] = { "Incinerate", "i" }, [47867] = { "Curse of Doom", "i" }, [54277] = { "Backdraft", "i" },
        [47241] = { "Metamorphosis", "i" }, [50589] = { "Immolation Aura", "i" }, [47825] = { "Soul Fire", "i" },
        [63167] = { "Decimation", "i" }, [71165] = { "Molten Core", "i" }, [47193] = { "Demonic Empowerment", "i" },
        [55262] = { "Heart Strike", "i" }, [56815] = { "Rune Strike", "i" }, [49028] = { "Dancing Rune Weapon", "i" },
        [49016] = { "Hysteria", "i" }, [48982] = { "Rune Tap", "i" }, [55233] = { "Vampiric Blood", "i" },
        -- glyph spells
        [58647] = { "Glyph of Frost Strike", "i" }, [58671] = { "Glyph of Obliterate", "i" },
    }
    -- Like the real client, a lookup by name only finds spells in the spellbook.
    session.known = {}
    session.spellCosts = {} -- name -> mana cost reported for a learned spell
    session.castTimes = {} -- name -> cast time in ms reported for a learned spell (hasted)
    env.GetSpellInfo = function(idOrName)
        if type(idOrName) == "string" then
            if session.known[idOrName] then
                return idOrName, "", "i", session.spellCosts[idOrName] or 0, nil, 0, session.castTimes[idOrName] or 0
            end
            return nil
        end
        local s = session.spells[idOrName]
        if s then return s[1], "", s[2] end
    end

    -- Action bars: slot -> { type, id, subType, spellId }; bindings: command -> key.
    session.actions, session.bindings, session.macros = {}, {}, {}
    env.GetActionInfo = function(slot)
        local a = session.actions[slot]
        if a then return a[1], a[2], a[3], a[4] end
    end
    env.GetBindingKey = function(command) return session.bindings[command] end
    -- Bindings in a stable (sorted) order.
    local function SortedCommands()
        local commands = {}
        for command in pairs(session.bindings) do commands[#commands + 1] = command end
        table.sort(commands)
        return commands
    end
    env.GetNumBindings = function() return #SortedCommands() end
    env.GetBinding = function(i)
        local command = SortedCommands()[i]
        return command, session.bindings[command]
    end
    env.GetMacroSpell = function(id) return session.macros[id] end
    env.GetSpellName = function() return nil end

    -- Target and range: session.range[spellName] = 0 marks it out of range.
    session.hasTarget, session.range = false, {}
    session.target = { name = "Training Dummy", guid = "0xF130000001", health = 100, healthMax = 100,
        level = -1, canAttack = true, dead = false, classification = "worldboss" }
    session.petAlive = false
    session.bossFrames = false -- boss1 exists (boss unit frames up)
    env.UnitExists = function(unit)
        if unit == "pet" then return session.petAlive end
        if unit == "boss1" then return session.bossFrames end
        return unit == "target" and session.hasTarget
    end
    env.IsSpellInRange = function(name) return session.range[name] or 1 end
    env.UnitGUID = function(unit)
        if unit == "player" then return Mock.PLAYER_GUID end
        return unit == "target" and session.hasTarget and session.target.guid or nil
    end
    local baseUnitName = env.UnitName
    env.UnitName = function(unit)
        if unit == "target" then return session.hasTarget and session.target.name or nil end
        return baseUnitName(unit)
    end
    env.UnitCanAttack = function(_, unit) return unit == "target" and session.hasTarget and session.target.canAttack end
    env.UnitIsDead = function(unit) return unit == "target" and session.hasTarget and session.target.dead end
    -- Group and threat: session.party / session.raid = member counts;
    -- session.threat = { isTanking, scaledPercent } on the target.
    session.party, session.raid = 0, 0
    env.GetNumPartyMembers = function() return session.party end
    session.guild = false
    env.IsInGuild = function() return session.guild end
    env.GetNumRaidMembers = function() return session.raid end
    env.UnitDetailedThreatSituation = function(unit, target)
        local t = session.threat
        if not t or target ~= "target" or not session.hasTarget then return nil end
        return t.isTanking, t.isTanking and 3 or 1, t.scaledPercent, t.scaledPercent, 1000
    end
    -- session.player = { health, healthMax }
    session.player = { health = 20000, healthMax = 20000 }
    env.UnitHealth = function(unit)
        if unit == "player" then return session.player.health end
        return unit == "target" and session.target.health or 0
    end
    env.UnitHealthMax = function(unit)
        if unit == "player" then return session.player.healthMax end
        return unit == "target" and session.target.healthMax or 0
    end
    -- Reactive spells (Rune Strike): session.usable[name] = true after a
    -- dodge or parry; session.current[name] = true while queued for the next swing.
    session.usable, session.current = {}, {}
    env.IsUsableSpell = function(name) return session.usable[name] or false, false end
    env.IsCurrentSpell = function(name) return session.current[name] or false end
    env.UnitLevel = function(unit) return unit == "target" and session.target.level or 80 end
    -- Totems: session.totems[slot] = { name, start, duration } (1 fire, 2 earth, 3 water, 4 air).
    session.totems = {}
    env.GetTotemInfo = function(slot)
        local t = session.totems[slot]
        if not t then return false, "", 0, 0, nil end
        return true, t[1], t[2], t[3], "i"
    end
    -- Temporary weapon enchants (Shaman imbues): session.imbues = { main = bool, off = bool }.
    session.imbues, session.offhandWeapon = { main = false, off = false }, false
    env.GetWeaponEnchantInfo = function()
        return session.imbues.main, 1800000, 0, session.imbues.off, 1800000, 0
    end
    env.OffhandHasWeapon = function() return session.offhandWeapon end
    session.rangedSpeed = 2.4 -- UnitRangedDamage("player")
    env.UnitRangedDamage = function() return session.rangedSpeed, 1000, 1200 end
    session.combo = 0 -- GetComboPoints("player", "target")
    env.GetComboPoints = function() return session.combo end
    session.form = 0 -- GetShapeshiftForm (warrior stance)
    env.GetShapeshiftForm = function() return session.form end
    env.UnitCreatureType = function(unit) return unit == "target" and session.target.creatureType or nil end
    env.UnitClassification = function(unit) return unit == "target" and session.target.classification or "normal" end
    -- The target's cast/channel: session.targetCast / targetChannel =
    -- { name, endsIn = seconds, notInterruptible }. The player never casts here.
    -- The player's cast: session.playerCast = { name, startedAgo, endsIn, icon }.
    env.UnitCastingInfo = function(unit)
        local c = unit == "target" and session.targetCast or unit == "player" and session.playerCast
        if not c then return nil end
        return c.name, "", c.name, c.icon or "icon", (session.time - (c.startedAgo or 0)) * 1000,
            (session.time + c.endsIn) * 1000, false, 1, c.notInterruptible
    end
    -- The player's channel: session.playerChannel = { name, startedAgo, endsIn }.
    env.UnitChannelInfo = function(unit)
        local c = unit == "target" and session.targetChannel or unit == "player" and session.playerChannel
        if not c then return nil end
        return c.name, "", c.name, c.icon or "icon", (session.time - (c.startedAgo or 0)) * 1000,
            (session.time + c.endsIn) * 1000, false, c.notInterruptible
    end
    env.GetUnitSpeed = function() return session.speed or 0 end

    -- Power: runic power by default.
    session.power = { type = 6, current = 0, max = 130 }
    env.UnitPowerType = function() return session.power.type end
    env.UnitPower = function() return session.power.current end
    env.UnitPowerMax = function() return session.power.max end

    -- Runes: slots 1-2 blood, 3-4 unholy, 5-6 frost, all ready.
    -- Set session.runes[i].readyAt to make a rune recharge.
    session.runes = {}
    for i, t in ipairs({ 1, 1, 2, 2, 3, 3 }) do session.runes[i] = { type = t } end
    session.runeRegen = 10
    env.GetRuneType = function(i) return session.runes[i].type end
    env.GetRuneCooldown = function(i)
        local r = session.runes[i]
        if r.readyAt and r.readyAt > session.time then
            return r.readyAt - session.runeRegen, session.runeRegen, false
        end
        return 0, 0, true
    end

    -- Auras: session.auras.player / .target = list of
    -- { name, spellId, count, duration, expires, caster, harmful }
    session.auras = { player = {}, target = {} }
    env.UnitAura = function(unit, index, filter)
        local wantHarmful = filter and filter:find("HARMFUL") ~= nil
        local n = 0
        for _, a in ipairs(session.auras[unit] or {}) do
            if (a.harmful or false) == wantHarmful then
                n = n + 1
                if n == index then
                    return a.name, "", "icon", a.count or 0, nil, a.duration or 0, a.expires or 0,
                        a.caster or "player", nil, nil, a.spellId
                end
            end
        end
    end

    -- Cooldowns by spell name: session.cooldowns[name] = { start, duration }
    session.cooldowns = {}
    env.GetSpellCooldown = function(name)
        local c = session.cooldowns[name]
        if c then return c[1], c[2], 1 end
        return 0, 0, 1
    end


    -- Items: session.items[itemID] = { name, icon, useSpell }; session.equipped[slot] = itemID;
    -- session.bags[itemID] = count; session.itemCooldowns[itemID] = { start, duration, enabled }.
    session.items = {
        [40211] = { "Potion of Speed", "Interface\Icons\INV_Alchemy_Elixir_04", "Speed" },
        [40093] = { "Indestructible Potion", "i", "Indestructible" },
    }
    session.equipped, session.bags, session.itemCooldowns = {}, {}, {}
    env.GetInventoryItemID = function(unit, slot) return unit == "player" and session.equipped[slot] or nil end
    env.GetInventoryItemTexture = function(unit, slot)
        local item = session.items[env.GetInventoryItemID(unit, slot) or 0]
        return item and item[2] or nil
    end
    env.GetItemSpell = function(id)
        local item = session.items[id]
        if item and item[3] then return item[3], id end
    end
    env.GetItemInfo = function(id)
        if type(id) == "string" then
            for itemID, item in pairs(session.items) do if item[1] == id then id = itemID end end
        end
        local item = session.items[id]
        if item then return item[1], "item:" .. id, 4, 80, 80, "Miscellaneous", "Junk", 1, "", item[2] end
    end
    env.GetItemIcon = function(id) local item = session.items[id] return item and item[2] end
    env.GetItemCount = function(id) return session.bags[id] or 0 end
    env.GetItemCooldown = function(id)
        local c = session.itemCooldowns[id]
        if c then return c[1], c[2], c[3] or 1 end
        return 0, 0, 1
    end
    env.GetInventoryItemCooldown = function(unit, slot)
        local id = env.GetInventoryItemID(unit, slot)
        if not id then return 0, 0, 0 end
        if not env.GetItemSpell(id) then return 0, 0, 0 end
        return env.GetItemCooldown(id)
    end
    -- Talents: session.talentTabs = { { name = "Frost", talents = { { "Name", rank }, ... } }, ... }
    session.talentTabs = {
        { name = "Blood", talents = { { "Butchery", 0 }, { "Subversion", 3 } } },
        { name = "Frost", talents = { { "Blood of the North", 3 }, { "Killing Machine", 5 }, { "Chill of the Grave", 2 } } },
        { name = "Unholy", talents = { { "Epidemic", 2 } } },
    }
    session.talentGroup = 1
    env.GetActiveTalentGroup = function() return session.talentGroup end
    session.numTalentGroups = 2
    env.GetNumTalentGroups = function() return session.numTalentGroups end
    env.GetNumTalentTabs = function() return #session.talentTabs end
    env.GetTalentTabInfo = function(tab)
        local t = session.talentTabs[tab]
        local points = 0
        for _, talent in ipairs(t.talents) do points = points + talent[2] end
        return t.name, "icon", points, "bg"
    end
    env.GetNumTalents = function(tab) return #session.talentTabs[tab].talents end
    env.GetTalentInfo = function(tab, i)
        local talent = session.talentTabs[tab].talents[i]
        return talent[1], "icon", 1, 1, talent[2], 5
    end

    -- Glyphs: session.glyphs[socket] = glyph spell ID
    session.glyphs = {}
    env.GetGlyphSocketInfo = function(socket)
        local id = session.glyphs[socket]
        return id ~= nil, 1, id, "icon"
    end

    local _, tocMeta = ReadToc(root)
    env.GetAddOnMetadata = function(addon, field)
        if addon == ADDON_DIR then return tocMeta[field] end
    end
    env.GetAddOnInfo = function(addon) return addon, addon, "", true, true end
    env.debugprofilestop = function() return os.clock() * 1000 end
    env.UpdateAddOnMemoryUsage = function() end
    env.GetAddOnMemoryUsage = function() return session.memoryKB or 250 end
    env.UpdateAddOnCPUUsage = function() end
    env.GetAddOnCPUUsage = function() return session.cpuMs or 0 end
    session.cvars = { scriptProfile = "0" }
    session.latencyMs = 0
    env.GetNetStats = function() return 0, 0, session.latencyMs end
    env.GetCVar = function(name) return session.cvars[name] end
    env.IsAddOnLoaded = function(addon) return addon == ADDON_DIR end

    env.RAID_CLASS_COLORS = { DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 }, DRUID = { r = 1, g = 0.49, b = 0.04 },
        WARLOCK = { r = 0.58, g = 0.51, b = 0.79 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
    env.CreateFrame = NewFrameFactory(session)
    env.UIParent = env.CreateFrame("Frame", "UIParent")
    env.UISpecialFrames = {}

    -- Static popups and addon messages.
    env.StaticPopupDialogs = {}
    session.popups = {}
    env.StaticPopup_Show = function(which, text1, text2, data)
        session.popups[#session.popups + 1] = { which = which, text1 = text1, data = data }
    end
    session.addonMessages = {}
    env.SendAddonMessage = function(prefix, text, channel, target)
        session.addonMessages[#session.addonMessages + 1] = { prefix = prefix, text = text, channel = channel,
            target = target }
    end

    -- The minimap (centered at 500,500) and the cursor, for the minimap button.
    env.Minimap = env.CreateFrame("Frame", "Minimap")
    function env.Minimap:GetCenter() return 500, 500 end
    function env.Minimap:GetEffectiveScale() return 1 end
    session.cursor = { 500, 500 }
    env.GetCursorPosition = function() return session.cursor[1], session.cursor[2] end

    -- Keyboard, tooltip and sound.
    session.shift = false
    env.IsShiftKeyDown = function() return session.shift end
    session.sounds = {}
    env.PlaySound = function(name) session.sounds[#session.sounds + 1] = name end
    local tooltip = { lines = {}, shown = false }
    function tooltip:SetOwner(owner) self.owner, self.lines, self.link = owner, {}, nil end
    function tooltip:SetHyperlink(link) self.link = link end
    function tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown, self.owner = false, nil end
    function tooltip:IsOwned(frame) return self.owner == frame end
    function tooltip:Text() return table.concat(self.lines, "\n") end
    env.GameTooltip = tooltip
    env.HideUIPanel = function(frame) if frame then frame:Hide() end end

    session.toc = tocMeta
    return setmetatable(session, { __index = Mock })
end

function Mock:LoadFile(path, ...)
    local chunk, err = loadfile(path)
    if not chunk then error(err, 0) end
    setfenv(chunk, self.env)
    return chunk(...)
end

-- Loads libraries, then the addon's TOC files with the (name, namespace)
-- varargs the client passes, then fires ADDON_LOADED + PLAYER_LOGIN.
function Mock:LoadAddon()
    local root = "."
    for _, f in ipairs(LIB_FILES) do
        self:LoadFile(root .. "/" .. ADDON_DIR .. "/" .. f)
    end
    self.ns = {}
    local files = ReadToc(root)
    for _, f in ipairs(files) do
        self:LoadFile(root .. "/" .. ADDON_DIR .. "/" .. f, ADDON_DIR, self.ns)
    end
    self:FireEvent("ADDON_LOADED", ADDON_DIR)
    self.loggedIn = true
    self:FireEvent("PLAYER_LOGIN")
    self:FireEvent("PLAYER_ENTERING_WORLD")
    return self.env.RotationHelper
end

function Mock:FireEvent(event, ...)
    for _, f in ipairs(self.frames) do
        if f.events[event] and f.scripts.OnEvent then
            f.scripts.OnEvent(f, event, ...)
        end
    end
end

-- Advances time and runs every visible frame's OnUpdate once.
function Mock:Tick(dt)
    self.time = self.time + dt
    for _, f in ipairs(self.frames) do
        if f.shown and f.scripts.OnUpdate then
            f.scripts.OnUpdate(f, dt)
        end
    end
end

function Mock:Slash(cmd, msg)
    local handler = self.env.SlashCmdList[cmd]
    assert(handler, "no slash handler " .. cmd)
    handler(msg or "")
end

function Mock:ClearChat() self.chat = {} end

Mock.PLAYER_GUID = "0x0000000000000001"
-- Combat log unit flags: us (mine, friendly player), and a hostile NPC.
Mock.FLAGS_ME = 0x511
Mock.FLAGS_HOSTILE_NPC = 0xa48
Mock.FLAGS_FRIENDLY_NPC = 0xa18

-- Fires a combat log event with 3.3.5's argument layout.
function Mock:CombatLog(subevent, srcGUID, srcFlags, dstGUID, dstFlags)
    self:FireEvent("COMBAT_LOG_EVENT_UNFILTERED", self.time, subevent,
        srcGUID, "src", srcFlags, dstGUID, "dst", dstFlags, 49909, "Icy Touch", 16)
end

-- Adds an aura. unit is "player" or "target"; fields as in session.auras.
function Mock:AddAura(unit, aura)
    local list = self.auras[unit]
    list[#list + 1] = aura
end

-- Marks spells (by name) as in the spellbook and refreshes the Spec module.
function Mock:Learn(...)
    for i = 1, select("#", ...) do self.known[(select(i, ...))] = true end
    self:FireEvent("LEARNED_SPELL_IN_TAB")
end

-- Puts a spell on an action slot, optionally bound to a key.
function Mock:PlaceSpell(slot, spellId, command, key)
    self.actions[slot] = { "spell", slot, "spell", spellId }
    if command then self.bindings[command] = key end
    self:FireEvent("ACTIONBAR_SLOT_CHANGED", slot)
end

-- Matches `pattern` against chat lines with color codes removed.
function Mock:ChatContains(pattern)
    for _, line in ipairs(self.chat) do
        local plain = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if plain:find(pattern) then return true end
    end
    return false
end

return Mock
