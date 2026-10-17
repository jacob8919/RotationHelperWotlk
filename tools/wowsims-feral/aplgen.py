"""Builds WoWSims APL JSON for feral cat rotation variants.

Spell IDs: Mangle (Cat) 48566, Shred 48572, Rake 48574, Rip 49800, Savage Roar 52610,
Ferocious Bite 48577, Tiger's Fury 50213, Berserk 50334, Faerie Fire (Feral) 16857,
Clearcasting 16870; Faerie Fire debuff 770.
"""
import json, os, sys

MANGLE, SHRED, RAKE, RIP, ROAR, BITE, TF, BERSERK, FF, CC, FFDEBUFF = (
    48566, 48572, 48574, 49800, 52610, 48577, 50213, 50334, 16857, 16870, 770)

def const(v): return {"const": {"val": str(v)}}
def sec(v): return const(f"{v}s")
def cmp(op, l, r): return {"cmp": {"op": op, "lhs": l, "rhs": r}}
def lt(l, r): return cmp("OpLt", l, r)
def le(l, r): return cmp("OpLe", l, r)
def gt(l, r): return cmp("OpGt", l, r)
def ge(l, r): return cmp("OpGe", l, r)
def eq(l, r): return cmp("OpEq", l, r)
def AND(*v): return {"and": {"vals": list(v)}}
def OR(*v): return {"or": {"vals": list(v)}}
def NOT(v): return {"not": {"val": v}}
energy = {"currentEnergy": {}}
cp = {"currentComboPoints": {}}
fight_left = {"remainingTime": {}}
def buff(id): return {"auraIsActive": {"auraId": {"spellId": id}}}
def buff_left(id): return {"auraRemainingTime": {"auraId": {"spellId": id}}}
def debuff(id): return {"auraIsActive": {"sourceUnit": {"type": "CurrentTarget"}, "auraId": {"spellId": id}}}
def dot(id): return {"dotIsActive": {"spellId": {"spellId": id}}}
def dot_left(id): return {"dotRemainingTime": {"spellId": {"spellId": id}}}
def cd_left(id): return {"spellTimeToReady": {"spellId": {"spellId": id}}}
def cast(id, cond=None):
    a = {"castSpell": {"spellId": {"spellId": id}}}
    if cond is not None: a["condition"] = cond
    return {"action": a}

def apl(lines):
    return {"type": "TypeAPL",
            "prepullActions": [],
            "priorityList": [{"action": {"autocastOtherCooldowns": {}}}] + lines}

def write(name, lines, outdir):
    with open(os.path.join(outdir, name + ".apl.json"), "w") as f:
        json.dump(apl(lines), f)

# The addon's cat priority (APLs/Druid_Feral.lua) as it was before the WoWSims tuning of
# 2026-10-11, with the glyph and CDs on. Each option switches on one of the tuned changes
# (or another idea to try); run.sh's "addon_tuned" is the current rotation.
def addon(o=None):
    o = dict(dict(
        bite_rip=8, bite_roar=8,       # Bite when Rip and Roar have this long left
        rip_refresh=2,                 # Rip when it has less than this left
        roar_refresh=2,
        ff_energy=90,                  # glyph Faerie Fire below this energy
        cc_shred_first=True,           # Clearcasting Shred above Rake
        bite_no_cc=False, bite_max_energy=None,
        pool_shred=80,                 # at 5 points, Shred from this energy while waiting
        rake_refresh=1,
        berserk_rule="tf",             # "tf": with Tiger's Fury up or TF far away; "cd": on cooldown
        tf_energy=30,                  # Tiger's Fury below this energy (None: never)
        tf_cc=0,                       # ...and this much lower with Clearcasting up
        tf_berserk_block=False,        # the addon's "not during Berserk" (WoWSims forbids it anyway)
        ff_avoid_rip=False,            # don't FF when Rip is due and affordable
        roar_desync=None,              # don't refresh Roar at 5 points within N seconds of Rip
        wait_ff=None,                  # hold Shred/Rake when FF is ready within this many seconds (energy below wait_ff_energy)
        wait_ff_energy=80,
        berserk_bite_energy=None,      # during Berserk, Bite only at or below this energy
        roar_clip=None,                # (leeway, max rip left): at 5 points refresh Roar early when it ends near Rip
        rake_reserve=False,            # hold Shred so Rake can be refreshed the moment it drops
    ), **(o or {}))
    hold = None
    if o["wait_ff"] is not None:
        hold = AND(lt(cd_left(FF), sec(o["wait_ff"])), gt(cd_left(FF), sec(0)), lt(energy, const(o["wait_ff_energy"])), NOT(buff(CC)))
    L = []
    if o["berserk_rule"] == "tf":
        L.append(cast(BERSERK, OR(buff(TF), gt(cd_left(TF), sec(15)))))
    else:
        L.append(cast(BERSERK))
    if o["tf_energy"] is not None:
        tfc = [lt(energy, const(o["tf_energy"]))]
        if o["tf_cc"]:
            tfc = [OR(AND(NOT(buff(CC)), lt(energy, const(o["tf_energy"]))),
                      AND(buff(CC), lt(energy, const(o["tf_energy"] - o["tf_cc"]))))]
        if o["tf_berserk_block"]: tfc.append(NOT(buff(BERSERK)))
        L.append(cast(TF, AND(*tfc)))
    L.append(cast(FF, NOT(debuff(FFDEBUFF))))
    L.append(cast(MANGLE, NOT(debuff(MANGLE))))
    L.append(cast(ROAR, AND(ge(cp, const(1)), lt(buff_left(ROAR), sec(o["roar_refresh"])))))
    if o["roar_clip"]:
        leeway, maxrip = o["roar_clip"]
        # Roar ends no later than Rip + leeway, Rip ends soon enough that a 34s Roar lasts well past it.
        L.append(cast(ROAR, AND(eq(cp, const(5)), dot(RIP), le(dot_left(RIP), sec(maxrip)),
                                OR(*[AND(ge(dot_left(RIP), sec(r)), le(buff_left(ROAR), sec(r + 1 + leeway)))
                                     for r in range(0, maxrip + 1)]),
                                gt(fight_left, sec(20)))))
    L.append(cast(RIP, AND(eq(cp, const(5)), lt(dot_left(RIP), sec(o["rip_refresh"])), gt(fight_left, sec(10)))))
    L.append(cast(BITE, AND(eq(cp, const(5)), le(fight_left, sec(10)))))
    if o["cc_shred_first"]:
        L.append(cast(SHRED, AND(buff(CC), lt(cp, const(5)))))
    rk = [lt(dot_left(RAKE), sec(o["rake_refresh"])), gt(fight_left, sec(9))]
    if hold is not None: rk.append(NOT(hold))
    L.append(cast(RAKE, AND(*rk)))
    ffc = [NOT(buff(CC)), lt(energy, const(o["ff_energy"]))]
    if o["ff_avoid_rip"]:
        ffc.append(NOT(AND(eq(cp, const(5)), lt(dot_left(RIP), sec(o["rip_refresh"] + 1)))))
    L.append(cast(FF, AND(*ffc)))
    bc = [eq(cp, const(5)), gt(dot_left(RIP), sec(o["bite_rip"])), gt(buff_left(ROAR), sec(o["bite_roar"]))]
    if o["bite_no_cc"]: bc.append(NOT(buff(CC)))
    if o["bite_max_energy"] is not None: bc.append(lt(energy, const(o["bite_max_energy"])))
    if o["berserk_bite_energy"] is not None:
        bc.append(OR(NOT(buff(BERSERK)), le(energy, const(o["berserk_bite_energy"]))))
    L.append(cast(BITE, AND(*bc)))
    sh = [lt(cp, const(5))]
    if hold is not None: sh.append(NOT(hold))
    if o["rake_reserve"]:
        # Hold Shred when Rake (35) drops before energy covers Shred (37) + Rake: rake_left < (72 - energy) / 10.
        holds = []
        for e in range(0, 72, 4):
            holds.append(AND(ge(energy, const(e)), lt(energy, const(e + 4)), dot(RAKE),
                             lt(dot_left(RAKE), sec(round((72 - e) / 10, 2)))))
        sh.append(NOT(AND(NOT(buff(CC)), OR(*holds))))
    L.append(cast(SHRED, AND(*sh)))
    L.append(cast(SHRED, ge(energy, const(o["pool_shred"]))))
    return L

# ---------------------------------------------------------------------------
# Bear tanking (the addon's actions.bear / actions.bear_aoe lists)
# ---------------------------------------------------------------------------
MANGLE_BEAR, LACERATE, SWIPE_BEAR, MAUL, DEMO, ENRAGE, SURV, BARK = (
    48564, 48568, 48562, 48480, 48560, 5229, 61336, 22812)
rage = {"currentRage": {}}
health_pct = {"currentHealthPercent": {}}
lac_stacks = {"auraNumStacks": {"sourceUnit": {"type": "CurrentTarget"}, "auraId": {"spellId": LACERATE}}}
targets = {"numberTargets": {}}
def maul(cond=None):
    a = {"castSpell": {"spellId": {"spellId": MAUL, "tag": 1}}}
    if cond is not None: a["condition"] = cond
    return {"action": a}
def wait_for(id, within):
    return {"action": {"condition": AND({"gcdIsReady": {}}, NOT({"spellIsReady": {"spellId": {"spellId": id}}}),
                                        lt(cd_left(id), sec(within))),
                       "wait": {"duration": cd_left(id)}}}

def bear(o=None):
    o = dict(dict(
        maul_rage=40, maul_first=True,   # Maul at this rage, above (True) or below the GCD abilities
        aoe_maul_rage=None,              # 3+ targets: Maul at this rage instead
        swipe_rage=40,                   # single target: Swipe from this rage
        lac_refresh=4,                   # Lacerate when under 5 stacks or under this many seconds
        lac_top_refresh=None,            # a top-priority Lacerate refresh at 5 stacks under N seconds
        mangle_wait=None,                # wait for Mangle when it's this close
        ff_wait=None,                    # wait for Faerie Fire when it's this close
        demo=True, enrage_rage=20, defensives=True,
        swipe_over_lacerate=False,       # single target: Swipe (with rage) above the Lacerate refresh
        aoe=None,                        # 3+ targets: list order of the bear_aoe list
        ff_before_mangle=False,
    ), **(o or {}))
    L = []
    L.append(cast(BERSERK))
    if o["enrage_rage"]:
        L.append(cast(ENRAGE, lt(rage, const(o["enrage_rage"]))))
    if o["defensives"]:
        L.append(cast(SURV, lt(health_pct, const("30%"))))
        L.append(cast(BARK, lt(health_pct, const("50%"))))
    if o["maul_first"]:
        if o["aoe_maul_rage"] is None:
            L.append(maul(ge(rage, const(o["maul_rage"]))))
        else:
            L.append(maul(AND(lt(targets, const(3)), ge(rage, const(o["maul_rage"])))))
            L.append(maul(AND(ge(targets, const(3)), ge(rage, const(o["aoe_maul_rage"])))))
    # 3+ targets: the bear_aoe list (run_action_list: nothing below it then).
    aoe = []
    for name in (o["aoe"] or ["mangle_berserk", "swipe", "demo", "mangle", "ff", "lacerate"]):
        if name == "mangle_berserk": aoe.append(cast(MANGLE_BEAR, buff(BERSERK)))
        elif name == "swipe": aoe.append(cast(SWIPE_BEAR))
        elif name == "demo": aoe.append(cast(DEMO, NOT(debuff(DEMO))))
        elif name == "mangle": aoe.append(cast(MANGLE_BEAR))
        elif name == "ff": aoe.append(cast(FF))
        elif name == "lacerate": aoe.append(cast(LACERATE))
    for a in aoe:
        a["action"]["condition"] = AND(ge(targets, const(3)), a["action"]["condition"]) if "condition" in a["action"] else ge(targets, const(3))
        L.append(a)
    st = []
    if o["lac_top_refresh"] is not None:
        st.append(cast(LACERATE, AND(eq(lac_stacks, const(5)), le(dot_left(LACERATE), sec(o["lac_top_refresh"])))))
    if o["ff_before_mangle"]:
        st.append(cast(FF))
    st.append(cast(MANGLE_BEAR))
    if o["mangle_wait"] is not None:
        st.append(wait_for(MANGLE_BEAR, o["mangle_wait"]))
    if not o["ff_before_mangle"]:
        st.append(cast(FF))
    if o["demo"]:
        st.append(cast(DEMO, NOT(debuff(DEMO))))
    if o["swipe_over_lacerate"]:
        st.append(cast(SWIPE_BEAR, ge(rage, const(o["swipe_rage"]))))
    st.append(cast(LACERATE, OR(lt(lac_stacks, const(5)), lt(dot_left(LACERATE), sec(o["lac_refresh"])))))
    if not o["swipe_over_lacerate"]:
        st.append(cast(SWIPE_BEAR, ge(rage, const(o["swipe_rage"]))))
    if o["ff_wait"] is not None:
        st.append(wait_for(FF, o["ff_wait"]))
    st.append(cast(LACERATE))
    if not o["maul_first"]:
        st.append(maul(ge(rage, const(o["maul_rage"]))))
    # Single-target lines only below 3 targets.
    for a in st:
        a["action"]["condition"] = AND(lt(targets, const(3)), a["action"]["condition"]) if "condition" in a["action"] else lt(targets, const(3))
        L.append(a)
    if not o["maul_first"]:
        L.append(maul(ge(rage, const(o["maul_rage"]))))
    return L

def write_bear(name, lines, outdir):
    with open(os.path.join(outdir, name + ".apl.json"), "w") as f:
        json.dump(apl(lines), f)

def main_bear(outdir, variants):
    write_bear("bear_original", bear(), outdir)
    for name, opts in variants.items():
        write_bear(name, bear(opts), outdir)


if __name__ == "__main__":
    # aplgen.py OUTDIR [VARIANTS_JSON]           cat variants
    # aplgen.py --bear OUTDIR [VARIANTS_JSON]    bear variants
    args = sys.argv[1:]
    is_bear = bool(args) and args[0] == "--bear"
    if is_bear: args = args[1:]
    outdir = args[0]
    variants = json.loads(args[1]) if len(args) > 1 else {}
    if is_bear:
        main_bear(outdir, variants)
    else:
        write("addon_original", addon(), outdir)
        for name, opts in variants.items():
            write(name, addon(opts), outdir)
