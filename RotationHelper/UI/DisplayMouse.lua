local ADDON_NAME, ns = ...
local RH = ns.RH
local Display = ns.Display

-- Mouse interaction with the locked display, only while Shift is held, so
-- normally it stays click-through:
--   hover an icon      tooltip: the spell, and the rotation line that chose it
--   click CD / AoE     toggle cooldowns / cycle the AoE mode
local IsShiftKeyDown = IsShiftKeyDown

local ACCENT = { 0.35, 0.68, 0.95 }
local DIM = { 0.6, 0.6, 0.63 }
local WAITING_ON = { gcd = "the GCD", runes = "runes", cooldown = "its cooldown", cast = "your cast" }

function Display:SetMouseMode(on)
    self.mouseMode = on
    for _, b in ipairs(self.buttons) do b:EnableMouse(on) end
    self.frame.cdChip:EnableMouse(on)
    self.frame.aoeChip:EnableMouse(on)
    self.frame.potChip:EnableMouse(on)
    if not on then
        for _, b in ipairs(self.buttons) do
            if GameTooltip:IsOwned(b) then GameTooltip:Hide() end
        end
    end
    self:UpdateStatus()
end

-- Called every frame from Animate while the display is shown.
function Display:UpdateMouseMode()
    local want = (self.db.locked and self.db.shiftInteract and IsShiftKeyDown()) and true or false
    if want ~= (self.mouseMode or false) then self:SetMouseMode(want) end
end

local function AuraName(key)
    local def = RH.classData.auras[key]
    local id = def and (def.id or (def.ids and def.ids[1]))
    return id and GetSpellInfo(id) or key
end

-- "Ready now" / "Ready in 1.2s (waiting on runes)".
local function Readiness(entry)
    if entry.wait <= 0.05 then return "Ready now" end
    local on = WAITING_ON[entry.limitedBy]
    if not on and entry.limitedBy then
        local ability = RH.classData.abilities[entry.name]
        if ability and ability.blockedBy == entry.limitedBy then
            local aura = RH.classData.auras[entry.limitedBy]
            on = (aura and aura.id and GetSpellInfo(aura.id) or entry.limitedBy) .. " to end"
        end
    end
    return ("Ready in %.1fs%s"):format(entry.wait, on and (" (waiting on " .. on .. ")") or "")
end

function Display:ShowTooltip(b, index)
    local entries = self:GetEntries()
    local entry = entries and entries[index]
    if not entry then return end
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(entry.itemID and ("item:" .. entry.itemID) or ("spell:" .. entry.spellId))
    GameTooltip:AddLine(" ")

    local action = entry.action
    if not action then
        GameTooltip:AddLine("Sample icon (display unlocked or test mode).", DIM[1], DIM[2], DIM[3])
        GameTooltip:Show()
        return
    end
    local apl = ns.Recommender:GetAPL()
    local list = action.list == "default" and "main list" or ("list '" .. action.list .. "'")
    GameTooltip:AddLine(("%s, %s, line %d"):format(apl and apl.name or "Rotation", list, action.line),
        ACCENT[1], ACCENT[2], ACCENT[3])
    -- '|' is an escape character in tooltips too.
    GameTooltip:AddLine((action.text:gsub("|", "||")), 1, 1, 1, true)
    GameTooltip:AddLine(Readiness(entry), 1, 1, 1)
    if entry.procReason then
        GameTooltip:AddLine("Recommended because of " .. AuraName(entry.procReason), 1, 0.82, 0)
    elseif entry.usesProc then
        GameTooltip:AddLine("Spends " .. AuraName(entry.usesProc), 1, 0.82, 0)
    end
    if index > 1 then
        GameTooltip:AddLine("Predicted: assumes you use the icons before it first.", DIM[1], DIM[2], DIM[3], true)
    end
    GameTooltip:Show()
end

function Display:SetupMouse()
    for i, b in ipairs(self.buttons) do
        b:EnableMouse(false)
        b:SetScript("OnEnter", function(button) Display:ShowTooltip(button, i) end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    self.mouseMode = false
end
