local ADDON_NAME, ns = ...
local RH = ns.RH

-- The recommendation display, drawn like Hekili's: one icon for the next
-- action and a queue of predicted ones, each with its border, cooldown
-- swipe and keybind, and on the main icon the enemy count, the delay and
-- the proc glow.
--
-- It renders RH.recommendations, an array of entries set by the engine:
--   { name = "obliterate", spellId = 51425, wait = 0.4, lacksResources = false }
-- `wait` is seconds until the action is usable and drives the swipe on
-- the main icon (queued icons show their spell's real cooldown, GCD
-- included, as Hekili does).
--
-- The icon button (CreateButton / UpdateButton) is shared with the AoE,
-- interrupt and cooldown displays.
--
-- While you cast or channel (display.castSlot), the spell being cast gets
-- its own icon: it slides out beside the main icon and shrinks as the cast
-- progresses, gone when it lands. The main icon stays what to press next.
local Display = RH:NewModule("Display", "AceEvent-3.0")
ns.Display = Display

local GetSpellInfo, GetTime, UnitExists, IsSpellInRange = GetSpellInfo, GetTime, UnitExists, IsSpellInRange
local IsUsableSpell, IsCurrentSpell, GetSpellCooldown = IsUsableSpell, IsCurrentSpell, GetSpellCooldown
local PlaySound = PlaySound
local abs, max, min, floor = math.abs, math.max, math.min, math.floor

local MAX_ICONS = 5
local FLASH_DURATION = 0.3
local FLASH_ALPHA = 0.55
local WARN_PULSE_SPEED = 5 -- radians per second
local WHITE = "Interface\\Buttons\\WHITE8X8"
local HIGHLIGHT = "Interface\\Buttons\\ButtonHilight-Square"
local DELAY_DOT = "Interface\\FriendsFrame\\StatusIcon-Online"
local FONT = "Fonts\\ARIALN.TTF" -- Arial Narrow, Hekili's font on the icons
local BADGE_SCALE = 0.42 -- proc badge size relative to the icon
local STATUS_HEIGHT = 14
local CHIP_GAP = 6
local CAST_SLIDE = 0.2     -- seconds the cast icon takes to slide out of the main icon
local CAST_MIN_SCALE = 0.4 -- its size (relative to the main icon) when the cast lands
local CAST_MIN_ALPHA = 0.5

-- Sounds for a new proc (PlaySound names in the 3.3.5 client).
Display.PROC_SOUNDS = { none = "None", MapPing = "Ping", RaidWarning = "Raid warning", ReadyCheck = "Ready check" }
Display.DELAY_TYPES = { TEXT = "Seconds (top left)", ICON = "Colored dot (top left)", NONE = "None" }

local TINT_NORMAL = { 1, 1, 1 }

-- Color presets for the configurable colors (profile.display.colors).
-- The defaults are Hekili's: out of range is desaturated red, unusable
-- is dark grey. The color-blind friendly one uses the Okabe-Ito palette,
-- whose colors stay distinguishable with the common kinds of color blindness.
Display.COLOR_PRESETS = {
    default = {
        outOfRange = { 1, 0, 0 },
        noResources = { 0.4, 0.4, 0.4 },
        waste = { 1, 0.5, 0 },
        threat = { 0.9, 0.1, 0.1 },
    },
    colorblind = {
        outOfRange = { 0.84, 0.37, 0 },    -- vermillion
        noResources = { 0.34, 0.71, 0.91 }, -- sky blue
        waste = { 0.9, 0.62, 0 },          -- orange
        threat = { 0.8, 0.47, 0.65 },      -- reddish purple
    },
}

-- Layout presets: Hekili's stock look, and the compact one from the
-- user's own Hekili settings (32px main icon, 30px queue almost touching,
-- the AoE display to the right and only shown with 3+ enemies).
-- Applied with RH:ApplyPreset; everything stays editable afterwards.
Display.PRESETS = {
    hekili = {
        numIcons = 3, iconSize = 50, queueSize = 50, spacing = 5, direction = "RIGHT", scale = 1,
        point = { "CENTER", "UIParent", "CENTER", 0, -225 },
        aoeNumIcons = 3, aoeIconSize = 50, aoeQueueSize = 50, aoeScale = 1,
        aoePoint = { "CENTER", "UIParent", "CENTER", 0, -170 },
        interruptSize = 50, interruptPoint = { "CENTER", "UIParent", "CENTER", -55, -225 },
        cooldownSize = 50, cooldownPoint = { "CENTER", "UIParent", "CENTER", 0, -280 },
        dualDisplay = false, reactiveAoE = false,
    },
    grambam = {
        numIcons = 3, iconSize = 32, queueSize = 30, spacing = 1, direction = "RIGHT", scale = 1,
        point = { "CENTER", "UIParent", "CENTER", -25, -140 },
        aoeNumIcons = 3, aoeIconSize = 30, aoeQueueSize = 30, aoeScale = 1,
        aoePoint = { "CENTER", "UIParent", "CENTER", 91, -140 },
        interruptSize = 50, interruptPoint = { "CENTER", "UIParent", "CENTER", -149, -203 },
        cooldownSize = 50, cooldownPoint = { "CENTER", "UIParent", "CENTER", -89, -148 },
        dualDisplay = true, reactiveAoE = true,
    },
}
Display.PRESET_NAMES = { hekili = "Hekili (stock)", grambam = "Grambam (compact)" }

-- What the main icon waits on, when it's more than a GCD away (the
-- optional caption at the bottom of the icon).
local HOLD_LABELS = { runes = "RUNES", cooldown = "COOLDOWN", cast = "CAST", wait = "WAIT",
    rage = "RAGE", energy = "ENERGY", ["auto shot"] = "AUTO" }

-- An ability waiting for a buff that forbids it to end (Tiger's Fury during
-- Berserk): the buff's name, in capitals.
local function BlockedLabel(entry)
    local ability = RH.classData and RH.classData.abilities[entry.name]
    if not (ability and ability.blockedBy and entry.limitedBy == ability.blockedBy) then return nil end
    local aura = RH.classData.auras[ability.blockedBy]
    local name = aura and aura.id and GetSpellInfo(aura.id)
    return (name or ability.blockedBy:gsub("_", " ")):upper()
end

-- Where each queued icon goes relative to the previous one.
local GROW = {
    RIGHT = { "LEFT", "RIGHT", 1, 0 },
    LEFT = { "RIGHT", "LEFT", -1, 0 },
    UP = { "BOTTOM", "TOP", 0, 1 },
    DOWN = { "TOP", "BOTTOM", 0, -1 },
}

-- Sample icons (display unlocked or /rh test): the first abilities of your
-- spec's rotation, so every class sees its own spells. Rebuilt when the spec
-- or the settings change.
local preview, previewKey = {}, nil
local previewEntries = {} -- reused, so rebuilding creates no garbage

function Display:GetPreview()
    local key = tostring(RH.playerClass) .. ":" .. tostring(ns.Spec.key)
    if key == previewKey and preview[1] then return preview end
    previewKey = key
    for i = #preview, 1, -1 do preview[i] = nil end
    local abilities = RH.classData and RH.classData.abilities
    if not abilities then return preview end
    local function Add(name)
        local ability = abilities[name]
        if #preview >= MAX_ICONS or not (ability and ability.id) then return end
        for _, entry in ipairs(preview) do
            if entry.spellId == ability.id then return end
        end
        local i = #preview + 1
        local entry = previewEntries[i] or {}
        previewEntries[i] = entry
        entry.spellId, entry.wait = ability.id, i == 1 and 0 or nil
        preview[i] = entry
    end
    -- The main list first, then the others (not the out-of-combat one).
    -- (Only once the Recommender has started: before that it has no compiled rotations.)
    local apl = ns.Recommender and ns.Recommender.compiled and ns.Recommender:GetAPL()
    if apl then
        for _, action in ipairs(apl.lists.default or {}) do
            if action.kind == "ability" then Add(action.name) end
        end
        for _, name in ipairs(apl.listOrder) do
            if name ~= "default" and name ~= "precombat" then
                for _, action in ipairs(apl.lists[name]) do
                    if action.kind == "ability" then Add(action.name) end
                end
            end
        end
    end
    -- No rotation yet (talents not loaded, still starting up): any of the
    -- class's spells for now, and look again next time.
    if not preview[1] then
        for name in pairs(abilities) do Add(name) end
        previewKey = nil
    end
    return preview
end

local spellCache = {}

-- Item abilities (trinkets, potions): name and icon from the entry.
local itemCache = {}
local function ItemInfo(entry)
    local info = itemCache[entry.itemID]
    if not info then
        info = { name = entry.itemName, icon = entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark" }
        itemCache[entry.itemID] = info
    end
    return info
end

local function SpellInfo(spellId)
    local info = spellCache[spellId]
    if not info then
        local name, _, icon = GetSpellInfo(spellId)
        info = { name = name, icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark" }
        spellCache[spellId] = info
    end
    return info
end

---------------------------------------------------------------------------
-- The icon button (Hekili's button, part for part)
---------------------------------------------------------------------------
-- The icon fills the button; a border frame sits outside it, a frame
-- level below. The cooldown swipe covers the icon; the corner texts and
-- the proc badge sit on an overlay above the swipe:
--   top right      keybind
--   top left       delay (seconds until the engine says to press, when
--                  that's beyond the cooldown already shown)
--   bottom right   enemy count (main icon)
--   bottom         caption: what the icon waits on (optional)
-- Also used by the AoE, interrupt and cooldown displays.
function Display.CreateButton(parent, name)
    local b = CreateFrame("Frame", name, parent)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)

    -- Border, outside the icon and under it.
    local border = CreateFrame("Frame", nil, b)
    border:SetFrameLevel(max(0, b:GetFrameLevel() - 1))
    border:SetPoint("CENTER", b, "CENTER")
    border:Hide()
    b.border = border

    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b.icon)
    b.cooldown:SetFrameLevel(b:GetFrameLevel() + 1)
    if b.cooldown.SetDrawEdge then b.cooldown:SetDrawEdge(false) end
    if b.cooldown.SetDrawBling then b.cooldown:SetDrawBling(false) end
    b.cooldown:Hide()

    -- Texts sit above the cooldown swipe.
    b.overlay = CreateFrame("Frame", nil, b)
    b.overlay:SetAllPoints(b)
    b.overlay:SetFrameLevel(b.cooldown:GetFrameLevel() + 1)

    b.key = b.overlay:CreateFontString(nil, "OVERLAY")
    b.key:SetPoint("TOPRIGHT", b, "TOPRIGHT", 1, -1)
    b.key:SetJustifyH("RIGHT")
    b.key:SetJustifyV("TOP")
    b.key:SetTextColor(1, 1, 1)

    b.delay = b.overlay:CreateFontString(nil, "OVERLAY")
    b.delay:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.delay:SetJustifyH("LEFT")
    b.delay:SetJustifyV("TOP")
    b.delay:SetTextColor(1, 1, 1)

    b.delayIcon = b.overlay:CreateTexture(nil, "OVERLAY")
    b.delayIcon:SetTexture(DELAY_DOT)
    b.delayIcon:SetDesaturated(true)
    b.delayIcon:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.delayIcon:Hide()

    b.targets = b.overlay:CreateFontString(nil, "OVERLAY")
    b.targets:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    b.targets:SetJustifyH("RIGHT")
    b.targets:SetJustifyV("BOTTOM")
    b.targets:SetTextColor(1, 1, 1)

    -- Caption: what the main icon waits on (RUNES, COOLDOWN, ...), and the
    -- time left on the cast icon.
    b.hold = b.overlay:CreateFontString(nil, "OVERLAY")
    b.hold:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
    b.hold:SetJustifyH("CENTER")
    b.hold:SetJustifyV("BOTTOM")
    b.hold:SetTextColor(1, 1, 1)
    b.hold:Hide()

    -- The action button highlight, while the recommended spell is the one
    -- you're casting or have queued.
    b.highlight = b:CreateTexture(nil, "OVERLAY")
    b.highlight:SetTexture(HIGHLIGHT)
    b.highlight:SetAllPoints(b)
    b.highlight:SetBlendMode("ADD")
    b.highlight:Hide()

    -- "Press now" flash: brightens the icon briefly (additive white).
    b.flash = b.overlay:CreateTexture(nil, "OVERLAY")
    b.flash:SetAllPoints(b.icon)
    b.flash:SetTexture(1, 1, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:Hide()

    -- Proc badge: the proc's icon in the bottom-right corner when the proc
    -- is why this ability is recommended.
    local badge = CreateFrame("Frame", nil, b.overlay)
    badge:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    badge:SetBackdrop({ bgFile = WHITE })
    badge:SetBackdropColor(0, 0, 0, 1)
    badge.icon = badge:CreateTexture(nil, "ARTWORK")
    badge.icon:SetPoint("TOPLEFT", 1, -1)
    badge.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    badge.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    badge:Hide()
    b.badge = badge

    b:Hide()
    return b
end

function Display.SetButtonSize(b, size)
    b.size = size
    b:SetWidth(size)
    b:SetHeight(size)
    b.badge:SetWidth(size * BADGE_SCALE)
    b.badge:SetHeight(size * BADGE_SCALE)
    local dot = min(20, max(10, size / 3))
    b.delayIcon:SetWidth(dot)
    b.delayIcon:SetHeight(dot)
    local thickness = b.borderThickness or 0
    b.border:SetWidth(size + 2 * thickness)
    b.border:SetHeight(size + 2 * thickness)
end

-- Applies the look settings to a button: the border, the icon zoom and
-- the fonts. `d` is the display profile.
function Display.StyleButton(b, d)
    local thickness = d.border or 0
    b.borderThickness = thickness
    if thickness > 0 then
        b.border:SetBackdrop({ edgeFile = WHITE, edgeSize = thickness,
            insets = { left = -1, right = -1, top = -1, bottom = -1 } })
        if d.borderClassColor then
            local r, g, bl = ns.Mover.ClassColor()
            b.border:SetBackdropBorderColor(r, g, bl, 1)
        else
            local c = d.borderColor
            b.border:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
        end
        b.border:Show()
    else
        b.border:SetBackdrop(nil)
        b.border:Hide()
    end
    -- Zoom: the percentage of the icon's edge trimmed off, where 30%
    -- removes the Blizzard border baked into the icons.
    local inset = (d.zoom or 0) / 400
    b.icon:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
    local size = d.fontSize or 12
    b.key:SetFont(FONT, size, "OUTLINE")
    b.delay:SetFont(FONT, size, "OUTLINE")
    b.targets:SetFont(FONT, size, "OUTLINE")
    b.hold:SetFont(FONT, size, "OUTLINE")
    if b.size then Display.SetButtonSize(b, b.size) end
    b.tint = nil -- colors may have changed
    ns.Glow.Stop(b)
end

function Display:CreateFrames()
    local f = CreateFrame("Frame", "RotationHelperDisplay", UIParent)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        Display:SavePosition()
    end)
    f.SavePosition = function() Display:SavePosition() end

    self.frame = f
    self.buttons = {}
    for i = 1, MAX_ICONS do
        self.buttons[i] = Display.CreateButton(f, "RotationHelperButton" .. i)
    end
    self.buttons[1].targetMode = "primary"

    -- Unlocked: Hekili's box with the display name (UI/Mover.lua).
    ns.Mover.Create(f, "Primary", ns.Mover.OpenDisplaySettings)

    -- Waste warning: an orange border around the main icon that pulses.
    local main = self.buttons[1]
    local warn = CreateFrame("Frame", nil, main)
    warn:SetPoint("TOPLEFT", -3, 3)
    warn:SetPoint("BOTTOMRIGHT", 3, -3)
    warn:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
    warn:Hide()
    main.warn = warn

    -- Threat warning: a steady border outside the waste border.
    local threat = CreateFrame("Frame", nil, main)
    threat:SetPoint("TOPLEFT", -6, 6)
    threat:SetPoint("BOTTOMRIGHT", 6, -6)
    threat:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
    threat:Hide()
    main.threat = threat

    -- The spell you're casting, beside the main icon (see UpdateCast).
    self.castButton = Display.CreateButton(f, "RotationHelperCastButton")

    -- In-range alternative when the main ability is out of range, below
    -- the status line.
    self.altButton = Display.CreateButton(f, "RotationHelperAlternativeButton")

    -- Status line under the main icon: "CD", the AoE mode or enemy count,
    -- and waste labels. The first two are chips that Shift-click toggles.
    local status = CreateFrame("Frame", nil, f)
    status:SetPoint("TOPLEFT", self.buttons[1], "BOTTOMLEFT", 0, -2)
    status:SetWidth(1)
    status:SetHeight(STATUS_HEIGHT)
    f.status = status
    f.cdChip = self:CreateChip(status, function() RH:ToggleCooldowns() end)
    f.cdChip:SetPoint("TOPLEFT", status, "TOPLEFT")
    -- "POT": consumables, shown while you have one (anchored in UpdateStatus).
    f.potChip = self:CreateChip(status, function() RH:ToggleConsumables() end)
    f.potChip:SetPoint("LEFT", f.cdChip, "RIGHT", CHIP_GAP, 0)
    f.aoeChip = self:CreateChip(status, function() RH:CycleAoEMode() end)
    f.aoeChip:SetPoint("LEFT", f.cdChip, "RIGHT", CHIP_GAP, 0)
    f.wasteText = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.wasteText:SetPoint("LEFT", f.aoeChip, "RIGHT", CHIP_GAP, 0)
    -- "3/5 DIS": enemies with our diseases, with several enemies around.
    f.dotText = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.dotText:SetPoint("LEFT", f.wasteText, "RIGHT", CHIP_GAP, 0)

    -- Pre-pull checklist, e.g. "Missing: Flask, Food" (out of combat only,
    -- so it can share the space of the in-range alternative icon).
    f.checklist = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.checklist:SetPoint("TOPLEFT", self.buttons[1], "BOTTOMLEFT", 0, -(STATUS_HEIGHT + 4))
    f.checklist:SetTextColor(1, 0.6, 0.2)
    f.checklist:SetJustifyH("LEFT")
    f.checklist:Hide()

    -- Shown after an error until /rh errors has been used.
    f.errorMark = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.errorMark:SetPoint("RIGHT", self.buttons[1], "LEFT", -4, 0)
    f.errorMark:SetTextColor(1, 0.2, 0.2)
    f.errorMark:SetText("!")
    f.errorMark:Hide()

    -- Per frame, only while the display is shown: times the flash exactly,
    -- since the GCD ending fires no event and updates run at most 20/s.
    f:SetScript("OnUpdate", function() Display:Animate(GetTime()) end)

    self:CreateExtras(f) -- UI/DisplayExtras.lua
end

function Display:StartFlash(b, now)
    -- Only the main icon animates its flash.
    if b == self.buttons[1] and self.db.pressFlash and b:IsShown() then b.flashStart = now end
end

-- Flashes the main icon when its predicted ready time is reached, and
-- pulses the waste warning.
function Display:Animate(now)
    self:UpdateMouseMode()
    self:AnimateCast(now)
    local b = self.buttons[1]
    if b.warn:IsShown() then
        b.warn:SetAlpha(0.35 + 0.65 * abs(math.sin(now * WARN_PULSE_SPEED)))
    end
    if b.readyAt and now >= b.readyAt then
        b.readyAt = nil
        self:StartFlash(b, now)
    end
    local start = b.flashStart
    if start then
        local t = now - start
        if t >= FLASH_DURATION then
            b.flash:Hide()
            b.flashStart = nil
        else
            b.flash:SetAlpha(FLASH_ALPHA * (1 - t / FLASH_DURATION))
            b.flash:Show()
        end
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
function Display:SavePosition()
    local point, _, relPoint, x, y = self.frame:GetPoint(1)
    self.db.point = { point, "UIParent", relPoint, x, y }
end

-- The outermost buttons of a queue laid out from `main` in `direction`
-- with `count` icons of `mainSize` and `queueSize`: left, right, top,
-- bottom (for the unlocked box).
function Display.Perimeter(buttons, count, direction, mainSize, queueSize)
    local main, last = buttons[1], buttons[max(1, count)]
    local big = count > 1 and queueSize > mainSize and buttons[2] or main
    if direction == "LEFT" then return last, main, big, big end
    if direction == "UP" then return big, big, last, main end
    if direction == "DOWN" then return big, big, main, last end
    return main, last, big, big
end

function Display:ApplySettings()
    self.db = RH.db.profile.display
    previewKey = nil -- the rotation may have changed
    local d, f = self.db, self.frame

    f:ClearAllPoints()
    local p = d.point
    f:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
    f:SetScale(d.scale)
    f:SetWidth(d.iconSize)
    f:SetHeight(d.iconSize)
    f:EnableMouse(not d.locked)

    local grow = GROW[d.direction] or GROW.RIGHT
    local queueSize = d.queueSize or d.iconSize
    for i, b in ipairs(self.buttons) do
        Display.StyleButton(b, d)
        b:ClearAllPoints()
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            Display.SetButtonSize(b, d.iconSize)
        else
            b:SetPoint(grow[1], self.buttons[i - 1], grow[2], grow[3] * d.spacing, grow[4] * d.spacing)
            Display.SetButtonSize(b, queueSize)
        end
    end

    local main, colors = self.buttons[1], d.colors
    main.warn:SetBackdropBorderColor(colors.waste[1], colors.waste[2], colors.waste[3], 1)
    main.threat:SetBackdropBorderColor(colors.threat[1], colors.threat[2], colors.threat[3], 1)
    local alt = self.altButton
    Display.StyleButton(alt, d)
    alt:ClearAllPoints()
    alt:SetPoint("TOPLEFT", main, "BOTTOMLEFT", 0, -(STATUS_HEIGHT + 4))
    Display.SetButtonSize(alt, queueSize)
    Display.StyleButton(self.castButton, d)

    if d.locked then
        f.mover:Hide()
    else
        ns.Mover.Layout(f.mover, Display.Perimeter(self.buttons, d.numIcons, d.direction, d.iconSize, queueSize))
        f.mover:Show()
    end

    self:ApplyExtras()
    self:Refresh()
end

-- Copies a layout preset into the profile (see Display.PRESETS).
function RH:ApplyPreset(name)
    local preset = Display.PRESETS[name]
    if not preset then
        self:Print("Presets: " .. table.concat({ "hekili", "grambam" }, ", "))
        return false
    end
    local d = self.db.profile.display
    for key, value in pairs(preset) do
        if type(value) == "table" then
            d[key] = { unpack(value) }
        else
            d[key] = value
        end
    end
    d.preset = name -- "Reset positions" goes back to this preset's spots
    self:Print("Layout preset '" .. name .. "' applied.")
    self:SettingChangedOutsideOptions()
    return true
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
function Display:SetTestMode(enabled)
    self.testMode = enabled
    self:Refresh()
end

-- Returns the entries to draw, or nil to hide the display.
function Display:GetEntries()
    local d = self.db
    local unlockedPreview = not d.locked and RH.classSupported

    if self.testMode or unlockedPreview then
        local recs = RH.recommendations
        if not self.testMode and RH:IsActive() and recs and #recs > 0 then return recs end
        return self:GetPreview()
    end
    if not RH:IsActive() then return nil end
    if d.hideOutOfCombat and not RH.inCombat then return nil end

    local recs = RH.recommendations
    if recs and #recs > 0 then return recs end
end

-- The setters below skip calls into the client when nothing changed; the
-- display refreshes up to 20 times a second and rarely changes.
local function Tint(b, color, desaturate)
    if b.tint == color and b.desaturated == desaturate then return end
    b.tint, b.desaturated = color, desaturate
    b.icon:SetDesaturated(desaturate)
    b.icon:SetVertexColor(color[1], color[2], color[3])
end

local function SetIcon(b, path)
    if b.iconPath == path then return end
    b.iconPath = path
    b.icon:SetTexture(path)
end

local function SetKeyText(b, text)
    if b.keyText == text then return end
    b.keyText = text
    b.key:SetText(text)
end

local function SetText(fs, text)
    if fs.lastText == text then return end
    fs.lastText = text
    fs:SetText(text)
end

-- "0.8": seconds, cached per tenth so updates create no strings. From 10s
-- on, whole seconds ("12"), so a long countdown doesn't grow the cache.
local tenths, wholeSeconds = {}, {}
local function TenthsText(seconds)
    if seconds >= 10 then
        local n = floor(seconds + 0.5)
        local text = wholeSeconds[n]
        if not text then
            text = tostring(n)
            wholeSeconds[n] = text
        end
        return text
    end
    local n = floor(seconds * 10 + 0.5)
    local text = tenths[n]
    if not text then
        text = ("%.1f"):format(n / 10)
        tenths[n] = text
    end
    return text
end

-- Enemy count texts, cached per (shown, detected).
local targetTexts = {}
local function TargetText(shown, detected)
    local key = shown * 1000 + detected
    local text = targetTexts[key]
    if not text then
        -- Red: fewer enemies around than the mode assumes; blue: more.
        local color = detected < shown and "|cFFFF0000" or (shown < detected and "|cFF00C0FF" or "")
        text = color .. shown .. (color ~= "" and "|r" or "")
        targetTexts[key] = text
    end
    return text
end

-- Seconds until the ability's own cooldown, the GCD or your cast lets you
-- press it: the wait the swipe already shows. A delay beyond this is the
-- engine holding the ability (runes, a proc, a DoT to refresh).
local function Moment(entry, now)
    local s = ns.State.real
    local moment = 0
    local ability = entry.name and RH.classData and RH.classData.abilities[entry.name]
    if not (ability and ability.offGcd) and s.realGcdEnd and s.realGcdEnd > now then
        moment = s.realGcdEnd - now
    end
    local castRemains = s.realCastRemains or s.castRemains
    if castRemains and castRemains > moment then moment = castRemains end
    local cd = entry.name and s.cooldowns[entry.name]
    if cd and cd.readyAt ~= math.huge and cd.readyAt - now > moment then moment = cd.readyAt - now end
    return moment
end

-- Where the main icon's swipe starts (Hekili's "extend"): from the
-- ability's own cooldown if it's running, else your cast, else the GCD,
-- so the swipe shows how far along the real wait is.
local function SwipeStart(entry, now)
    local s = ns.State.real
    local cd = entry.name and s.cooldowns[entry.name]
    if cd and cd.duration and cd.readyAt ~= math.huge and cd.readyAt > now and cd.readyAt - cd.duration < now then
        return cd.readyAt - cd.duration
    end
    if s.castStart and s.castDuration and s.castStart + s.castDuration > now then return s.castStart end
    if s.realGcdEnd and s.gcdDuration and s.realGcdEnd > now then return s.realGcdEnd - s.gcdDuration end
    return now
end

-- The real cooldown of an entry's spell or item (GCD included), as the
-- action bars show it: start, duration, or nil.
local function RealCooldown(entry, info)
    local start, duration, enabled
    if entry.itemID then
        if not GetItemCooldown then return nil end
        start, duration, enabled = GetItemCooldown(entry.itemID)
    elseif info.name then
        start, duration, enabled = GetSpellCooldown(info.name)
    end
    if start and start > 0 and duration and duration > 0 and enabled ~= 0 then return start, duration end
    return nil
end

local function SetSwipe(b, start, duration)
    if b.swipeStart ~= start or b.swipeDuration ~= duration then
        b.swipeStart, b.swipeDuration = start, duration
        b.cooldown:SetCooldown(start, duration)
    end
    b.cooldown:Show()
end

local function HideSwipe(b)
    b.swipeStart, b.swipeDuration = nil, nil
    b.cooldown:Hide()
end

-- The enemy count for a main icon: in single-target mode always 1 (as
-- Hekili shows), in AoE mode at least 3, otherwise the count when there's
-- more than one enemy. Red when fewer are around than shown, blue when more.
function Display:UpdateTargets(b)
    if not self.db.targetCount then
        SetText(b.targets, "")
        return
    end
    local toggles = RH.db.profile.toggles
    local detected = RH.detectedEnemies or ns.State.real.activeEnemies or 1
    local tMin, tMax = 0, 0
    if b.targetMode == "aoe" then
        tMin = 3
    elseif self.db.dualDisplay or toggles.aoeMode == "single" then
        tMax = 1
    elseif toggles.aoeMode == "aoe" then
        tMin = 3
    end
    local shown = detected
    if tMin > 0 then shown = max(tMin, shown) end
    if tMax > 0 then shown = min(tMax, shown) end
    if tMax == 1 or shown > 1 then
        SetText(b.targets, TargetText(shown, detected))
    else
        SetText(b.targets, "")
    end
end

function Display:UpdateButton(b, entry, isMain, now)
    local d = self.db
    local info = entry.itemID and ItemInfo(entry) or SpellInfo(entry.spellId)
    SetIcon(b, info.icon)
    SetKeyText(b, (isMain or d.keybindQueued) and ns.Keybinds:Get(info.name) or "")

    -- Out of range: desaturated red. Unusable (resources): dark grey.
    local colors = d.colors
    local outOfRange = info.name and UnitExists("target") and IsSpellInRange(info.name, "target") == 0
    if outOfRange then
        Tint(b, colors.outOfRange, true)
    else
        local unusable = entry.lacksResources
        if not unusable and info.name and not entry.itemID then
            local _, noMana = IsUsableSpell(info.name)
            unusable = noMana
        end
        Tint(b, unusable and colors.noResources or TINT_NORMAL, false)
    end

    local wait = entry.wait
    if isMain then
        -- The swipe runs to the predicted press time; it's only restarted
        -- when that time moves, so it doesn't flicker.
        if wait and wait > 0.05 then
            local readyAt = now + wait
            if not b.readyAt or abs(readyAt - b.readyAt) > 0.1 then
                local start = SwipeStart(entry, now)
                b.swipeStart = nil
                SetSwipe(b, start, readyAt - start)
                b.readyAt = readyAt
            end
            b.readySpell = entry.spellId
        elseif b.readyAt then
            -- The ability we were counting down to is ready now (a refresh got
            -- here before Animate did).
            if b.readySpell == entry.spellId then self:StartFlash(b, now) end
            HideSwipe(b)
            b.readyAt = nil
        end

        -- Delay: the wait beyond the cooldown the swipe already shows.
        local delay = d.delayType ~= "NONE" and wait and wait > Moment(entry, now) + 0.05 and wait or nil
        if delay and d.delayType == "ICON" then
            SetText(b.delay, "")
            if delay < 0.5 then
                b.delayIcon:SetVertexColor(0, 1, 0, 1)
            elseif delay < 1.5 then
                b.delayIcon:SetVertexColor(1, 1, 0, 1)
            else
                b.delayIcon:SetVertexColor(1, 0, 0, 1)
            end
            b.delayIcon:Show()
        else
            SetText(b.delay, delay and TenthsText(delay) or "")
            b.delayIcon:Hide()
        end

        -- Caption: what the icon waits on, when it's more than a GCD away.
        local hold = d.holdIndicator and wait and wait > (ns.State.real.gcdDuration or 1.5)
            and (HOLD_LABELS[entry.limitedBy] or BlockedLabel(entry))
        if hold then
            SetText(b.hold, hold)
            b.hold:Show()
        else
            b.hold:Hide()
        end

        -- The highlight while this is the spell you're casting or have queued.
        local current = d.highlightCurrent and info.name and not entry.itemID and IsCurrentSpell(info.name)
        if current then b.highlight:Show() else b.highlight:Hide() end

        if b.targetMode then self:UpdateTargets(b) end
    else
        -- Queued: the spell's real cooldown, GCD included, like the action bars.
        local start, duration = RealCooldown(entry, info)
        if start then
            SetSwipe(b, start, duration)
        else
            HideSwipe(b)
        end
    end

    b:Show()
end

function Display:Refresh()
    if not self.frame then return end
    local entries = self:GetEntries()
    -- An unseen error keeps the display (and its "!") visible even when the
    -- error left nothing to recommend.
    local showError = RH.unseenErrors > 0 and RH:IsActive()
    -- The checklist also keeps it visible: before a pull there's often
    -- nothing to press yet.
    local checklist = RH:IsActive() and RH.checklist
    if not entries and not showError and not checklist then
        self.frame.errorMark:Hide()
        self.frame.checklist:Hide()
        self.frame:Hide()
        return
    end

    local now = GetTime()
    local count = self.db.numIcons
    for i, b in ipairs(self.buttons) do
        local entry = entries and i <= count and entries[i]
        if entry then
            self:UpdateButton(b, entry, i == 1, now)
        else
            b:Hide()
        end
    end

    if showError then self.frame.errorMark:Show() else self.frame.errorMark:Hide() end
    self:UpdateChecklist(checklist)
    local main = self.buttons[1]
    local borders = self.db.warningBorders and entries
    local waste = RH.waste
    if borders and waste and waste.any then main.warn:Show() else main.warn:Hide() end
    local threat = RH.threat
    if borders and threat and threat.warn then main.threat:Show() else main.threat:Hide() end

    local alternative = self.db.alternative and entries and RH.alternative
    if alternative then
        self:UpdateButton(self.altButton, alternative, false, now)
    else
        self.altButton:Hide()
    end
    self:UpdateCast(entries, now)
    self:UpdateProcs(entries, count)
    self:UpdateExtras(entries, count, now)
    self:UpdateStatus()
    self.frame:Show()
end

---------------------------------------------------------------------------
-- The spell you're casting
---------------------------------------------------------------------------
-- Whether to show your cast: casting or channelling for real, with
-- recommendations on screen (not the sample icons).
function Display:ShowsCast(entries)
    if not (self.db.castSlot and entries and entries == RH.recommendations and not self.testMode) then return false end
    local s = ns.State.real
    return s.castName ~= nil and s.castStart ~= nil and (s.castDuration or 0) > 0
        and (s.realCastRemains or s.castRemains or 0) > 0
end

function Display:UpdateCast(entries, now)
    local b = self.castButton
    if not self:ShowsCast(entries) then
        b.castStart = nil
        b:Hide()
        return
    end
    local s = ns.State.real
    if b.castStart ~= s.castStart then
        -- A new cast: the swipe runs with it, and the icon slides out from
        -- the main icon (from where it is if the cast started earlier).
        b.castStart, b.castEnd = s.castStart, s.castStart + s.castDuration
        b.slideStart = now
        SetIcon(b, s.castIcon or SpellInfo(0).icon)
        SetKeyText(b, "")
        Tint(b, TINT_NORMAL, false)
        SetSwipe(b, s.castStart, s.castDuration)
    end
    b:Show()
    self:AnimateCast(now)
end

-- Per frame: slide out, shrink and fade with the cast's progress, and the
-- time left. Beside the main icon on the side away from the queue.
function Display:AnimateCast(now)
    local b = self.castButton
    if not b:IsShown() then return end
    if now >= b.castEnd then
        b:Hide()
        return
    end
    local duration = b.castEnd - b.castStart
    local progress = max(0, min(1, (now - b.castStart) / duration))
    local slide = min(1, (now - b.slideStart) / CAST_SLIDE)
    slide = 1 - (1 - slide) * (1 - slide) -- ease out
    local main, d = self.buttons[1], self.db
    local size = d.iconSize * (1 - (1 - CAST_MIN_SCALE) * progress)
    Display.SetButtonSize(b, size)
    b:SetAlpha(1 - (1 - CAST_MIN_ALPHA) * progress)
    -- Starts on top of the main icon, ends `spacing` away from it.
    local overlap = (1 - slide) * size
    b:ClearAllPoints()
    if d.direction == "LEFT" then
        b:SetPoint("LEFT", main, "RIGHT", d.spacing * slide - overlap, 0)
    else
        b:SetPoint("RIGHT", main, "LEFT", -d.spacing * slide + overlap, 0)
    end
    SetText(b.hold, TenthsText(max(0, b.castEnd - now)))
    b.hold:Show()
end

local AOE_LABELS = { single = "ST", aoe = "AOE" }

-- A small clickable text on the status line. Only takes the mouse while
-- Shift is held (see UI/DisplayMouse.lua).
function Display:CreateChip(parent, onClick)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(STATUS_HEIGHT)
    chip.text = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chip.text:SetPoint("LEFT", chip, "LEFT")
    chip:SetScript("OnClick", onClick)
    chip:EnableMouse(false)
    return chip
end

-- Sets a chip's text and width; an empty text hides it.
local function SetChipText(chip, text)
    if chip.lastText ~= text then
        chip.lastText = text
        chip.text:SetText(text)
        chip:SetWidth(max(1, chip.text:GetStringWidth()))
    end
    if text == "" then chip:Hide() else chip:Show() end
end

-- The waste labels, e.g. "RUNES  RP  THREAT", built once per combination.
local wasteTexts = {}
local function WasteText(runes, powerLabel, threat)
    local key = (runes and "R" or "") .. "|" .. (powerLabel or "") .. "|" .. (threat and "T" or "")
    local text = wasteTexts[key]
    if not text then
        local parts = {}
        if runes then parts[#parts + 1] = "|cffff8000RUNES|r" end
        if powerLabel then parts[#parts + 1] = "|cffff8000" .. powerLabel .. "|r" end
        if threat then parts[#parts + 1] = "|cffff2020THREAT|r" end
        text = table.concat(parts, "  ")
        wasteTexts[key] = text
    end
    return text
end

-- "CD" is green when cooldowns are on, red when off. The AoE chip shows
-- the forced mode, or in auto mode the enemy count once there's more than
-- one ("AUTO" while Shift is held, so there's always something to click).
-- Waste labels follow.
function Display:UpdateStatus()
    local f = self.frame
    if not self.db.showStatus then
        f.status:Hide()
        return
    end
    local toggles = RH.db.profile.toggles
    -- CD: green when cooldowns are suggested now, yellow when on but waiting
    -- for a boss ("bosses only"), red when off.
    local cdText = "|cffff4040CD|r"
    if toggles.cooldowns then
        cdText = ns.State.real.cooldownsEnabled and "|cff40ff40CD|r" or "|cffffd100CD|r"
    end
    SetChipText(f.cdChip, cdText)

    -- POT: green when consumables would be suggested now, yellow when on but
    -- waiting for a boss, red when off. Only while you have a consumable.
    local potText = ""
    if ns.Spec.known.potion or self.mouseMode then
        if not toggles.consumables then
            potText = "|cffff4040POT|r"
        elseif ns.State.real.consumablesAllowed then
            potText = "|cff40ff40POT|r"
        else
            potText = "|cffffd100POT|r"
        end
    end
    SetChipText(f.potChip, potText)
    local aoeAnchor = f.potChip:IsShown() and f.potChip or f.cdChip
    if f.aoeChip.anchor ~= aoeAnchor then
        f.aoeChip.anchor = aoeAnchor
        f.aoeChip:ClearAllPoints()
        f.aoeChip:SetPoint("LEFT", aoeAnchor, "RIGHT", CHIP_GAP, 0)
    end

    local mode = AOE_LABELS[RH.db.profile.display.dualDisplay and "single" or toggles.aoeMode]
    local enemies = ns.State.real.activeEnemies or 1
    local aoeText = ""
    if mode then
        aoeText = "|cffffd100" .. mode .. "|r"
    elseif enemies > 1 then
        aoeText = tostring(enemies)
    elseif self.mouseMode then
        aoeText = "|cff999999AUTO|r"
    end
    SetChipText(f.aoeChip, aoeText)

    local waste, threat = RH.waste, RH.threat
    local wasteText = WasteText(waste and waste.runes, waste and waste.power and waste.powerLabel,
        threat and threat.warn)
    if f.wasteText.lastText ~= wasteText then
        f.wasteText.lastText = wasteText
        f.wasteText:SetText(wasteText)
    end
    -- Waste labels move left when the AoE chip is empty (re-anchored only
    -- when that changes; this runs 20 times a second).
    local anchor = f.aoeChip:IsShown() and f.aoeChip or (f.potChip:IsShown() and f.potChip or f.cdChip)
    if f.wasteText.anchor ~= anchor then
        f.wasteText.anchor = anchor
        f.wasteText:ClearAllPoints()
        f.wasteText:SetPoint("LEFT", anchor, "RIGHT", CHIP_GAP, 0)
    end
    self:UpdateDotText(enemies)
    f.status:Show()
end

-- "diseased/enemies DIS" (or "2/4 CORR", the Engine/Dots.lua hint),
-- yellow while some enemy lacks them. The strings are cached per label and
-- pair so updates don't create garbage.
local dotTexts = {}
function Display:UpdateDotText(enemies)
    local f, text = self.frame, ""
    local s = ns.State.real
    local hint = ns.Dots.hint
    if enemies > 1 and hint and RH.inCombat then
        local count = min(ns.Dots.HintCount(s), enemies)
        local texts = dotTexts[hint.label]
        if not texts then
            texts = {}
            dotTexts[hint.label] = texts
        end
        local key = count * 1000 + enemies
        text = texts[key]
        if not text then
            text = (count < enemies and "|cffffd100%d/%d %s|r" or "|cff40ff40%d/%d %s|r"):format(count, enemies, hint.label)
            texts[key] = text
        end
    end
    if f.dotText.lastText ~= text then
        f.dotText.lastText = text
        f.dotText:SetText(text)
    end
    -- Moves left when there are no waste labels.
    local anchor = f.wasteText.lastText ~= "" and f.wasteText
        or (f.aoeChip:IsShown() and f.aoeChip or (f.potChip:IsShown() and f.potChip or f.cdChip))
    if f.dotText.anchor ~= anchor then
        f.dotText.anchor = anchor
        f.dotText:ClearAllPoints()
        f.dotText:SetPoint("LEFT", anchor, "RIGHT", CHIP_GAP, 0)
    end
end

-- "Missing: Flask, Food"; the text is only rebuilt when the list changes.
function Display:UpdateChecklist(checklist)
    local fs = self.frame.checklist
    if not checklist then
        fs:Hide()
        fs.key = nil
        return
    end
    local key = table.concat(checklist, ", ")
    if fs.key ~= key then
        fs.key = key
        fs:SetText("Missing: " .. key)
    end
    fs:Show()
end

-- The status line as plain text, e.g. "CD  3  RP" (for tests and debugging).
function Display:GetStatusText()
    local f, parts = self.frame, {}
    if not f.status:IsShown() then return "" end
    for _, fs in ipairs({ f.cdChip:IsShown() and f.cdChip.text, f.potChip:IsShown() and f.potChip.text,
        f.aoeChip:IsShown() and f.aoeChip.text, f.wasteText,
        f.dotText }) do
        local text = fs and fs:GetText()
        if text and text ~= "" then parts[#parts + 1] = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    end
    return table.concat(parts, "  ")
end

---------------------------------------------------------------------------
-- Procs: the glow (Hekili's styles, UI/Glow.lua) on icons whose ability
-- spends a proc, the badge, and a sound once per new proc (a proc is new
-- when its expiry time changes).
---------------------------------------------------------------------------
-- The icon of a proc aura, e.g. Killing Machine's.
local function ProcIcon(key)
    local def = RH.classData.auras[key]
    local id = def and (def.id or (def.ids and def.ids[1]))
    return id and SpellInfo(id).icon
end

local classGlowColor = {}
function Display:GlowColor()
    local d = self.db
    if d.glowClassColor then
        classGlowColor[1], classGlowColor[2], classGlowColor[3], classGlowColor[4] = ns.Mover.ClassColor()
        classGlowColor[4] = 1
        return classGlowColor
    end
    return d.glowColor or ns.Glow.DEFAULT_COLOR
end

-- Shows or hides the proc glow on one button.
function Display:SetGlow(b, on)
    if on then
        ns.Glow.Start(b, self.db.glowMode or "autocast", self:GlowColor(), self.db.glowScale or 1)
    elseif b.glowing then
        ns.Glow.Stop(b)
    end
end

function Display:UpdateProcs(entries, count)
    local d = self.db
    local glowOn, badgeOn = d.procGlow, d.procBadge
    for i, b in ipairs(self.buttons) do
        local entry = entries and i <= count and entries[i]
        local shown = entry and b:IsShown()
        self:SetGlow(b, glowOn and shown and entry.usesProc and (i == 1 or d.glowQueued))
        local reason = badgeOn and shown and entry.procReason
        if reason then
            local icon = ProcIcon(reason)
            if b.badge.iconPath ~= icon then
                b.badge.iconPath = icon
                b.badge.icon:SetTexture(icon)
            end
            b.badge:Show()
        else
            b.badge:Hide()
        end
    end
    local main = entries and entries[1]
    local sound = d.procSound
    if main and main.usesProc and sound and sound ~= "none" then
        local key = main.usesProc
        self.procHeard = self.procHeard or {}
        if self.procHeard[key] ~= main.procExpires then
            self.procHeard[key] = main.procExpires
            PlaySound(sound)
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
-- The other displays draw with this module's settings and may be enabled
-- before it (AceAddon enables modules in no particular order).
function Display:OnInitialize()
    self.db = RH.db.profile.display
end

function Display:OnEnable()
    self:CreateFrames()
    self:SetupMouse()
    self:RegisterMessage("ROTATIONHELPER_CONFIG_CHANGED", "ApplySettings")
    self:RegisterMessage("ROTATIONHELPER_COMBAT_CHANGED", "Refresh")
    RH:RegisterUpdater(function() Display:Refresh() end, RH.UPDATE_ORDER.DISPLAY, "display")
    self:ApplySettings()
end
