-- Tiny assertion helpers shared by the test suites.
local Mock = require("wowmock")

local T = { passed = 0, failed = 0 }

function T.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        T.passed = T.passed + 1
        print("  PASS  " .. name)
    else
        T.failed = T.failed + 1
        print("  FAIL  " .. name .. "\n        " .. tostring(err))
    end
end

function T.eq(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function T.truthy(v, what)
    if not v then error((what or "value") .. " was not truthy", 2) end
end

function T.falsy(v, what)
    if v then error((what or "value") .. " was " .. tostring(v) .. ", expected falsy", 2) end
end

-- Loads the addon into a fresh mocked client. Returns the session and addon.
function T.newAddon(opts)
    local s = Mock.NewSession(opts)
    local RH = s:LoadAddon()
    if s.luaErrors[1] then error("error while loading the addon: " .. s.luaErrors[1], 2) end
    -- The spec tests read four predictions; the Hekili look shows three.
    RH.db.profile.display.numIcons = 4
    return s, RH
end

return T
