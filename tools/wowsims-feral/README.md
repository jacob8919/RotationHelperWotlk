# Feral cat rotation vs WoWSims

Compares the addon's Feral cat priority with WoWSims WotLK's expert feral
rotation, using WoWSims' damage model. Our priority is translated into a
WoWSims rotation (APL) by `aplgen.py`, so each change can be tried in the sim
before it goes into `RotationHelper/APLs/Druid_Feral.lua`.

```
./setup.sh   # once: Go, protoc and WoWSims into ~/.cache/rotationhelper-wowsims (~1 minute)
./run.sh     # WoWSims' rotation vs the addon before and after tuning, 10,000 fights
./run.sh -gear ui/feral_druid/gear_sets/p3.gear.json -dur 90   # other gear / fight length
```

`feralcmp` options: `-gear` (WoWSims gear set JSON; `preraid`, `p1` to `p4`), `-dur`
and `-var` (fight length and its +/- in seconds), `-glyphs` (`ooc,shred,rip,berserk`,
three of them), `-self=false` (someone else keeps up Mangle and Faerie Fire), `-iters`,
`-seed`. Every rotation runs with the same seed, so the differences between them are
more precise than the +/- shown.

To try an idea, add an option to `addon()` in `aplgen.py`, add a variant with it
to `run.sh`, and compare. The setup: a Tauren with the WoWSims standard talents, P1 gear,
full raid buffs, 100 ms latency, no consumables, 3 minute fights (+/- 15 s).

**Limits:** WoWSims runs the first usable line of a priority list; the addon shows
the line that becomes usable soonest. That's the same thing for a player who presses
the icon as soon as it's ready, but conditions are checked at slightly different
moments. The Glyph of Omen of Clarity in WoWSims (WotLK Classic, spell 206580) has
the effect Whitemane describes for its glyph.
