-- Offline test runner. From the repo root:
--   lua tests/run.lua
package.path = "./tests/?.lua;" .. package.path

local T = require("testlib")

local SUITES = {
    "test_syntax",
    "test_core",
    "test_keybinds",
    "test_display",
    "test_state",
    "test_apl",
    "test_engine",
    "test_frost",
    "test_unholy",
    "test_blood",
    "test_retribution",
    "test_fury",
    "test_arms",
    "test_elemental",
    "test_enhancement",
    "test_shadow",
    "test_fire",
    "test_arcane",
    "test_frost_mage",
    "test_affliction",
    "test_destruction",
    "test_demonology",
    "test_balance",
    "test_feral",
    "test_feral_gaps",
    "test_marksmanship",
    "test_survival",
    "test_beast_mastery",
    "test_combat",
    "test_assassination",
    "test_subtlety",
    "test_predict",
    "test_targets",
    "test_options",
    "test_skin",
    "test_perf",
    "test_errors",
    "test_latency",
    "test_waste",
    "test_interrupt",
    "test_specprofiles",
    "test_mouse_procs",
    "test_phase_a",
    "test_review",
    "test_sim",
    "test_apltext",
    "test_apleditor",
    "test_phase_e",
    "test_phase_f",
    "test_phase_g",
    "test_versioncheck",
    "test_report",
    "test_apl_options",
    "test_castslot",
    "test_consumables",
}

for _, suite in ipairs(SUITES) do
    print(suite)
    require(suite)
end

print(("\n%d passed, %d failed"):format(T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
