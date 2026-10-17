# Adding a spec or class

This guide covers adding a rotation for another Death Knight spec (just data and an APL), and
what a new class needs, including the engine work for classes that don't use runes.

## How the pieces fit

```
Classes/<Class>.lua        class data: abilities (IDs, costs, cooldowns, effects) and tracked auras
APLs/<Class>_<Spec>.lua    the default priority list for a spec
Engine/Spec.lua            detects the spec (tree with most points), talents, glyphs, known spells
Engine/State.lua           snapshot of the game each update, and the virtual copy for prediction
  Resources/Auras/Cooldowns/Targets.lua   the readers the snapshot uses
Engine/Abilities.lua       when an ability becomes usable (ReadyAt) and what using it does (Apply)
Engine/Expressions.lua     binds APL names (buff.x.up, runes.frost, ...) to the state
APL/Lexer,Parser,Compiler  turn APL text into Lua functions
APL/Runner.lua             picks the action usable soonest, ties to priority
Engine/Recommender.lua     runs it all every update and fills the queue
UI/Display, Keybinds, Options
```

Load order is in `RotationHelper.toc`: class files after `Core.lua`, APL files after the `APL/`
modules, `Engine/Recommender.lua` after the APL files.

## A new Death Knight spec

All three Death Knight specs are done: [APLs/DeathKnight_Blood.lua](../RotationHelper/APLs/DeathKnight_Blood.lua)
and [tests/test_blood.lua](../tests/test_blood.lua) are the most recent worked example of these steps
(the Blood examples below show how it was done).

### 1. Add missing abilities and auras

Open [Classes/DeathKnight.lua](../RotationHelper/Classes/DeathKnight.lua) and add anything the
spec uses. For Blood that's e.g. Heart Strike, Hysteria, Rune Tap, Vampiric Blood and Dancing
Rune Weapon. Use the **highest rank** spell ID from a WotLK spell database (3.3.5's
`GetSpellInfo` doesn't return spell IDs, so they can't be looked up in game). The addon checks
them: at login it prints `Unknown spell IDs in class data: ...` for any ID the client doesn't know.

Ability fields (all optional except `id`):

| Field | Meaning |
|---|---|
| `id` | spell ID, highest rank |
| `runes` | `{ blood = 1, frost = 1, unholy = 1 }` |
| `rp` | runic power: positive costs it, negative generates it |
| `rpCost(spec)` / `rpGain(spec)` | when talents or glyphs change the cost or gain |
| `cooldown` | seconds; abilities with one get their cooldown read from the game |
| `offGcd` | `true` if it doesn't trigger the GCD |
| `freeWith` | a buff key that makes it free (and is used up), like Rime for Howling Blast |
| `consumes` | buff keys it uses up, e.g. `{ "killing_machine" }` |
| `convert` | death rune conversion: `{ runes = { blood = true }, talents = { "blood_of_the_north" } }` |
| `requiresPet` | `true` if it needs a living pet, like Ghoul Frenzy |
| `mana` | mana cost in % of base mana (set `baseMana` in the class data); in game the client's real cost is used |
| `cooldownFn(spec)` | the cooldown with talents or glyphs, e.g. Improved Judgements; used by the prediction |
| `variants` + `variant` | several spells behind one key, chosen in the options (Judgement of Light / Wisdom / Justice); every variant counts as a cast |
| `rage` / `rageCost(spec)` / `rageGain(spec)` | rage cost and gain (set `rageIncome` in the class data: rage per second until the fight shows the real income) |
| `nextSwing` | an on-next-swing attack (Heroic Strike): not suggested again while queued (`IsCurrentSpell`) |
| `requiresForm` | the stance or form it needs (`GetShapeshiftForm()` index); skipped otherwise |
| `usableWith` | a buff that also makes a `reactive` ability usable (Overpower with Taste for Blood) |
| `blockedBy` | a buff that forbids the ability while it's up (Tiger's Fury during Berserk); it's suggested once the buff ends |
| `cooldownGroup` | abilities sharing one cooldown (the Shaman shocks) |
| `totem` + `totemDuration` | a totem of that element (set `usesTotems` in the class data) |
| `castTime` / `channel` | cast or channel time in base seconds (set `hasteProbe` in the class data: an ability with a fixed `castTime` whose hasted cast time gives your spell haste) |
| `castTimeFn(spec, state)` | the base cast time when talents or buffs change it (Improved Fireball; Missile Barrage) |
| `manaFn(spec, state, baseMana)` | a mana cost that depends on the state (Arcane Blast stacks) |
| `instantWith` | a buff that makes the cast instant and is used up (Hot Streak for Pyroblast) |
| `energy` / `energyCost(spec)` | energy cost (set `energyRegen(spec)` in the class data, and `energyBoosts = { { aura, factor }, ... }` for buffs that speed it up (overlapping ones multiply); `baseGcd = 1` for a 1 second GCD) |
| `energyGain(spec)` | energy it gives (Tiger's Fury); set `freeCostAura` (Clearcasting: the next ability is free) and `costBuff = { aura, factor }` (Berserk) in the class data for class-wide cost changes |
| `comboGain` / `finisher` | builders add combo points; finishers need one and use them all (`s.comboPointsSpent` in their `apply`) |
| `avoidAutoClip` | a cast that waits for the next Auto Shot rather than delaying it, when waiting is cheaper (set `autoShot = true` in the class data) |
| `ignoreCooldownWith` | a buff with charges that lets the ability skip its cooldown (Lock and Load); one charge is used |
| `usesStack` | uses one charge of a buff with charges (Fingers of Frost) |
| `reactive` | `true` if it's only usable when the game says so (`IsUsableSpell`), like Rune Strike after a dodge or parry; using it makes it unusable in the prediction |
| `apply(state, spec, fx)` | other effects, for the prediction; see below |

Trinkets (`trinket1`, `trinket2`), `potion` and the DPS racials (`blood_fury`, `berserking`,
`arcane_torrent`) come from [Classes/Shared.lua](../RotationHelper/Classes/Shared.lua) and are
added to every class, so don't repeat them. Put them in the spec's cooldowns list; lines for
things the player doesn't have are skipped.

`apply` gets the virtual state and helpers from `Abilities.Effects`:
`fx.ApplyBuff(s, key, duration)`, `fx.ApplyDebuff(s, key, duration)`, `fx.RemoveBuff(s, key)`,
`fx.DebuffUp(s, key)`, `fx.ActivateAllRunes(s)`, `fx.BloodTap(s)`, `fx.SummonPet(s)`. Add a helper there if a new
mechanic needs one. Only model what the rotation's conditions look at; the prediction doesn't need
damage.

Auras: `key = { id = N }` (or `ids = { ... }` for several ranks or equivalent buffs), with
`debuff = true` for debuffs on the target. Debuffs only count when you applied them, unless
`anySource = true`. `onPlayer = true` is for a harmful aura on yourself that should read like a buff
(Arcane Blast's stacks); set `hasPlayerDebuffs` in the class data. Auras are also matched by localized name, so a wrong rank ID still works for
reading, but fix it anyway. `partOf = "group"` makes an aura also count as a group aura
(declared as `group = {}`): every Paladin seal is `partOf = "seal"`, so `buff.seal.up` means any seal.

A new class also needs `gcdSpell` (a spell with no cooldown of its own), and for the simulator
`simPower = { type, max, start, regen }` when it doesn't start at 0 runic power (or one per spec: `{ elemental = {...}, enhancement = {...} }`)
([Classes/Paladin.lua](../RotationHelper/Classes/Paladin.lua) is the example).

### 2. Write the APL

Create `APLs/DeathKnight_Blood.lua`:

```lua
local ADDON_NAME, ns = ...

ns.RegisterAPL("DEATHKNIGHT", "blood", "Blood (default)", [[
actions.precombat=horn_of_winter,if=!buff.horn_of_winter.up
actions=icy_touch,if=dot.frost_fever.remains<2
actions+=/plague_strike,if=dot.blood_plague.remains<2
actions+=/heart_strike
actions+=/death_coil,if=runic_power.deficit<20
...
]])
```

The spec key is the talent tree's name in lowercase (`blood`, `frost`, `unholy`). Add the file to
`RotationHelper.toc` next to the other APLs, and set `specs.blood = true` in the class data.

Thresholds players may want to change become settings: pass a list as the fifth argument and
read them as `option.NAME` (see [APL.md](APL.md#settings)). They appear on the Rotation tab.

```lua
ns.RegisterAPL("WARRIOR", "fury", "Fury (default)", [[
actions+=/heroic_strike,if=rage>=option.hs_rage
]], {
    { key = "hs_rage", name = "Heroic Strike at rage", type = "range", default = 50, min = 20, max = 100, step = 5,
      desc = "Shown as the tooltip." },
    -- type = "toggle" (default true/false) or "select" (values = { key = "Label", ... })
})
```

The fastest way to develop the list is the in-game editor (`/rh apl`, pick the spec): it compiles
on Accept and shows errors with line and column. Paste the result into the file when it works.
See [APL.md](APL.md) for the syntax and every name you can use.

### 3. Test it

Offline tests live in `tests/` and run with `lua tests/run.lua`.

- Add the new spell IDs and names to `session.spells` in [tests/wowmock.lua](../tests/wowmock.lua),
  so the class data resolves offline. The test "Death Knight class data resolves every spell ID"
  catches missing ones.
- Write scenario tests like [tests/test_frost.lua](../tests/test_frost.lua): set up runes, runic
  power, auras and cooldowns, then assert the recommendation (`Recommend(s)`) or the predicted
  queue (see [tests/test_predict.lua](../tests/test_predict.lua)).
- A test that the default APL compiles with no errors, like the Frost one. It catches typos in
  names before you log in.
- Add the new test file to the `SUITES` list in [tests/run.lua](../tests/run.lua).

In game, check with `/rh snapshot` on a training dummy: that the new auras and cooldowns show up,
that nothing important is under "Not in spellbook", and that the trace picks what you expect.

### 4. Tune it with the simulator

- If the spec has random procs its rotation reacts to, add them to the class data's `simProcs`:
  `{ aura = "x", duration = 15, on = { ability = true }, chance = function(spec) ... end }` for a
  chance when an ability is used, or `perMinute = function(spec) ... end` for random times.
  `resetCooldown = "ability"` resets a cooldown when the proc happens.
- Add a typical build for the spec to `BUILDS` in [tests/sim.lua](../tests/sim.lua).
- Compare versions side by side: `lua tests/sim.lua unholy default my_version.apl`. Look for
  higher time spent casting, less rune and runic power waste, diseases near 100%, and few wasted
  procs. The class data's `reviewDebuffs` lists the debuffs whose uptime is reported.
- `lastAuraGroup = { "lunar_eclipse", "solar_eclipse" }` remembers which of those buffs came last
  (`last.lunar_eclipse`); simulator procs can have an internal cooldown (`icd`).
- `reviewDebuffs` can also be per spec: `{ arms = { "rend" } }`.
- `spreadDots` lists the dots tracked on other enemies (`active_dot.X`, `diseased_enemies`);
  an ability's `apply` calls `fx.SpreadDots(s, duration)` to spread them in the prediction.
- `trackDots = { affliction = { "corruption", ..., hint = "CORR" } }` tracks a spec's dots on
  other enemies too (`active_dot.X`), with "2/4 CORR" (the first key) on the status line.
- A channel with `ticks = N` can be cut short after any tick when something above it in the
  rotation is due (`channel` is the whole duration).
- `gcdFn = function(spec, state, gcd) return shorter end` shortens an ability's GCD (Backdraft);
  it never goes below 1 second.

## A new class

### Class data

Create `Classes/<Class>.lua` calling `ns.RegisterClass("CLASSTOKEN", { ... })`, where the token is
the second return of `UnitClass("player")` (e.g. `"WARRIOR"`). Required fields:

| Field | Meaning |
|---|---|
| `gcdSpell` | a spell with no cooldown of its own; its cooldown is read as the GCD |
| `specs` | `{ arms = true, fury = false, ... }` |
| `abilities`, `auras` | as above |
| `usesRunes` | only for Death Knights |

The addon loads for any class that registers data; others stay idle.

### What the engine doesn't model yet

The engine was built around Death Knights. Runes and runic power are fully modelled; other
resources are **read** (`state.power`, `state.powerMax`, `state.powerType`) but not simulated:

- **Costs**: `Abilities.ReadyAt` checks rune costs and the `rp` cost. For mana, rage or energy,
  generalize `rp`/`rpCost` into a cost in the class's power type, and check it the same way.
- **Regeneration**: runic power doesn't regenerate, so `ReadyAt` treats "not enough" as "never".
  Energy (rogues, feral cats) regenerates at a known rate: `ReadyAt` should compute when enough
  will have come in, and `Abilities.Apply` should add regeneration when moving time forward.
  Rage comes from taking and dealing damage, so it can't really be predicted; treating it like
  runic power (no regeneration) is a reasonable start.
- **Combo points**: read them in `Engine/Resources.lua` (`GetComboPoints("player", "target")`), add
  `combo_points` to `Expressions.SIMPLE`, and let finishers set them to 0 in `Apply`.
- **APL names**: `runic_power*` are Death Knight names. Add the class's resource names (`energy`,
  `rage`, `mana.pct`, ...) to `SIMPLE` in [Engine/Expressions.lua](../RotationHelper/Engine/Expressions.lua).
- **Pets and totems**, **stances/forms** (`GetShapeshiftForm()`), **swing timers** and **cast
  times** (the snapshot reads the current cast, but abilities have no cast time yet) would need
  support as the rotations call for them.

Each of these is an addition next to the existing Death Knight code rather than a rewrite: the
snapshot, virtual state, APL language, runner and display are class-independent.

## Checklist

- [ ] Abilities and auras in `Classes/<Class>.lua`, with `apply` effects for anything the APL checks
- [ ] `APLs/<Class>_<Spec>.lua` registered, and listed in `RotationHelper.toc`
- [ ] `specs.<spec> = true`
- [ ] Spell IDs added to the test mock; the class data test passes
- [ ] A test that the default APL compiles, plus scenario tests
- [ ] In game: no "Unknown spell IDs" message at login, `/rh snapshot` looks right on a dummy
