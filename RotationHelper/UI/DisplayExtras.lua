local ADDON_NAME, ns = ...
local RH = ns.RH

-- Display extras (Phase F), drawn as part of the main display:
--   - the rune bar: the six runes with their type and recharge, and under
--     each a strip showing its type once the predicted actions are used
--     (dim when the shown queue spends it);
--   - the cooldown strip: the class's major cooldowns and trinkets with the
--     time left;
--   - timeline mode: queued icons placed by when they'll be usable, so
--     waiting on runes shows as a gap.
local Display = ns.Display

local GetSpellInfo = GetSpellInfo
local ceil, floor, max, min, ipairs = math.ceil, math.floor, math.max, math.min, ipairs

local WHITE = "Interface\\Buttons\\WHITE8X8"
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local EXTRA_GAP = 3        -- between the icons and the extras above them
local RUNE_GAP = 2
local STRIP_HEIGHT = 3     -- the predicted-type strip under each rune
local CD_GAP = 2
local MAX_COOLDOWNS = 8
local MAX_TICKS = 16

Display.RUNE_COLORS = {
    blood = { 0.85, 0.15, 0.15 },
    unholy = { 0.2, 0.75, 0.2 },
    frost = { 0.25, 0.55, 1 },
    death = { 0.65, 0.3, 0.9 },
    unknown = { 0.5, 0.5, 0.5 },
}
local RUNE_COLORS = Display.RUNE_COLORS

-- Trinkets follow the class's major cooldowns in the strip.
local SHARED_COOLDOWNS = { "trinket1", "trinket2" }

-- Number labels, built once so updates don't create strings.
local seconds = {}
local function SecondsText(n)
    local text = seconds[n]
    if not text then
        text = tostring(n)
        seconds[n] = text
    end
    return text
end

local minutes = {}
local function CooldownText(remains)
    if remains >= 60 then
        local m = ceil(remains / 60)
        local text = minutes[m]
        if not text then
            text = m .. "m"
            minutes[m] = text
        end
        return text
    end
    return SecondsText(ceil(remains))
end

-- "2.3" for the timeline labels, cached per tenth of a second.
local tenths = {}
local function WaitText(wait)
    local n = floor(wait * 10 + 0.5)
    local text = tenths[n]
    if not text then
        text = ("%.1f"):format(n / 10)
        tenths[n] = text
    end
    return text
end

local function SetText(fs, text)
    if fs.lastText == text then return end
    fs.lastText = text
    fs:SetText(text)
end

local function SetColor(tex, color, alpha)
    if tex.color == color and tex.alpha == alpha then return end
    tex.color, tex.alpha = color, alpha
    tex:SetVertexColor(color[1], color[2], color[3], alpha)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
function Display:CreateExtras(f)
    -- Rune bar
    local bar = CreateFrame("Frame", nil, f)
    bar:Hide()
    bar.cells = {}
    for i = 1, 6 do
        local cell = CreateFrame("Frame", nil, bar)
        cell:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        cell:SetBackdropColor(0, 0, 0, 0.7)
        cell:SetBackdropBorderColor(0, 0, 0, 1)
        cell.fill = cell:CreateTexture(nil, "ARTWORK")
        cell.fill:SetTexture(WHITE)
        cell.fill:SetPoint("TOPLEFT", 1, -1)
        cell.fill:SetPoint("BOTTOMLEFT", 1, 1 + STRIP_HEIGHT)
        cell.predicted = cell:CreateTexture(nil, "ARTWORK")
        cell.predicted:SetTexture(WHITE)
        cell.predicted:SetPoint("BOTTOMLEFT", 1, 1)
        cell.predicted:SetPoint("BOTTOMRIGHT", -1, 1)
        cell.predicted:SetHeight(STRIP_HEIGHT - 1)
        cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell.text:SetPoint("CENTER", 0, STRIP_HEIGHT / 2)
        bar.cells[i] = cell
    end
    f.runeBar = bar

    -- Cooldown strip
    local strip = CreateFrame("Frame", nil, f)
    strip:Hide()
    strip.icons = {}
    for i = 1, MAX_COOLDOWNS do
        local b = CreateFrame("Frame", nil, strip)
        b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        b:SetBackdropColor(0, 0, 0, 0.6)
        b:SetBackdropBorderColor(0, 0, 0, 1)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 1, -1)
        b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
        b.cooldown:SetAllPoints(b.icon)
        b.cooldown:Hide()
        b.overlay = CreateFrame("Frame", nil, b)
        b.overlay:SetAllPoints(b)
        b.overlay:SetFrameLevel(b.cooldown:GetFrameLevel() + 1)
        b.text = b.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER", 0, 0)
        b:Hide()
        strip.icons[i] = b
    end
    f.cooldownStrip = strip

    -- Timeline axis: a line under the queue with a tick every second.
    local axis = f:CreateTexture(nil, "ARTWORK")
    axis:SetTexture(WHITE)
    axis:SetVertexColor(0.6, 0.6, 0.6, 0.6)
    axis:SetHeight(1)
    axis:Hide()
    f.axis = axis
    f.ticks = {}
    for i = 1, MAX_TICKS do
        local tick = f:CreateTexture(nil, "ARTWORK")
        tick:SetTexture(WHITE)
        tick:SetVertexColor(0.6, 0.6, 0.6, 0.8)
        tick:SetWidth(1)
        tick:SetHeight(4)
        tick:Hide()
        f.ticks[i] = tick
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
-- Sizes and anchors; called from Display:ApplySettings after the icons are placed.
function Display:ApplyExtras()
    local d, f = self.db, self.frame
    local main = self.buttons[1]

    -- The extras go above the icons; with the queue growing upwards, above
    -- the last queued icon.
    local anchor = main
    if d.direction == "UP" and not d.timeline then anchor = self.buttons[d.numIcons] end

    local bar = f.runeBar
    local cellWidth = max(10, floor(d.iconSize * 0.36 + 0.5))
    local cellHeight = max(8, floor(d.iconSize * 0.22 + 0.5)) + STRIP_HEIGHT
    bar.cellWidth = cellWidth
    for i, cell in ipairs(bar.cells) do
        cell:SetWidth(cellWidth)
        cell:SetHeight(cellHeight)
        cell:ClearAllPoints()
        cell:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", (i - 1) * (cellWidth + RUNE_GAP), 0)
    end
    bar:SetWidth(6 * cellWidth + 5 * RUNE_GAP)
    bar:SetHeight(cellHeight)
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, EXTRA_GAP)
    bar.enabled = d.runeBar and RH.classData and RH.classData.usesRunes or false

    local strip = f.cooldownStrip
    local size = max(14, floor(d.iconSize * 0.5 + 0.5))
    for i, b in ipairs(strip.icons) do
        b:SetWidth(size)
        b:SetHeight(size)
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", (i - 1) * (size + CD_GAP), 0)
    end
    strip:SetHeight(size)
    strip:SetWidth(size)
    strip:ClearAllPoints()
    strip:SetPoint("BOTTOMLEFT", bar.enabled and bar or anchor, "TOPLEFT", 0, EXTRA_GAP)
    strip.enabled = d.cooldownStrip and RH.classData ~= nil

    -- Timeline: queued icons are placed on every refresh.
    for i = 2, #self.buttons do
        self.buttons[i].timelineX = nil
    end
    f.axis:ClearAllPoints()
    f.axis:SetPoint("TOPLEFT", main, "BOTTOMRIGHT", d.spacing, -1)
    if not d.timeline then
        f.axis:Hide()
        for _, tick in ipairs(f.ticks) do tick:Hide() end
        for i = 2, #self.buttons do self.buttons[i].hold:Hide() end
    end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
function Display:UpdateRuneBar(now)
    local bar = self.frame.runeBar
    local s = ns.State.real
    local runes = s.runes
    if not bar.enabled or not runes[6] then
        bar:Hide()
        return
    end
    local predicted = ns.Recommender.predictedRunes
    local regen = s.runeRegen or 10
    local width = bar.cellWidth - 2
    for i, cell in ipairs(bar.cells) do
        local rune = runes[i]
        local color = RUNE_COLORS[rune.type] or RUNE_COLORS.unknown
        local remains = rune.readyAt - now
        if remains <= 0 then
            cell.fill:SetWidth(width)
            SetColor(cell.fill, color, 1)
            SetText(cell.text, "")
        else
            local progress = min(1, max(0, 1 - remains / regen))
            cell.fill:SetWidth(max(0.1, width * progress))
            SetColor(cell.fill, color, 0.45)
            SetText(cell.text, SecondsText(ceil(remains)))
        end
        -- The strip: the rune's type after the predicted actions, dim when
        -- the queue spends it.
        local p = predicted[i]
        if p then
            local spent = p.readyAt > max(now, rune.readyAt) + 0.05
            SetColor(cell.predicted, RUNE_COLORS[p.type] or RUNE_COLORS.unknown, spent and 0.25 or 1)
            cell.predicted:Show()
        else
            cell.predicted:Hide()
        end
    end
    bar:Show()
end

local function AbilityIcon(ability)
    if ability.icon then return ability.icon end
    if ability.id then
        local _, _, icon = GetSpellInfo(ability.id)
        ability.icon = icon
        return icon
    end
end

-- Fills one strip slot. Returns true if the ability is shown.
local function UpdateCooldownIcon(b, key, now)
    local ability = RH.classData.abilities[key]
    local cd = ns.State.real.cooldowns[key]
    if not ability or not cd or not ns.Spec.known[key] or cd.readyAt == math.huge then return false end
    local icon = AbilityIcon(ability) or QUESTION_MARK
    if b.iconPath ~= icon then
        b.iconPath = icon
        b.icon:SetTexture(icon)
    end
    b.key = key
    local remains = cd.readyAt - now
    if remains > 0 then
        if b.readyAt ~= cd.readyAt then
            b.readyAt = cd.readyAt
            b.cooldown:Show()
            b.cooldown:SetCooldown(cd.readyAt - cd.duration, cd.duration)
        end
        b.icon:SetDesaturated(true)
        SetText(b.text, CooldownText(remains))
    else
        if b.readyAt then
            b.readyAt = nil
            b.cooldown:Hide()
        end
        b.icon:SetDesaturated(false)
        SetText(b.text, "")
    end
    b:Show()
    return true
end

function Display:UpdateCooldownStrip(now)
    local strip = self.frame.cooldownStrip
    if not strip.enabled then
        strip:Hide()
        return
    end
    local icons, n = strip.icons, 0
    local lists = RH.classData.majorCooldowns
    for pass = 1, 2 do
        local list = pass == 1 and lists or SHARED_COOLDOWNS
        if list then
            for _, key in ipairs(list) do
                if n < MAX_COOLDOWNS and UpdateCooldownIcon(icons[n + 1], key, now) then n = n + 1 end
            end
        end
    end
    for i = n + 1, MAX_COOLDOWNS do icons[i].key = nil; icons[i]:Hide() end
    if n == 0 then
        strip:Hide()
        return
    end
    strip:SetWidth(n * icons[1]:GetWidth() + (n - 1) * CD_GAP)
    strip:Show()
end

-- Timeline mode: the left edge of each queued icon sits at the time it
-- becomes usable. The scale makes one GCD exactly one icon plus spacing,
-- so back-to-back GCDs line up as usual and waits show as gaps; icons at
-- the same time (off-GCD cooldowns) are placed side by side.
function Display:LayoutTimeline(entries, count, now)
    local d, f = self.db, self.frame
    local main = self.buttons[1]
    local first = entries and entries[1]
    if not d.timeline or not first then
        f.axis:Hide()
        for _, tick in ipairs(f.ticks) do tick:Hide() end
        return
    end
    local step = (d.queueSize or d.iconSize) + d.spacing
    local gcd = ns.State.real.gcdDuration or 1.5
    local perSecond = step / gcd
    local maxX = (d.numIcons + 2) * step
    local origin = (first.wait or 0) + gcd -- the time at x = 0 (just right of the main icon)

    local x, right = 0, 0
    for i = 2, #self.buttons do
        local b = self.buttons[i]
        local entry = i <= count and entries[i]
        if entry and b:IsShown() then
            local wait = entry.wait or (i - 1) * gcd -- sample icons have no wait
            x = max(x, min(maxX, (wait - origin) * perSecond))
            if not b.timelineX or math.abs(b.timelineX - x) > 0.5 then
                b.timelineX = x
                b:ClearAllPoints()
                b:SetPoint("LEFT", main, "RIGHT", d.spacing + x, 0)
            end
            if b.holdText ~= WaitText(wait) then
                b.holdText = WaitText(wait)
                b.hold:SetText(b.holdText)
            end
            b.hold:Show()
            right = x + step
            x = right
        end
    end

    if right <= 0 then
        f.axis:Hide()
        for _, tick in ipairs(f.ticks) do tick:Hide() end
        return
    end
    f.axis:SetWidth(right)
    f.axis:Show()
    -- A tick at every whole second from now.
    local k = 1
    local t = ceil(origin)
    while k <= MAX_TICKS do
        local tickX = (t - origin) * perSecond
        if tickX > right then break end
        local tick = f.ticks[k]
        tick:SetPoint("TOP", f.axis, "TOPLEFT", tickX, 0) -- moves the tick's one anchor
        tick:Show()
        k = k + 1
        t = t + 1
    end
    for i = k, MAX_TICKS do f.ticks[i]:Hide() end
end

function Display:UpdateExtras(entries, count, now)
    self:UpdateRuneBar(now)
    self:UpdateCooldownStrip(now)
    self:LayoutTimeline(entries, count, now)
end
