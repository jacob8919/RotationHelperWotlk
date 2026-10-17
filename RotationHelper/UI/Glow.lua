local ADDON_NAME, ns = ...

-- Proc glows around an icon, in Hekili's three styles (its LibCustomGlow
-- modes), written for the 3.3.5 client:
--   autocast  four rings of small sparkles orbiting the icon's edge, each
--             ring a little slower than the last (Hekili's default)
--   pixel     short lines running around the icon's edge
--   button    the game's own proc glow (the spell activation alert with
--             the running ants), as on the action bars
-- Every glow frame is a child of the button, kept and reused.
local Glow = {}
ns.Glow = Glow

local CreateFrame = CreateFrame
local floor, max, min, ipairs, unpack = math.floor, math.max, math.min, ipairs, unpack

Glow.MODES = { autocast = "Autocast shine", pixel = "Pixel glow", button = "Action button glow", none = "None" }
Glow.DEFAULT_COLOR = { 0.95, 0.95, 0.32, 1 }

local WHITE = "Interface\\Buttons\\WHITE8X8"
-- The sparkle: a glint from the item socketing frame (as LibCustomGlow
-- uses on classic clients).
local SHINE = "Interface\\ItemSocketingFrame\\UI-ItemSockets"
local SHINE_COORDS = { 0.3984375, 0.4453125, 0.40234375, 0.44921875 }
-- Fallback for the button glow when the alert template isn't available.
local RING = "Interface\\Buttons\\UI-ActionButton-Border"

local GLOW_LEVEL = 8 -- above the cooldown swipe and the corner text

local function NewGlowFrame(b, key, offset)
    local f = CreateFrame("Frame", nil, b)
    f:SetFrameLevel(b:GetFrameLevel() + GLOW_LEVEL)
    f:SetPoint("TOPLEFT", b, "TOPLEFT", -offset, offset)
    f:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", offset, -offset)
    f.offset = offset
    f:Hide()
    b.glowFrames = b.glowFrames or {}
    b.glowFrames[key] = f
    return f
end

---------------------------------------------------------------------------
-- Autocast shine (Hekili's default)
---------------------------------------------------------------------------
local AC_GROUPS = 4          -- rings, from fastest to slowest
local AC_PER_GROUP = 4       -- sparkles per ring
local AC_SIZES = { 7, 6, 5, 4 }
local AC_PERIOD = 8          -- seconds per lap of the fastest ring

local function AutocastUpdate(self, elapsed)
    local width, height = self:GetWidth(), self:GetHeight()
    local info = self.info
    if width ~= info.width or height ~= info.height then
        if width * height == 0 then return end
        info.width, info.height = width, height
        info.perimeter = 2 * (width + height)
        info.bottomlim = height * 2 + width
        info.rightlim = height + width
        info.space = info.perimeter / AC_PER_GROUP
    end
    local index = 0
    for k = 1, AC_GROUPS do
        local t = self.timer[k] + elapsed / (AC_PERIOD * k)
        if t > 1 or t < -1 then t = t % 1 end
        self.timer[k] = t
        for i = 1, AC_PER_GROUP do
            index = index + 1
            local tex = self.textures[index]
            local position = (info.space * i + info.perimeter * t) % info.perimeter
            if position > info.bottomlim then
                tex:SetPoint("CENTER", self, "BOTTOMRIGHT", -position + info.bottomlim, 0)
            elseif position > info.rightlim then
                tex:SetPoint("CENTER", self, "TOPRIGHT", 0, -position + info.rightlim)
            elseif position > info.height then
                tex:SetPoint("CENTER", self, "TOPLEFT", position - info.height, 0)
            else
                tex:SetPoint("CENTER", self, "BOTTOMLEFT", 0, position)
            end
        end
    end
end

local function AutocastStart(b, color, scale)
    local f = b.glowFrames and b.glowFrames.autocast
    if not f then
        f = NewGlowFrame(b, "autocast", 0)
        f.textures, f.timer, f.info = {}, { 0, 0, 0, 0 }, {}
        for k = 1, AC_GROUPS do
            for _ = 1, AC_PER_GROUP do
                local tex = f:CreateTexture(nil, "ARTWORK")
                tex:SetTexture(SHINE)
                tex:SetTexCoord(unpack(SHINE_COORDS))
                tex:SetDesaturated(true)
                tex:SetBlendMode("ADD")
                tex.size = AC_SIZES[k]
                f.textures[#f.textures + 1] = tex
            end
        end
        f:SetScript("OnUpdate", AutocastUpdate)
    end
    for _, tex in ipairs(f.textures) do
        tex:SetWidth(tex.size * scale)
        tex:SetHeight(tex.size * scale)
        tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    end
    f:SetWidth(b:GetWidth() + 2 * f.offset)
    f:SetHeight(b:GetHeight() + 2 * f.offset)
    f.info.width = nil
    AutocastUpdate(f, 0)
    f:Show()
    return f
end

---------------------------------------------------------------------------
-- Pixel glow
---------------------------------------------------------------------------
local PX_LINES = 8
local PX_PERIOD = 4
local PX_THICKNESS = 1

-- A line covers [from, to) along the perimeter (top edge left to right,
-- then down the right edge, back along the bottom, up the left edge).
-- Every edge it crosses gets one rectangle.
local function PlaceSegment(tex, f, edge, a, b, w, h, th)
    local x1, y1, x2, y2
    if edge == 1 then
        x1, y1, x2, y2 = a, 0, b, th
    elseif edge == 2 then
        x1, y1, x2, y2 = w - th, a, w, b
    elseif edge == 3 then
        x1, y1, x2, y2 = w - b, h - th, w - a, h
    else
        x1, y1, x2, y2 = 0, h - b, th, h - a
    end
    tex:SetPoint("TOPLEFT", f, "TOPLEFT", x1, -y1)
    tex:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", x2, -y2)
    tex:Show()
end

local function PixelUpdate(self, elapsed)
    local info = self.info
    local t = self.timer + elapsed / PX_PERIOD
    if t > 1 or t < -1 then t = t % 1 end
    self.timer = t
    local w, h = self:GetWidth(), self:GetHeight()
    if w * h == 0 then return end
    local edges = { w, h, w, h }
    local perimeter = 2 * (w + h)
    local length = min(info.length, min(w, h))
    for i, line in ipairs(self.lines) do
        local from = ((t + (i - 1) / PX_LINES) % 1) * perimeter
        local used = 0
        local start = 0
        for edge = 1, 4 do
            local edgeLen = edges[edge]
            local a = max(from, start)
            local b = min(from + length, start + edgeLen)
            if b > a then
                used = used + 1
                PlaceSegment(line[used], self, edge, a - start, b - start, w, h, info.th)
            end
            start = start + edgeLen
        end
        -- A line running off the end wraps onto the top edge.
        if from + length > perimeter and used < 2 then
            used = used + 1
            PlaceSegment(line[used], self, 1, 0, from + length - perimeter, w, h, info.th)
        end
        for k = used + 1, 2 do line[k]:Hide() end
    end
end

local function PixelStart(b, color, scale)
    local f = b.glowFrames and b.glowFrames.pixel
    if not f then
        f = NewGlowFrame(b, "pixel", 0)
        f.lines, f.timer, f.info = {}, 0, {}
        for i = 1, PX_LINES do
            local line = {}
            for k = 1, 2 do
                local tex = f:CreateTexture(nil, "ARTWORK")
                tex:SetTexture(WHITE)
                tex:Hide()
                line[k] = tex
            end
            f.lines[i] = line
        end
        f:SetScript("OnUpdate", PixelUpdate)
    end
    for _, line in ipairs(f.lines) do
        for _, tex in ipairs(line) do tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1) end
    end
    f.info.th = max(1, floor(PX_THICKNESS * scale + 0.5))
    local w, h = b:GetWidth(), b:GetHeight()
    f:SetWidth(w + 2 * f.offset)
    f:SetHeight(h + 2 * f.offset)
    f.info.length = max(2, floor((w + h) * (2 / PX_LINES - 0.1)))
    PixelUpdate(f, 0)
    f:Show()
    return f
end

---------------------------------------------------------------------------
-- The game's proc glow (ants)
---------------------------------------------------------------------------
-- The spell activation alert template draws the action bar proc glow:
-- a burst, then ants running around the icon. It's only ever shown and
-- hidden here (never faded out through its own animation, which would
-- hand the frame to the action bars' pool). Without the template (older
-- clients, tests) a static ring stands in.
local function ButtonStart(b, color, scale)
    local f = b.glowFrames and b.glowFrames.button
    if not f then
        -- The template exists where the action bars' own glow does.
        local template = ActionButton_ShowOverlayGlow and "ActionBarButtonSpellActivationAlert" or nil
        f = CreateFrame("Frame", nil, b, template)
        f:SetFrameLevel(b:GetFrameLevel() + GLOW_LEVEL)
        b.glowFrames = b.glowFrames or {}
        b.glowFrames.button = f
        if not f.animIn then
            f.ring = f:CreateTexture(nil, "OVERLAY")
            f.ring:SetTexture(RING)
            f.ring:SetBlendMode("ADD")
            f.ring:SetAllPoints(f)
        end
        f:Hide()
    end
    local w, h = b:GetWidth(), b:GetHeight()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", b, "TOPLEFT", -w * 0.2 * scale, h * 0.2 * scale)
    f:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", w * 0.2 * scale, -h * 0.2 * scale)
    f:SetWidth(w * 1.4 * scale)
    f:SetHeight(h * 1.4 * scale)
    for _, key in ipairs({ "spark", "innerGlow", "innerGlowOver", "outerGlow", "outerGlowOver", "ants", "ring" }) do
        local tex = f[key]
        if tex then tex:SetVertexColor(color[1], color[2], color[3]) end
    end
    f:Show()
    if f.animIn then f.animIn:Play() end
    return f
end

local starters = { autocast = AutocastStart, pixel = PixelStart, button = ButtonStart }

-- Shows the glow of `mode` on button `b` (switching modes if another is
-- up). `scale` sizes the sparkles and lines; 1 is Hekili's.
function Glow.Start(b, mode, color, scale)
    local start = starters[mode]
    if not start then
        Glow.Stop(b)
        return
    end
    if b.glowMode ~= mode then Glow.Stop(b) end
    local f = start(b, color or Glow.DEFAULT_COLOR, scale or 1)
    b.glowMode, b.glowing = mode, true
    return f
end

function Glow.Stop(b)
    if b.glowFrames then
        for _, f in pairs(b.glowFrames) do f:Hide() end
    end
    b.glowMode, b.glowing = nil, false
end
