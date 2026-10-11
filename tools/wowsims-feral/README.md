# Feral rotations vs WoWSims

Compares the addon's Feral cat and bear tank priorities with WoWSims WotLK's
rotations, using WoWSims' damage and threat model. Our priority is translated into a
WoWSims rotation (APL) by `aplgen.py`, so each change can be tried in the sim
before it goes into `RotationHelper/APLs/Druid_Feral.lua`.

```
./setup.sh   # once: Go, protoc and WoWSims into ~/.cache/rotationhelper-wowsims (~1 minute)
./run.sh     # cat: WoWSims' rotation vs the addon before and after tuning, 10,000 fights
./run.sh -gear ui/feral_druid/gear_sets/p3.gear.json -dur 90   # other gear / fight length
./run.sh bear                 # bear tank threat, 1 and 3 targets
./run.sh bear -whitemane=false   # with stock WotLK threat values
```

**Whitemane threat:** `whitemane-threat.patch` (applied by `setup.sh`) adds
Whitemane Frostmourne's bear changes to WoWSims behind `-whitemane` (on by default):
Bear Form threat ×1.65/1.45 (their 45% → 65%), Swipe (Bear) threat multiplier 1.65,
Faerie Fire (Feral) bonus threat +10%. For bears the tool prints threat per second,
and on several targets the lowest target's share (what matters for holding a pack).
WoWSims' default boss barely hits in this setup, so damage taken isn't compared.

`feralcmp` options: `-spec` (`cat` or `tank`), `-targets`, `-whitemane`, `-gear` (WoWSims gear set JSON; `preraid`, `p1` to `p4`), `-dur`
and `-var` (fight length and its +/- in seconds), `-glyphs` (`ooc,shred,rip,berserk,maul,survivalinstincts,frenziedregen`,
three of them; cat default `ooc,shred,rip`, tank `maul,survivalinstincts,frenziedregen`), `-self=false` (someone else keeps up Mangle, Faerie Fire and the attack power debuff), `-iters`,
`-seed`. Every rotation runs with the same seed, so the differences between them are
more precise than the +/- shown.

To try an idea, add an option to `addon()` (cat) or `bear()` in `aplgen.py`, add a variant with it
to `run.sh`, and compare. The setup: a Tauren with the WoWSims standard talents (cat or tank), P1 gear,
full raid buffs, 100 ms latency, no consumables, 3 minute fights (+/- 15 s).

**Limits:** WoWSims runs the first usable line of a priority list; the addon shows
the line that becomes usable soonest. That's the same thing for a player who presses
the icon as soon as it's ready, but conditions are checked at slightly different
moments. The Glyph of Omen of Clarity in WoWSims (WotLK Classic, spell 206580) has
the effect Whitemane describes for its glyph.
