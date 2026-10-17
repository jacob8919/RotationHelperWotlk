# RotationHelper

A Hekili-style rotation helper for **World of Warcraft 3.3.5a** (WotLK), made on Whitemane.
It shows the ability to press next and predicts the few after it, from a priority list you can
tune, read and edit in game.

- **All 23 DPS specs** (plus Blood tanking), each with a default rotation.
- **Looks ahead**: runes, runic power, energy and rage regeneration, cast times with haste,
  cooldowns, procs, DoTs, totems, Auto Shot timing, and channels that can be cut short.
- **Tunable without code**: rotation settings (Heroic Strike rage, which curse, Envenom points,
  ...), cooldown and potion toggles, bosses only, AoE mode.
- **Feedback**: a fight review after each fight, waste and threat warnings, a pre-pull
  checklist.
- **Your own rotation**: an in-game editor with syntax checking, a simulator to compare
  versions, and sharing with your group.

## Supported specs

| Class | Specs | Notes |
|---|---|---|
| Death Knight | Frost, Unholy, Blood | Blood tanks in Frost Presence (Rune Strike, Rune Tap, Vampiric Blood). Pestilence spreads diseases in AoE. |
| Paladin | Retribution | First come, first served priority; which Judgement to use is a setting. |
| Warrior | Fury, Arms | Heroic Strike / Cleave on the next swing with spare rage; the rage countdown learns your income during the fight. |
| Shaman | Enhancement, Elemental | Maelstrom Weapon, shocks, totems; the checklist wants weapon imbues. |
| Priest | Shadow | DoTs kept up; Mind Flay is cut after a tick for Mind Blast or a DoT refresh. |
| Mage | Fire, Arcane, Frost | Hot Streak, Arcane Blast stacks and mana, Fingers of Frost and Brain Freeze. |
| Warlock | Affliction, Destruction, Demonology | Your curse is a setting; Backdraft, Molten Core and Decimation; Drain Soul cut for Haunt. |
| Druid | Balance, Feral (cat) | Eclipse; cat energy, Savage Roar, Rip, Clearcasting. |
| Rogue | Combat, Assassination, Subtlety | Energy countdown, combo points, poisons on the checklist; Subtlety pools energy for Shadow Dance. |
| Hunter | Marksmanship, Survival, Beast Mastery | Steady Shot timed around Auto Shot, Lock and Load, Kill Command; the checklist wants your pet out. |

Frost Death Knight has been checked in game the most. Every other spec is built from the
class's 3.3.5 mechanics, offline tests and the simulator. If something looks off, see
[Something looks wrong?](#something-looks-wrong). [docs/SPECS.md](docs/SPECS.md) has details per
spec.

## Install

1. Download the latest `RotationHelper-x.y.z.zip` from
   [Releases](https://github.com/rynosuki/RotationHelperWotlk/releases).
2. Extract it into `World of Warcraft\Interface\AddOns\`, so you have
   `Interface\AddOns\RotationHelper\RotationHelper.toc`.
3. Restart the game (a new addon needs a full restart, `/reload` isn't enough) and make sure
   RotationHelper is ticked under AddOns at character select.

## First steps

1. Log in. Sample icons with your own class's spells appear below the middle of the screen, each
   display under a box with its name (Primary, AOE, Interrupts, Cooldowns, Notifications).
2. Drag the boxes where you want them, then type `/rh lock`.
3. Target a training dummy and fight. The big icon is what to press now; the small icons are
   what comes after it, if you follow along.
4. `/rh` opens the options. Check the **Rotation** tab for your spec's settings.

## Reading the display

The display is drawn like Hekili's: a row of icons, each with a thin border, the keybind in the
top-right corner and a cooldown sweep, and on the main icon the enemy count and the delay.

| What you see | Meaning |
|---|---|
| First icon | The ability to use next. |
| Icons after it | The predicted next abilities, in order. |
| Sweep on the first icon | Not usable yet (GCD, cooldown, resources): it runs out when you can press. |
| Sweep on the other icons | That spell's real cooldown, the GCD included, as on your action bars. |
| Number in the top-left corner (`1.2`) | The rotation is holding the ability longer than the sweep shows (runes, a proc, a DoT to refresh): seconds until it says to press. |
| Number in the bottom-right corner | How many enemies the rotation is counting. `1` in single-target mode. Red: fewer are around than it assumes (forced AoE). Blue: more (forced single target). |
| Text in the top-right corner | The key the ability is bound to (default bars, Bartender, Dominos, ElvUI, ...). |
| Sparkles orbiting the first icon | That ability spends a proc (Killing Machine, Hot Streak, Bloodsurge, ...). The style and color are settings. |
| Bright square highlight | The first icon's spell is the one you're casting or have queued. |
| Grey icon | Not enough resources (runes, energy, rage, mana). |
| Red, washed-out icon | Your target is out of range for it. |
| Icon in the Interrupts display | Your target is casting something you can interrupt. |
| Icon in the Cooldowns display | With "Cooldowns display" on: the next major cooldown to use (they leave the main row). |
| Icons in the AOE display | With the dual display: the rotation for 3+ enemies, next to the single-target one. |
| Gold text in the middle of the screen (`Cooldowns: ON`) | A toggle changed; it fades out. |
| `Missing: ...` under the icons | Out of combat with a boss or elite targeted: what you still need before the pull. |
| Red `!` left of the icons | The addon hit an error; see `/rh errors`. |

Unlock the display (`/rh lock`) and each display gets a dark box with its name: drag the box to
move it, right-click it for the display settings.

Hold **Shift** over the locked display to hover an icon for why it's recommended (the rotation
line, what it waits on).

The extras under **Display > Extras** add things Hekili doesn't have (all off by default):

| What you see | Meaning |
|---|---|
| `RUNES` / `RAGE` / `ENERGY` / `COOLDOWN` / `CAST` / `AUTO` / `WAIT` at the bottom of the first icon | It's more than a GCD away; this is what it waits on. |
| Icon sliding out to the left of the first one, shrinking | The spell you're casting or channelling, with its time left; it's gone when the cast lands. |
| Proc icon in the corner | That proc is *why* the ability is recommended now. |
| Flash on the first icon | The moment its ability can be pressed. |
| Small icon below the status line | The first icon is out of range; this is the best thing you can do from where you are. |
| Pulsing orange border, `RUNES` / `RP` / `ENERGY` / `RAGE` on the status line | Resources are going to waste: a full rune pair, or runic power, energy or rage near the cap. |
| Steady red border, `THREAT` | In a group: you're close to pulling aggro. |
| `CD` / `POT` under the first icon | Cooldowns / potions. Green: suggested now. Yellow: on, waiting for a boss. Red: off. Shift-click toggles them. |
| `ST` / `AOE` / a number | The AoE mode forced to single target or AoE, or (auto) how many enemies are counted. Shift-click cycles it. |
| `2/4 DIS`, `2/4 CORR` | With several enemies: how many carry your diseases (Death Knight) or Corruption (Affliction). |

Under **Display** you can pick a layout preset (**Hekili (stock)**: 50px icons, three in a row;
**Grambam (compact)**: a 32px main icon with 30px queue icons, the AoE display to the right and only
shown with 3+ enemies), then change the icon sizes, spacing, direction, zoom, border, font size,
the glow style, the delay style, colors (including a color-blind friendly preset), and turn on the
extras: a rune bar for Death Knights, a strip of your major cooldowns and trinkets, and a
**timeline** that places the queued icons by when they can be used.

Random procs are never assumed; the icons update as soon as one happens.

## Settings worth knowing

- **Rotation settings** (Rotation tab, top): thresholds and choices of your spec's rotation, such
  as Heroic Strike rage, Arcane Blast mana %, which curse, Envenom at 4 or 5 points, "not
  behind the target" for Feral and Subtlety, Gargoyle's burst wait, hunter aspect mana %. They
  apply right away.
- **Cooldowns and potions**: big cooldowns, trinkets, racials and potions only show with `CD` /
  `POT` on, and by default only in boss fights. Short cooldowns that are part of the rotation
  (Shadow Dance, Tiger's Fury, Unbreakable Armor, ...) are used on trash too. A boss is a
  skull-level target, anything while boss frames are up, or a name on the built-in list (ICC, ToC,
  Naxxramas, Ulduar, the WotLK dungeons); add more under General > Extra bosses.
- **Trinkets**: only use effects that help damage are suggested; General > Trinkets shows how
  yours were read and can change that.
- **Latency** (General): the next ability is shown slightly early, by your lag tolerance, so you
  can queue it.
- **AoE**: with 3 or more enemies the AoE priority takes over. Enemies are counted from the
  combat log (3.3.5 addons can't read nameplates): anything you or your pet hit, that hits you,
  or that has your debuff, until 6 seconds after the last of these. `/rh aoe` forces single
  target or AoE.
- **Profiles**: settings and custom rotations are per profile, and the Profiles tab can switch
  profile with your talent spec (dual spec).

## Before the pull

- **Checklist**: with a boss or elite targeted out of combat, the display lists what's missing:
  flask or elixir, food, and what your class needs: Horn of Winter, your presence and ghoul
  (Death Knights), stance (Warriors), weapon imbues or poisons (Shamans, Rogues), your pet or
  demon (Hunters, Warlocks).
- **Pull timer**: with a DBM or BigWigs pull timer (or `/rh pull 10`), the rotation suggests a
  potion right at the pull (Army of the Dead about 10 seconds out for Death Knights).
- **Burst windows**: rotations can hold a cooldown for a burst buff (Bloodlust, Hyperspeed
  Accelerators, trinket procs, ...). Unholy holds Summon Gargoyle for one, 15 seconds at most by
  default. More buffs can be added on the General tab.

## Fight review

Every fight longer than 20 seconds is reviewed. `/rh review` (or the General tab) shows it,
graded green, yellow or red; "Show after each fight" pops it up by itself.

- **Time spent casting** while there was something to press.
- **Following the icons**: how many casts matched one of the first two icons.
- **Resources**: runic power, energy or rage at the cap and rune pairs sitting full; for mana
  users, time below 10% mana.
- **Procs used** before they ran out, and **DoT / disease uptime**.
- **Cooldowns left unused** and the **biggest mistakes**, e.g.
  `0:42 Frost Strike instead of Obliterate (ready)`.

The last 10 fights are kept per character; the arrows in the title bar browse them.

## Editing the rotation

`/rh apl` opens the editor. Rotations are SimC-style action priority lists; see
[docs/APL.md](docs/APL.md) for every name you can use. A short example:

```
actions=icy_touch,if=dot.frost_fever.remains<2
actions+=/obliterate
actions+=/frost_strike,if=buff.killing_machine.up|runic_power.deficit<25
```

- The editor checks the rotation as you type: "Compiles", or the first error with its line
  marked red. **Accept** saves it only if it compiles.
- **Names** lists everything you can use for your class and talents, including the rotation's
  settings (`option.NAME`); click one to insert it.
- **Export** / **Import** a one-line `RH1:` string, or **Share** it with your party, raid or a
  player (they're asked first, and nothing is saved without their Accept).
- **Revert to default** discards your version.

## Simulating a rotation

**Simulate** on the Rotation tab (or `/rh sim`) plays the rotation for 5 fights of 5 minutes with
your talents and glyphs and random procs, and reports time spent casting, resources wasted, DoT
uptime, procs used and casts per minute. Use it to compare versions, e.g. before and after
moving a line.

After some fighting, `/rh damage` shows what each ability hits for with your gear, and the
simulator uses it to estimate damage per minute. Reset it after a big gear change
(`/rh damage reset`).

## Commands

| Command | What it does |
|---|---|
| `/rh` | Open the options (also under Interface > AddOns). |
| `/rh apl` | Open the rotation editor. |
| `/rh lock` | Lock or unlock the display. |
| `/rh cd` / `/rh pots` | Toggle cooldowns / potions. |
| `/rh aoe` | Cycle the AoE mode: auto > single > aoe. |
| `/rh pause` | Pause or resume. |
| `/rh set <key> [value]` | A rotation setting, for macros: `/rh set not_behind` flips "Not behind the target", `/rh set hs_rage 60` sets a number, `/rh set curse doom` picks a value. `/rh set` alone lists your spec's settings with their keys. |
| `/rh test` | Show or hide sample icons. |
| `/rh scale <0.5-3>` / `/rh icons <1-5>` | Display scale / number of icons. |
| `/rh preset hekili` / `/rh preset grambam` | Layout preset: Hekili's stock look, or the compact one. |
| `/rh review [n]` | The last fight review, or saved fight n. |
| `/rh pull <seconds>` | Start a pull timer (0 cancels). |
| `/rh sim [seconds]` | Simulate the active rotation. |
| `/rh damage` | Your damage per ability (`/rh damage reset` starts over). |
| `/rh snapshot` | Everything the addon reads from the game, its prediction and why. |
| `/rh why <ability>` | Why an ability is or isn't recommended now, e.g. `/rh why frost strike`. |
| `/rh keys` | The keybinds found for your spells. |
| `/rh report` | A bug report to copy into a GitHub issue. |
| `/rh errors` | Recorded addon errors (`/rh errors clear` empties the list). |
| `/rh perf` | What the addon costs in CPU and memory. |
| `/rh version` | Your version, and whether a newer one has been seen. |
| `/rh status` / `/rh help` | Current settings / all commands. |

The toggles can also be bound to keys (Escape > Key Bindings > RotationHelper). The minimap
button opens the options (left click) and toggles cooldowns (right click).

## Updates

Addons can't go online, so RotationHelper compares versions with guild and group members who
run it, like DBM does. When someone has a newer version you get one message per session and a
box with the [download link](https://github.com/rynosuki/RotationHelperWotlk/releases) to copy.
"Tell me about new versions" on the General tab turns it off.

## Something looks wrong?

Type `/rh report` right when it happens (or General tab > "Create a bug report"), press Ctrl+C
and paste it into a [new issue](https://github.com/rynosuki/RotationHelperWotlk/issues/new?template=bug_report.md)
with what you expected. It includes your spec, talents, settings, what the addon sees and
decides at that moment, and recent errors.

To look yourself: `/rh snapshot` prints what the addon reads and one line per rotation entry
explaining why it was or wasn't chosen; `/rh why <ability>` does it for one ability.
[docs/TESTING.md](docs/TESTING.md) lists what to check when you first play a spec.

## Development

Plain Lua 5.1, with Ace3 r960 (the 3.3.5 release) bundled in `RotationHelper/Libs`. Tests run
outside the game against a mocked WoW API, with the real Ace3 libraries:

```
lua tests/run.lua
```

(Lua 5.1 is needed, e.g. `winget install -e --id rjpcomputing.luaforwindows`.)

`lua tests/sim.lua <spec> [--runs N] [--seconds N] [--enemies N] default my.apl` compares
rotations side by side. Adding a spec or class: [docs/ADDING_A_SPEC.md](docs/ADDING_A_SPEC.md).
Rotation language: [docs/APL.md](docs/APL.md). Progress: [docs/SPECS.md](docs/SPECS.md) and
[docs/ROADMAP.md](docs/ROADMAP.md).

## License

MIT License: see [LICENSE](LICENSE). The bundled Ace3 libraries have their own license
([RotationHelper/Libs/Ace3-LICENSE.txt](RotationHelper/Libs/Ace3-LICENSE.txt)).
