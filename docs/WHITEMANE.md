# Handoff: RotationHelper changes for Whitemane Frostmourne (Feral Druid, AoE, dual display, bear)

## Context

- **Addon:** RotationHelper, a Hekili-style rotation helper for the WoW 3.3.5a (WotLK) client.
  Upstream: https://github.com/rynosuki/RotationHelperWotlk
- **Base commit:** `b25aa650e84fb177483967372c289e3bc84ec9b6` (2026-09-29). The changes below are
  committed on top of it in the fork https://github.com/jacob8919/RotationHelperWotlk.
- **Server:** Whitemane's **Frostmourne** realm (WotLK, progressive). Its class changes are listed in
  "Frostmourne Beta Class Changes" (2026-08-22): https://whitemane.gg/en/news/beta-class-changes
  Whitemane says these are beta changes and not final.
- **User:** plays Feral Druid; previously used Hekili on retail/Classic and wanted the same experience
  on 3.3.5a. Their requests, in order:
  1. Support Whitemane's new **Glyph of Omen of Clarity** in the Feral rotation.
  2. A **Feral AoE** priority.
  3. A **second display that always shows the AoE suggestion** next to the single-target one (Hekili's
     "dual display").
  4. **Separate size settings** for that AoE display.
  5. A **bear tanking** rotation, single target and AoE.
- **Delivered as:** `RotationHelper-feral-bear-v3.zip` (the `RotationHelper` addon folder, to unzip into
  `Interface\AddOns`). Earlier zips (`-feral-glyph`, `-feral-aoe-dual`, `-feral-aoe-dual-v2`) are
  superseded by v3.

> **Nothing here has been run in the real game client.** Everything was verified with the repo's
> offline test suite (a mocked WoW API in `tests/wowmock.lua`) plus a compile check of every Lua file.
> The first thing to do with user feedback is to compare in-game suggestions against these notes.

## Note on the README

The upstream README says only Death Knight is supported. That's stale: the repo has rotations (APLs) for
most classes, including a Feral cat rotation. An early answer to the user repeated the README's claim and
was corrected once the code was inspected.

---

## 1. Glyph of Omen of Clarity (Whitemane custom glyph)

**Server change:** new major glyph. With the Omen of Clarity talent, casting Faerie Fire (Feral) always
procs Clearcasting (not on players or their pets).

**Decisions**
- **No spell ID needed.** `Engine/Spec.lua` reads glyphs by name (`GetGlyphSocketInfo` → `GetSpellInfo` →
  snake_case, minus `glyph_of_`), so the custom glyph shows up automatically as
  `glyph.omen_of_clarity`. Its real spell ID on Whitemane is unknown; tests use a fake ID (999001) with
  the right name.
- **Prediction:** `faerie_fire_feral.apply` (in `Classes/Druid.lua`) now also applies the `clearcasting`
  buff (15s) when the glyph and the `omen_of_clarity` talent are both present, so predicted queues show the
  free ability that follows.
- **Rotation (cat):**
  - Spend Clearcasting on Shred right away (Mangle if the "Not behind the target" option is on), after
    Savage Roar/Rip upkeep but before Rake. That frees Faerie Fire's 6s cooldown to proc it again.
  - Faerie Fire on cooldown when Clearcasting isn't up and energy < 90, so it doesn't cap energy.
  - All new lines are gated on `glyph.omen_of_clarity.enabled`, so **without the glyph the cat
    rotation is unchanged**.
- **Simulator result (180s, 2 runs):** about 17 → 24 Shreds per minute with the glyph, Faerie Fire about
  9.7 per minute. Treat this as directional only, since the sim's Omen proc model is approximate.

## 2. Feral (cat) AoE priority

**Decisions**
- New ability `swipe_cat` (spell 62078, 50 energy − Ferocity; no combo point).
- `actions+=/run_action_list,name=aoe,if=active_enemies>=3`, placed right after Tiger's Fury. On trash
  packs, single-target debuffs (FF, Mangle, Rip) aren't worth it.
- `aoe` list: keep Savage Roar up (it also buffs Swipe), using Mangle to get the point if needed;
  Clearcasting → Swipe; Faerie Fire for Clearcasting with the glyph; Swipe.
- The 3+ threshold matches the addon's existing convention (`Targets:ActiveEnemies` and the other specs'
  AoE lists).
- Sim on 5 targets: 15+ Swipes per minute, no Shreds.

## 3. Dual display (Hekili-style single target + AoE)

The addon already had AoE switching (one display; mode auto/single/aoe via the status chip, `/rh aoe`
or a keybind). The user wanted Hekili's dual display, with both visible at once.

**Behavior**
- `display.dualDisplay` (default **off**). Toggle it with `/rh dual`, the Display options checkbox, or the
  new "Toggle Dual Display" keybind.
- When it's on, the **main display is forced to single target** (`State:Reset` passes `"single"` to
  `Targets:ActiveEnemies`), whatever `toggles.aoeMode` says, and the status chip shows "ST". This copies
  Hekili, where Primary is single target and AOE is AoE.
- A **second display** (`UI/AoEDisplay.lua`, frame `RotationHelperAoEDisplay`, tagged "AoE") always shows
  the AoE prediction: the real enemy count when 3 or more, otherwise 3 (`ActiveEnemies(..., "aoe", ...)`).
- It follows the same show/hide rules as the main display (unlocked preview, test mode, hide out of
  combat, active).

**Implementation decisions**
- `Recommender:Predict(count, trace, enemies)`: the optional `enemies` argument overrides
  `v.activeEnemies` on the virtual state and writes to a **separate pool** (`aoeRecommendations` /
  `aoeEntries`), so the main tables aren't overwritten. The DK rune prediction (`predictedRunes`) is only
  updated by the main pass. `Recommender:Update` runs the AoE pass only when dual display is on and stores
  it in `RH.aoeRecommendations`, which the error-reset clears as well.
- The second display is a **separate module** instead of a refactor of `UI/Display.lua` (833 lines with
  many extras: cast slot, procs, waste/threat borders, mouse mode). It reuses `Display.CreateButton`,
  `Display.SetButtonSize` and `Display:UpdateButton`, which gives it keybind text, range tint, the
  cooldown swipe and the hold label. **Not included on the AoE display:** status chips, cast slot, proc
  glow/badge, in-range alternative, waste/threat borders, timeline layout, the press flash (it only
  animates on `Display.buttons[1]`) and the extras (rune bar, cooldown strip).
  - Possible follow-up: proc glow on the AoE icons (`Display:UpdateProcs` is tied to `self.buttons`).
- A spec without an AoE list just shows the same priority on both displays. That's harmless.

## 4. Separate AoE display sizing

- New profile keys: `display.aoeScale` (1.0), `aoeIconSize` (50), `aoeQueueScale` (0.8), `aoeNumIcons`
  (4), and `aoePoint` (`CENTER`, 0, −240) for its position. Each falls back to the main value if nil.
- Options: an "AoE display (dual display)" section under Layout, hidden unless dual display is on.
- Commands: `/rh aoescale <0.5-3>`, `/rh aoeicons <1-5>`. "Reset position" resets both displays.
- **Spacing, queue direction and colors stay shared** on purpose, to keep the options short. They're easy
  to split later in the same way.
- The AoE prediction count uses `aoeNumIcons`.

## 5. Bear tanking (single target + AoE)

**Key decision: one rotation that switches on form, not a separate spec or profile.** Bear and cat are
the same talent spec (`feral_combat`), and the addon picks rotations per spec. So the main list starts
with `run_action_list,name=bear,if=buff.bear_form.up`. Shifting switches the suggestions with nothing to
configure, and it works with the dual display, which shows bear ST and bear AoE together. The rotation is
renamed **"Feral cat & bear (default)"**. Users with a saved custom Feral APL keep theirs, which has no
bear section.

**Engine changes needed**
- **Form-aware GCD:** `classData.baseGcd` may now be a function `(state, spec)`, supported in both
  `Engine/Cooldowns.lua` and `Engine/Sim.lua`. Druid returns 1.5 in Bear Form, 1.0 for Feral otherwise
  (cat), and nil for casters, which keeps the existing hasted-GCD path. The real GCD read from the client
  while one is running still takes priority.
- **Rage:** `classData.rageIncome = 10` for Druids. The engine already reads rage per form
  (`UnitPowerType`) and learns income during combat, the same way it does for Warriors.
- Cat Form/precombat no longer push a bear into Cat Form (`!buff.bear_form.up` guards).

**Abilities added** (`Classes/Druid.lua`, top ranks for 3.3.5a)

| key | spell ID | notes |
|---|---|---|
| `bear_form` | 9634 | aura matches Dire Bear Form 9634 or Bear Form 5487 |
| `mangle_bear` | 48564 | 20 rage − Ferocity; cooldown 6 − 0.5 × Improved Mangle; Berserk resets its cooldown in prediction (see below) |
| `lacerate` | 48568 | 15 rage − Shredding Attacks; adds a stack, max 5, 15s |
| `swipe_bear` | 48562 | 20 rage − Ferocity |
| `maul` | 48480 | next swing, off the GCD, 15 rage − Ferocity; not suggested again while queued (existing `nextSwing` handling) |
| `demoralizing_roar` | 48560 | 10 rage; the aura also counts a Warrior's Demoralizing Shout 47437 (`anySource`) |
| `enrage` | 5229 | off the GCD, cooldown 60, +20 rage |
| `survival_instincts` | 61336 | off the GCD, cooldown 180 (added to `majorCooldowns`) |
| `barkskin` | 22812 | off the GCD, cooldown 60 |
| `frenzied_regeneration` | 22842 | defined but not used by the rotation |

- **Berserk + Mangle:** the engine's `ignoreCooldownWith` consumes a buff stack, which would wrongly
  remove Berserk, so it wasn't used. `mangle_bear.apply` instead resets its own cooldown when Berserk is
  up. In game, the client's real cooldown is read anyway.

**Priority** (`APLs/Druid_Feral.lua`, lists `bear` and `bear_aoe`)
- `bear`: Berserk (CD toggle) → Enrage when rage < `enrage_rage` → Survival Instincts < 30% HP /
  Barkskin < 50% HP (option `defensives`) → trinkets (CD toggle) → **Maul when rage ≥ `maul_rage`** (off
  the GCD, shown alongside) → AoE list at 3+ enemies → Mangle → Faerie Fire (Feral) on cooldown →
  Demoralizing Roar if missing (option `demo_roar`) → Lacerate if < 5 stacks or < 4s left → Swipe when
  rage ≥ `swipe_rage` → Lacerate.
- `bear_aoe`: Mangle during Berserk (3 targets, no cooldown) → Swipe → Demoralizing Roar → Mangle → Faerie
  Fire → Lacerate.
- **Why Swipe leads AoE and FF is on cooldown:** Whitemane raised Swipe (Bear)'s threat multiplier from
  1.5 to 1.65, Faerie Fire (Feral) bear threat by 10%, and the Bear Form threat bonus from 45% to 65%.
  (Frenzied Regeneration was also changed to 1% HP per rage in PvE only. It isn't in the rotation.)
- **Rotation options** (Feral): `maul_rage` 40, `swipe_rage` 40, `enrage_rage` 20 (0 never suggests it),
  `demo_roar` on, `defensives` on. The existing `not_behind` option is cat only.
- **Not covered:** no bear sim profile (`simPower` is per spec and Feral's is energy), so bear is checked
  by queue tests, not sim numbers. Threat-based choices (for example Maul vs Swipe with a co-tank) and
  Frenzied Regeneration usage were left out.


## 6. Fix (2026-10-10): blank display / recharging trinket at 5 combo points (cat)

**Reported in game:** (1) near the end of a mob with 5 combo points, the whole display went blank;
(2) on a dungeon boss, right after popping trinkets, the trinket was suggested again while on cooldown,
with Mangle after it.

**Cause (one bug, both symptoms):** the runner checks a line's condition at the moment the ability
becomes usable, not later. At 5 points with Rip/Savage Roar too short to Bite (< 8s) but not due (> 2s),
or on a mob dying too soon for Rip (Rip needs `time_to_die>10`, Bite needed Rip up), no cat line matched:
`shred,if=energy>80` is checked when Shred becomes affordable (~42 energy), so it never fired. With
nothing usable, the display was blank on trash; on bosses (CDs on) the unconditional `trinket1` line
won with a ~115s wait, followed by Mangle once the virtual debuff had expired by then. The gap existed in
the original upstream cat rotation too.

**Fix (`APLs/Druid_Feral.lua` only):**
- `ferocious_bite,if=combo_points=5&target.time_to_die<=10` right after the Rip line.
- At the end of the main list, a pooling block at 5 points: `variable pool` = min(Rip − 2s, Savage Roar −
  2s, `energy.time_to_80`), then `wait,sec=variable.pool`, then Savage Roar / Rip (`remains<2.1`, for
  float rounding at the wait's end) and Shred/Mangle at `energy>=75`. It replaces the old
  `shred/mangle_cat,if=energy>80` lines. The display now shows the next finisher counting down (or Shred
  when energy is about to cap) instead of going blank.

**Tests:** `tests/test_feral_gaps.lua`, registered after `test_feral` in `tests/run.lua`. It includes a sweep over combo points, energy,
Rip/Roar timers, time to die and the not-behind option, with a recharging trinket. It fails 6 checks on
the old rotation and all pass on the new one. Full suite: 590 passed, 1 failed (the known `test_fury`
rounding failure). Run this time with the upstream tests at the base commit plus mock spell entries for
the bear/Swipe IDs, using lupa in a uv venv.


## 7. DPS tuning with WoWSims (2026-10-11)

**Method:** the addon's cat priority was translated into a WoWSims WotLK rotation and simulated
against WoWSims' expert feral rotation (`tools/wowsims-feral/`). WoWSims already models this glyph:
WotLK Classic added a Glyph of Omen of Clarity (spell 206580) with the effect Whitemane describes.
Setup: P1 gear, the WoWSims standard talents, OoC + Shred + Rip glyphs, full raid buffs, the druid
keeping up Mangle and Faerie Fire, 3 minute fights, 10,000 fights per rotation, same seed. WoWSims'
pre-pull Clearcasting and Berserk were removed for a fair comparison.

| Rotation | DPS |
|---|---|
| WoWSims expert rotation | 7,666 |
| Addon before tuning | 7,486 (−2.3%) |
| **Addon after tuning** | **7,599 (−0.9%)**, +1.5% over before |

The gain held at +1.1% to +1.6% with pre-raid and P3 gear, 90 second and 5 minute fights, without
Glyph of Shred, without the Omen glyph, and with Mangle/Faerie Fire from someone else. (The Omen glyph
itself is worth about +15% DPS.)

**Changes kept** (each tested alone, then together):
- Ferocious Bite at 5 points when Rip and Savage Roar have over **5s** left (was 8s): +43.
- Rake only **once it's off** (was under 1s left): +33.
- At 5 points, **refresh Savage Roar early** when it would run out within 4s of Rip (Rip ≤ 10s
  left), so the new 34s Roar lasts past the next Rip: +25.
- With the glyph, **hold Shred/Rake for Faerie Fire** coming off cooldown in under 0.5s (energy
  under 80, no Clearcasting): +10.
- While pooling at 5 points, Shred from **70** energy (was 80): +9. Glyph Faerie Fire below **87**
  energy (was 90): +4.

**Tried and rejected:** Rip or Roar only after they fall off (−26 to −46); not spending Clearcasting
on Shred first (−62); no Bite with Clearcasting or above 67 energy (−82); Berserk on cooldown
instead of with Tiger's Fury (−16); holding Shred to save energy for Rake (−22); Tiger's Fury at 20
or 40 energy (no change); Bite energy caps (no gain).

**What's left (~1%):** WoWSims plans energy around every upcoming refresh at once and projects
Rip's length with Glyph of Shred extensions. That's hard to express as a priority list.


## 8. Bear tank tuning with WoWSims (2026-10-11)

**Method:** the bear lists were translated into WoWSims rotations and compared on threat per second
(TPS), with WoWSims' tank talents, P1 tank gear and glyphs (Maul, Survival Instincts, Frenzied
Regeneration), the druid keeping up its own Mangle, Faerie Fire and Demoralizing Roar, 3 minute fights.
WoWSims was patched with Whitemane's threat changes (`tools/wowsims-feral/whitemane-threat.patch`):
Bear Form ×1.65/1.45, Swipe (Bear) ×1.65 (WoWSims had 1.0; Whitemane says it was 1.5), Faerie Fire
(Feral) bonus threat 632 → 695. On several targets the measure is the **lowest** target's threat.

| Rotation | 1 target | 3 targets, lowest mob | 5 targets, lowest mob |
|---|---|---|---|
| WoWSims tank rotation | 6,230 | 204 (single-target only) | 391 |
| Addon before | 6,061 | 1,592 | 1,543 |
| **Addon after** | **6,249 (+3.1%)** | **1,763 (+10.7%)** | **1,709 (+10.8%)** |

Single target also: P3 gear +1.4%, stock WotLK threat +4.6%, 90s fights +3.2%; ahead of WoWSims'
rotation in each. (Whitemane's changes add ~15% single-target threat and ~80% Swipe AoE threat.)

**Changes kept:**
- **Wait for Mangle** when it's under 1s away instead of filling with Lacerate: +151 alone.
- **Wait for Faerie Fire** under 1.5s away before a filler Lacerate: +116 alone.
- **Maul from 25 rage** on 1–2 targets (was 40; option `maul_rage`); **40 on 3+** (new option
  `aoe_maul_rage`), where Swipe needs the rage.
- **AoE: Swipe on every GCD** — the "Mangle in Berserk" line was dropped (it cost the lowest mob 5–11%).

**Tried and not kept:** Faerie Fire above Mangle, Enrage on cooldown, Swipe from 25 rage (≤ +8 once
the above were in); refreshing Lacerate earlier (8s, or at 1.5s on top), Swipe above Lacerate, Maul at
50+ or Swipe at 60 (worse); Mangle or Demoralizing Roar first in AoE (worse for the lowest mob).

---

## 9. The Hekili look (2026-10-16)

The user asked for the display to look like Hekili "end to end": the icons, the cooldowns over
them, the whole feel. Hekili's UI.lua/Options.lua (the Cataclysm port at
`J:\reformat 9-5-24\wow\Interface\AddOns\Hekili`) and the user's own saved Hekili settings
(`WTF\Account\...\SavedVariables\Hekili.lua`: Primary 32px with a 30px queue 1px apart, AOE
display at +91,-140 in reactive mode, Cooldowns/Interrupts/Defensives displays) were the reference.

**What was built (UI/):**

- `Display.lua` rewritten around Hekili's button: the icon fills the button, a border frame sits
  outside it one frame level lower (1px black by default, class color optional), the texture is
  zoomed 30%, corner texts in Arial Narrow 12 outlined (keybind top right at (1,-1), delay top
  left, enemy count bottom right, caption bottom). Queued icons show their spell's **real**
  cooldown (GCD included, `GetSpellCooldown`); the main icon's swipe runs from the real
  cooldown/cast/GCD start to the predicted press time (Hekili's "extend"). Delay text/dot only when
  the wait is beyond that (`Moment`). Out of range = desaturated + red, unusable = grey
  (`IsUsableSpell`'s notEnoughMana too). `ButtonHilight-Square` while `IsCurrentSpell`.
  Enemy count follows Hekili's rules (1 in single mode, red/blue when forced).
- `Glow.lua`: Hekili's three glow styles for 3.3.5 (LibCustomGlow needs retail frame pools and
  mask textures): the autocast shine (4 rings x 4 sparkles from `UI-ItemSockets`, period 8s), a
  pixel glow (8 lines, own perimeter math, 2 textures per line instead of masks), and the game's
  own `ActionBarButtonSpellActivationAlert` (only shown/hidden, never animated out, so the frame
  never lands in Blizzard's overlay pool; a static ring stands in where the template is missing).
- `Mover.lua`: the unlocked look, a black 80% box with a class-colored 1px border and the display
  name in 18pt outlined text; drag moves, right-click opens the Display tab; grey border for a
  display that's off. `Display.Perimeter` picks the outermost buttons from the layout.
- `Notify.lua`: "Cooldowns: ON" etc. in gold Arial Narrow 20 at screen center, fading over 3s
  (`ns.Notify`). Chat still gets the message (tests and logs rely on it).
- `Interrupt.lua` is now its own movable display ("Interrupts", default -55,-225);
  `CooldownDisplay.lua` is new ("Cooldowns", default 0,-280): with `display.separateCooldowns`,
  `Recommender:Update` runs the main prediction with both cooldown toggles off and a second run
  with them on, and `RH.cooldownRecommendation` is the first `majorCooldowns` entry of that run.
- `AoEDisplay.lua`: `reactiveAoE` (Hekili's reactive mode) hides it below 3 enemies;
  `RH.detectedEnemies` (the count before the AoE mode's say) is set by the Recommender for the
  corner counts.
- Presets (`Display.PRESETS`, `/rh preset`, two buttons in the options): `hekili` (stock: 50px,
  5px gap, 3 icons, Hekili's positions) and `grambam` (the user's compact sizes/positions, dual
  display reactive). Values stay editable; `display.preset` remembers the last one for "Reset
  positions".
- Defaults are the stock Hekili look; our extras (status line, cast slot, proc badge, press
  flash, hold caption, in-range alternative, waste/threat borders, rune bar, cooldown strip,
  timeline) are kept as options, **off by default**. `queueScale` became `queueSize` (pixels),
  `noResources` default is Hekili's grey, `outOfRange` pure red.

**Not ported:** SpellFlash (flashing the action bar buttons; off by default in Hekili and a large
library), Masque support, Hekili's "captions" from the APL (our caption slot carries the hold
word), the per-element font pickers (one font size for all corners).

**Test harness notes:** `wowmock.lua`'s `geterrorhandler` now records and prints errors raised
inside Ace callbacks (module `OnEnable`, messages) instead of raising from the handler, which
`xpcall` silently swallowed; `testlib.newAddon` fails if loading raised any. It also sets
`numIcons = 4` after loading because the spec tests read four predictions (the default is 3).
That surfaced a fixture bug in `test_affliction.lua` (a string damage amount), fixed.

## Files changed

| File | Change |
|---|---|
| `RotationHelper/APLs/Druid_Feral.lua` | Glyph lines, cat `aoe` list, `bear` / `bear_aoe` lists, form switch, new options, header comments, rename |
| `RotationHelper/Classes/Druid.lua` | `swipe_cat`, bear abilities and auras, glyph Clearcasting on FF, form-aware `baseGcd`, `rageIncome`, helpers `BearCost` / `AddLacerate` / `InBearForm` |
| `RotationHelper/Engine/Cooldowns.lua`, `Engine/Sim.lua` | `baseGcd` may be a function |
| `RotationHelper/Engine/Recommender.lua` | AoE prediction pass and separate pools; `RH.aoeRecommendations` |
| `RotationHelper/Engine/State.lua` | Main display forced to single target in dual mode |
| `RotationHelper/UI/AoEDisplay.lua` | **New:** second display module |
| `RotationHelper/UI/Display.lua` | Status chip shows "ST" in dual mode |
| `RotationHelper/UI/Options.lua` | Dual display toggle, AoE size section, Reset position covers both |
| `RotationHelper/Core.lua` | Defaults, `ToggleDualDisplay`, `SetAoEScale`, `SetAoEIconCount`, slash commands and help, binding name |
| `RotationHelper/Bindings.xml` | `ROTATIONHELPER_TOGGLE_DUAL` |
| `RotationHelper/RotationHelper.toc` | Loads `UI\AoEDisplay.lua` after `UI\DisplayMouse.lua` |
| `tests/test_feral.lua` | Glyph tests, cat AoE tests, rotation name |
| `tests/test_feral_gaps.lua` | **New:** 5 combo point gap tests (section 6) |
| `tests/test_bear.lua` | **New:** bear tests |
| `tests/test_dual.lua` | **New:** dual display and AoE sizing tests |
| `tests/wowmock.lua` | Mock spell entries for Swipe (Cat) and the bear spells |
| `tests/run.lua` | Registers `test_feral_gaps`, `test_bear`, `test_dual` |
| `tools/wowsims-feral/` | **New:** rotation comparison against WoWSims (sections 7 and 8) |

> The glyph, cat AoE, bear and dual display tests were lost with the original session and rewritten
> on 2026-10-11. Each feature was broken on purpose once to check that a test fails.

## Testing

- **How the tests were run:** without a `lua` binary, using lupa (it bundles Lua 5.1; on WSL:
  `uv venv` then `uv pip install lupa`), plus a tiny Python runner that `chdir`s to the repo and
  `loadfile`s `tests/run.lua`.
- `tests/test_syntax.lua` uses `io.popen('dir /s /b ...')`, which is **Windows only**. It was skipped,
  and every addon `.lua` file was compiled with `loadfile` instead (116 files, 0 errors).
  `Bindings.xml` was checked as valid XML.
- **Result (2026-10-16, after the Hekili look):** 643 passed, 1 failed (the `test_fury` rounding
  case below). `test_review`'s garbage check sits right at its 16-byte limit under lupa and can
  flip either way.
- **Result (2026-10-11, all tests in this repo):** 618 passed, 1 failed (`test_syntax` skipped). The failure, `test_fury.lua` "rage: short on rage means waiting for
  the expected income" (expects +1.3, gets +1.2), **was already failing before any changes.** It looks
  like a rounding or floating-point difference, possibly specific to this Lua runtime, and it's
  unrelated to this work.

## Suggested next steps

1. **In-game check on Whitemane:** glyph detection (does `/rh` show `glyph.omen_of_clarity`?), the bear
   GCD (1.5) and rage income, Maul's queued state, and the AoE display's position and size.
2. Confirm the custom glyph's in-game name is exactly "Glyph of Omen of Clarity", since detection is by
   name.
3. Possibly add proc glow to the AoE display, and separate spacing/direction settings if the user asks.
4. Possibly add a bear sim profile (per-form `simPower`) to tune the Maul and Swipe rage thresholds.
5. Update the upstream README (support list, dual display, bear) if this goes upstream as a PR.
6. Whitemane said more class tweaks are coming. Check the news page and changelog for further Druid
   changes.
