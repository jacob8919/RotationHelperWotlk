local ADDON_NAME, ns = ...
local RH = ns.RH

-- Rotation settings: a default rotation declares tunables (a rage
-- threshold, which curse to use), the Rotation tab shows them, and the
-- rotation reads them as option.KEY (a number; toggles are 1 or 0) or
-- option.KEY.VALUE for a select (1 if that one is chosen). Custom
-- rotations for the spec can read them too.
--
-- Declared with the rotation (Core.lua ns.RegisterAPL):
--   { key = "hs_rage", name = "Heroic Strike at rage", desc = "...",
--     type = "range", default = 50, min = 20, max = 100, step = 5 }
--   { key = "curse", name = "Curse", type = "select", default = "agony",
--     values = { agony = "Curse of Agony", elements = "Curse of the Elements" } }
--   { key = "not_behind", name = "Not behind the target", type = "toggle", default = false }
-- Values live in profile.aplOptions[class][spec][key]; unset means the default.
local APLOptions = {}
ns.APLOptions = APLOptions

local NONE = {}

local function B(value) return value and 1 or 0 end

-- The declarations for a spec (from its default rotation), or an empty list.
function APLOptions.Declared(specKey)
    local apls = ns.APLs[RH.playerClass]
    local apl = apls and apls[specKey]
    return apl and apl.options or NONE
end

function APLOptions.Find(specKey, key)
    for _, decl in ipairs(APLOptions.Declared(specKey)) do
        if decl.key == key then return decl end
    end
end

local function Saved(specKey, create)
    local all = RH.db.profile.aplOptions
    local class = all[RH.playerClass]
    if not class then
        if not create then return nil end
        class = {}
        all[RH.playerClass] = class
    end
    local spec = class[specKey]
    if not spec and create then
        spec = {}
        class[specKey] = spec
    end
    return spec
end

local function Value(specKey, decl)
    local saved = Saved(specKey)
    local value = saved and saved[decl.key]
    if value == nil then return decl.default end
    return value
end

function APLOptions.Get(specKey, key)
    local decl = APLOptions.Find(specKey, key)
    return decl and Value(specKey, decl)
end

-- Saves a value (the default is stored as unset) and applies it.
function APLOptions.Set(specKey, key, value)
    local decl = APLOptions.Find(specKey, key)
    if not decl then return end
    if value == decl.default then value = nil end
    Saved(specKey, true)[key] = value
    RH:OnConfigChanged()
end

-- Back to the defaults for a spec.
function APLOptions.Reset(specKey)
    local class = RH.db.profile.aplOptions[RH.playerClass]
    if class then class[specKey] = nil end
    RH:OnConfigChanged()
end

-- Whether any setting of the spec differs from its default.
function APLOptions.Changed(specKey)
    return next(Saved(specKey) or NONE) ~= nil
end

local function KnownNames(specKey)
    local names = {}
    for _, decl in ipairs(APLOptions.Declared(specKey)) do names[#names + 1] = decl.key end
    if #names == 0 then return "this spec's rotation has no settings" end
    return "known: " .. table.concat(names, ", ")
end

-- Resolves option.KEY / option.KEY.VALUE for a spec: a getter (read live,
-- so a changed setting applies right away), or nil and a message.
function APLOptions.Getter(specKey, name)
    local key, value = name:match("^option%.([%w_]+)%.([%w_]+)$")
    key = key or name:match("^option%.([%w_]+)$")
    local decl = key and APLOptions.Find(specKey, key)
    if not decl then
        return nil, "unknown setting '" .. tostring(key or name) .. "' (" .. KnownNames(specKey) .. ")"
    end
    if decl.type == "select" then
        if not value then return nil, "use option." .. key .. ".VALUE, e.g. option." .. key .. "." .. decl.default end
        if not decl.values[value] then
            local values = {}
            for v in pairs(decl.values) do values[#values + 1] = v end
            table.sort(values)
            return nil, "unknown value '" .. value .. "' for option." .. key .. " (" .. table.concat(values, ", ") .. ")"
        end
        return function() return B(Value(specKey, decl) == value) end
    end
    if value then return nil, "option." .. key .. " is a number; use it without ." .. value end
    if decl.type == "toggle" then return function() return B(Value(specKey, decl)) end end
    return function() return Value(specKey, decl) end
end

local ON_WORDS = { on = true, ["1"] = true, ["true"] = true, yes = true }
local OFF_WORDS = { off = true, ["0"] = true, ["false"] = true, no = true }

-- "Not behind the target: ON" / "Heroic Strike at rage: 60" / "Curse: Curse of Doom".
local function Describe(decl, value)
    if decl.type == "toggle" then return decl.name .. ": " .. (value and "ON" or "OFF") end
    if decl.type == "select" then return decl.name .. ": " .. (decl.values[value] or tostring(value)) end
    return decl.name .. ": " .. tostring(value)
end

-- /rh set KEY [VALUE], for macros and key bindings: flips a toggle (or
-- sets it with on/off), sets a number (clamped to its range) or picks a
-- select's value. Without a key, lists the current spec's settings.
-- Returns the message to show, and whether a setting changed.
function APLOptions.Command(specKey, input)
    local key, value = (input or ""):match("^%s*([%w_]*)%s*(.-)%s*$")
    local declared = APLOptions.Declared(specKey)
    if key == "" then
        if #declared == 0 then return "This spec's rotation has no settings.", false end
        local lines = {}
        for _, decl in ipairs(declared) do
            lines[#lines + 1] = ("%s (%s)"):format(Describe(decl, Value(specKey, decl)), decl.key)
        end
        return "Rotation settings (/rh set KEY [VALUE]):\n  " .. table.concat(lines, "\n  "), false
    end
    local decl = APLOptions.Find(specKey, key)
    if not decl then return "Unknown setting '" .. key .. "' (" .. KnownNames(specKey) .. ").", false end
    local new
    if decl.type == "toggle" then
        local word = value:lower()
        if word == "" then
            new = not Value(specKey, decl)
        elseif ON_WORDS[word] then
            new = true
        elseif OFF_WORDS[word] then
            new = false
        else
            return "Usage: /rh set " .. key .. " [on|off]", false
        end
    elseif decl.type == "select" then
        if not decl.values[value] then
            local values = {}
            for v in pairs(decl.values) do values[#values + 1] = v end
            table.sort(values)
            return "Usage: /rh set " .. key .. " <" .. table.concat(values, "|") .. ">", false
        end
        new = value
    else
        new = tonumber(value)
        if not new then return ("Usage: /rh set %s <%s-%s>"):format(key, decl.min, decl.max), false end
        new = math.max(decl.min, math.min(decl.max, new))
    end
    APLOptions.Set(specKey, key, new)
    return Describe(decl, new), true
end

-- Every option name of a spec, for the name picker.
function APLOptions.Names(specKey)
    local names = {}
    for _, decl in ipairs(APLOptions.Declared(specKey)) do
        if decl.type == "select" then
            for value in pairs(decl.values) do names[#names + 1] = "option." .. decl.key .. "." .. value end
        else
            names[#names + 1] = "option." .. decl.key
        end
    end
    table.sort(names)
    return names
end

-- "hs_rage=60, curse=doom" for the settings that differ from the defaults.
function APLOptions.Describe(specKey)
    local parts = {}
    for _, decl in ipairs(APLOptions.Declared(specKey)) do
        local value = Value(specKey, decl)
        if value ~= decl.default then parts[#parts + 1] = decl.key .. "=" .. tostring(value) end
    end
    return #parts > 0 and table.concat(parts, ", ") or "defaults"
end
