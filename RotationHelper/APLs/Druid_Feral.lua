local ADDON_NAME, ns = ...

-- Default Feral (cat) Druid priority for 3.3.5a:
--   Faerie Fire and Mangle debuffs (anyone's count) > Savage Roar (even at 1
--   point) > Rip at 5 points > Rake > Ferocious Bite at 5 points when Rip and
--   Savage Roar have long left (or the target is about to die) > Shred to
--   build points > at 5 points, pool for the next Rip or Savage Roar
--   (Shredding rather than capping energy)
-- Mangle instead of Shred when you can't get behind (a setting).
-- Tiger's Fury when low on energy, Berserk with the big cooldowns.
-- With Whitemane's Glyph of Omen of Clarity: Faerie Fire on cooldown for a
-- guaranteed Clearcasting, spent on Shred straight away.
-- 3+ enemies: Savage Roar, then Swipe (Cat).
--
-- In Bear Form (Dire Bear Form) the bear tanking priority runs instead, so
-- the same rotation covers cat DPS and bear tanking; just shift.
--   Mangle (Bear) on cooldown > Faerie Fire (Feral) on cooldown >
--   Demoralizing Roar (anyone's, a Warrior's shout too) > Lacerate to 5
--   stacks and before it runs out > Swipe (Bear) with spare rage > Lacerate
-- Maul goes on the next swing with spare rage (off the GCD, next to the
-- others). 3+ enemies: Swipe (Bear) first, Mangle on 3 targets in Berserk.
-- Whitemane buffed Swipe (Bear), Faerie Fire (Feral) and the Bear Form
-- threat bonus, so Swipe is a strong AoE threat button there.
ns.RegisterAPL("DRUID", "feral_combat", "Feral cat & bear (default)", [[
## Out of combat
actions.precombat=cat_form,if=!buff.cat_form.up&!buff.bear_form.up
actions.precombat+=/potion,if=toggle.cooldowns&pull.active&pull.remains<=1.5&!buff.bear_form.up

## Main priority
# Bear Form: the tanking priority.
actions=run_action_list,name=bear,if=buff.bear_form.up
actions+=/cat_form,if=!buff.cat_form.up
# Big cooldowns follow the CD toggle (bosses only by default).
actions+=/call_action_list,name=cooldowns,if=toggle.cooldowns
# Energy (used on trash too).
actions+=/tigers_fury,if=toggle.short_cooldowns&energy<30
actions+=/run_action_list,name=aoe,if=active_enemies>=3
actions+=/faerie_fire_feral,if=!debuff.faerie_fire.up
actions+=/mangle_cat,if=!debuff.mangle.up
actions+=/savage_roar,if=buff.savage_roar.remains<2
actions+=/rip,if=combo_points=5&dot.rip.remains<2&target.time_to_die>10
# Dying before a Rip would finish: Bite instead.
actions+=/ferocious_bite,if=combo_points=5&target.time_to_die<=10
# Glyph of Omen of Clarity (Whitemane): spend Clearcasting on Shred right away,
# so Faerie Fire's 6 second cooldown can proc it again.
actions+=/shred,if=glyph.omen_of_clarity.enabled&buff.clearcasting.up&!option.not_behind&combo_points<5
actions+=/mangle_cat,if=glyph.omen_of_clarity.enabled&buff.clearcasting.up&option.not_behind&combo_points<5
actions+=/rake,if=dot.rake.remains<1&target.time_to_die>9
# ...and Faerie Fire on cooldown for a free Clearcasting (not when about to cap energy).
actions+=/faerie_fire_feral,if=glyph.omen_of_clarity.enabled&talent.omen_of_clarity.enabled&!buff.clearcasting.up&energy<90
actions+=/ferocious_bite,if=combo_points=5&dot.rip.remains>8&buff.savage_roar.remains>8
actions+=/shred,if=!option.not_behind&combo_points<5
actions+=/mangle_cat,if=option.not_behind&combo_points<5
# At 5 points, Rip and Savage Roar too short for Bite but not due yet: pool
# energy until whichever runs out first, or Shred before energy caps. Lines
# are checked when they become usable, so without the wait nothing here would
# match and the display would go blank (or show a recharging trinket).
actions+=/variable,name=pool,value=dot.rip.remains-2,if=combo_points=5
actions+=/variable,name=pool,op=min,value=buff.savage_roar.remains-2,if=combo_points=5
actions+=/variable,name=pool,op=min,value=energy.time_to_80,if=combo_points=5
actions+=/wait,sec=variable.pool,if=combo_points=5
# (2.1, not 2: the wait ends at 2 seconds left, give or take rounding.)
actions+=/savage_roar,if=combo_points=5&buff.savage_roar.remains<2.1
actions+=/rip,if=combo_points=5&dot.rip.remains<2.1&target.time_to_die>10
actions+=/shred,if=!option.not_behind&energy>=75
actions+=/mangle_cat,if=option.not_behind&energy>=75

## Cooldowns
actions.cooldowns=berserk,if=buff.tigers_fury.up|cooldown.tigers_fury.remains>15
actions.cooldowns+=/berserking
actions.cooldowns+=/trinket1
actions.cooldowns+=/trinket2
actions.cooldowns+=/potion,if=buff.bloodlust.up|buff.berserk.up|target.time_to_die<30

## 3+ targets
# Savage Roar up (it boosts Swipe too), building its point with Mangle,
# then Swipe. With the glyph, Faerie Fire's Clearcasting makes a Swipe free.
actions.aoe=savage_roar,if=buff.savage_roar.remains<2&combo_points>=1
actions.aoe+=/mangle_cat,if=buff.savage_roar.remains<2&combo_points=0
actions.aoe+=/swipe_cat,if=buff.clearcasting.up
actions.aoe+=/faerie_fire_feral,if=glyph.omen_of_clarity.enabled&talent.omen_of_clarity.enabled&!buff.clearcasting.up&energy<90
actions.aoe+=/swipe_cat

## Bear tanking
actions.bear=berserk,if=toggle.cooldowns
actions.bear+=/enrage,if=toggle.short_cooldowns&rage<option.enrage_rage
# Defensives when health gets low (a setting).
actions.bear+=/survival_instincts,if=option.defensives&health.pct<30
actions.bear+=/barkskin,if=option.defensives&health.pct<50
actions.bear+=/trinket1,if=toggle.cooldowns
actions.bear+=/trinket2,if=toggle.cooldowns
# Spare rage goes into the next swing.
actions.bear+=/maul,if=rage>=option.maul_rage
actions.bear+=/run_action_list,name=bear_aoe,if=active_enemies>=3
actions.bear+=/mangle_bear
actions.bear+=/faerie_fire_feral
actions.bear+=/demoralizing_roar,if=option.demo_roar&!debuff.demoralizing_roar.up
actions.bear+=/lacerate,if=debuff.lacerate.stack<5|debuff.lacerate.remains<4
actions.bear+=/swipe_bear,if=rage>=option.swipe_rage
actions.bear+=/lacerate

## Bear, 3+ targets
actions.bear_aoe=mangle_bear,if=buff.berserk.up
actions.bear_aoe+=/swipe_bear
actions.bear_aoe+=/demoralizing_roar,if=option.demo_roar&!debuff.demoralizing_roar.up
actions.bear_aoe+=/mangle_bear
actions.bear_aoe+=/faerie_fire_feral
actions.bear_aoe+=/lacerate
]], {
    { key = "not_behind", name = "Not behind the target", type = "toggle", default = false,
      desc = "Mangle instead of Shred, e.g. on a boss you can't get behind." },
    { key = "maul_rage", name = "Bear: Maul at rage", type = "range", default = 40, min = 15, max = 100, step = 5,
      desc = "Queue Maul from this much rage. Lower it when rage comes in fast." },
    { key = "swipe_rage", name = "Bear: Swipe filler at rage", type = "range", default = 40, min = 15, max = 100, step = 5,
      desc = "On one target, Swipe (Bear) as filler from this much rage (otherwise Lacerate)." },
    { key = "enrage_rage", name = "Bear: Enrage below rage", type = "range", default = 20, min = 0, max = 100, step = 5,
      desc = "Use Enrage when rage is below this (0 never suggests it)." },
    { key = "demo_roar", name = "Bear: keep Demoralizing Roar up", type = "toggle", default = true,
      desc = "Turn off when another tank or a Warrior keeps the attack power debuff up." },
    { key = "defensives", name = "Bear: defensives at low health", type = "toggle", default = true,
      desc = "Survival Instincts below 30% health, Barkskin below 50%." },
})
