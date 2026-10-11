// Runs feral rotations (APL JSON files) head to head with the same gear,
// talents, glyphs, buffs and seed, and prints DPS (and for bears TPS and
// damage taken) and casts per minute. -spec tank for Feral bear tanking.
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"

	_ "github.com/wowsims/wotlk/sim/common"
	"github.com/wowsims/wotlk/sim/core"
	"github.com/wowsims/wotlk/sim/core/proto"
	"github.com/wowsims/wotlk/sim/druid"
	"github.com/wowsims/wotlk/sim/druid/feral"
	"github.com/wowsims/wotlk/sim/druid/tank"
)

var names = map[int32]string{
	48566: "mangle", 48572: "shred", 48574: "rake", 49800: "rip", 52610: "roar", 48577: "bite",
	50213: "tf", 50334: "berserk", 16857: "ff", 768: "catform", 62078: "swipe",
	48564: "mangle", 48568: "lacerate", 48562: "swipe", 48480: "maul", 48560: "demoroar", 5229: "enrage",
	61336: "survinst", 22812: "barkskin",
}

func main() {
	spec := flag.String("spec", "cat", "cat (Feral DPS) or tank (Feral bear tank)")
	gear := flag.String("gear", "", "gear set json (default: p1 for the spec)")
	whitemane := flag.Bool("whitemane", true, "Whitemane Frostmourne's bear threat changes")
	targets := flag.Int("targets", 1, "number of targets")
	iters := flag.Int("iters", 3000, "iterations")
	dur := flag.Float64("dur", 180, "fight length, seconds")
	variation := flag.Float64("var", 15, "fight length +/- seconds")
	glyphs := flag.String("glyphs", "", "major glyphs: ooc, shred, rip, berserk, maul, survivalinstincts, frenziedregen (comma separated); default by spec")
	selfDebuffs := flag.Bool("self", true, "the druid keeps up its own debuffs (Mangle, Faerie Fire, and for bears the attack power reduction)")
	seed := flag.Int64("seed", 101, "random seed")
	flag.Parse()

	feral.RegisterFeralDruid()
	tank.RegisterFeralTankDruid()
	druid.WhitemaneThreat = *whitemane
	isTank := *spec == "tank"
	if *gear == "" {
		*gear = map[bool]string{false: "ui/feral_druid/gear_sets/p1.gear.json", true: "ui/feral_tank_druid/gear_sets/p1.gear.json"}[isTank]
	}
	if *glyphs == "" {
		*glyphs = map[bool]string{false: "ooc,shred,rip", true: "maul,survivalinstincts,frenziedregen"}[isTank]
	}

	g := &proto.Glyphs{Minor1: int32(proto.DruidMinorGlyph_GlyphOfTheWild)}
	slots := []*int32{&g.Major1, &g.Major2, &g.Major3}
	n := 0
	for _, name := range strings.Split(*glyphs, ",") {
		var id proto.DruidMajorGlyph
		switch strings.TrimSpace(name) {
		case "ooc":
			id = proto.DruidMajorGlyph_GlyphOfOmenOfClarity
		case "shred":
			id = proto.DruidMajorGlyph_GlyphOfShred
		case "rip":
			id = proto.DruidMajorGlyph_GlyphOfRip
		case "berserk":
			id = proto.DruidMajorGlyph_GlyphOfBerserk
		case "savageroar":
			id = proto.DruidMajorGlyph_GlyphOfSavageRoar
		case "maul":
			id = proto.DruidMajorGlyph_GlyphOfMaul
		case "survivalinstincts":
			id = proto.DruidMajorGlyph_GlyphOfSurvivalInstincts
		case "frenziedregen":
			id = proto.DruidMajorGlyph_GlyphOfFrenziedRegeneration
		default:
			continue
		}
		*slots[n] = int32(id)
		n++
	}

	debuffs := *core.FullDebuffs
	if *selfDebuffs {
		debuffs.Mangle = false
		debuffs.FaerieFire = proto.TristateEffect_TristateEffectMissing
		debuffs.CurseOfWeakness = proto.TristateEffect_TristateEffectMissing
		debuffs.DemoralizingRoar = proto.TristateEffect_TristateEffectMissing
		debuffs.DemoralizingShout = proto.TristateEffect_TristateEffectMissing
		debuffs.Vindication = false
		debuffs.DemoralizingScreech = false
	}

	for _, aplPath := range flag.Args() {
		data, err := os.ReadFile(aplPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		var playerSpec interface{}
		talents := "-503202132322010053120230310511-205503012"
		if isTank {
			playerSpec = &proto.Player_FeralTankDruid{FeralTankDruid: &proto.FeralTankDruid{
				Options: &proto.FeralTankDruid_Options{InnervateTarget: &proto.UnitReference{}, StartingRage: 20},
			}}
			talents = "-503232132322010353120300313511-20350001"
		} else {
			playerSpec = &proto.Player_FeralDruid{FeralDruid: &proto.FeralDruid{
				Options: &proto.FeralDruid_Options{
					InnervateTarget:   &proto.UnitReference{},
					LatencyMs:         100,
					AssumeBleedActive: false,
				},
				Rotation: &proto.FeralDruid_Rotation{},
			}}
		}
		player := &proto.Player{
			Race:            proto.Race_RaceTauren,
			Class:           proto.Class_ClassDruid,
			Equipment:       core.EquipmentSpecFromJsonString(string(mustRead(*gear))),
			Consumes:        &proto.Consumes{},
			Buffs:           core.FullIndividualBuffs,
			TalentsString:   talents,
			Glyphs:          g,
			Rotation:        core.APLRotationFromJsonString(string(data)),
			InFrontOfTarget: isTank,
		}
		switch s := playerSpec.(type) {
		case *proto.Player_FeralTankDruid:
			player.Spec = s
		case *proto.Player_FeralDruid:
			player.Spec = s
		}
		raid := core.SinglePlayerRaidProto(player, core.FullPartyBuffs, core.FullRaidBuffs, &debuffs)
		if isTank {
			raid.Tanks = []*proto.UnitReference{{Type: proto.UnitReference_Player, Index: 0}}
		}
		encounterTargets := []*proto.Target{}
		for i := 0; i < *targets; i++ {
			encounterTargets = append(encounterTargets, core.NewDefaultTarget())
		}
		rsr := &proto.RaidSimRequest{
			Raid: raid,
			Encounter: &proto.Encounter{
				Duration:          *dur,
				DurationVariation: *variation,
				Targets:           encounterTargets,
			},
			SimOptions: &proto.SimOptions{Iterations: int32(*iters), RandomSeed: *seed},
		}
		res := core.RunRaidSim(rsr)
		if res.ErrorResult != "" {
			fmt.Fprintln(os.Stderr, aplPath, res.ErrorResult)
			os.Exit(1)
		}
		p := res.RaidMetrics.Parties[0].Players[0]
		dps := p.Dps
		casts := map[string]float64{}
		targetThreat := make([]float64, *targets)
		for _, a := range p.Actions {
			for _, tm := range a.Targets {
				if int(tm.UnitIndex) < len(targetThreat) {
					targetThreat[tm.UnitIndex] += tm.Threat
				}
			}
			id := a.Id.GetSpellId()
			if name, ok := names[id]; ok {
				for _, t := range a.Targets {
					casts[name] += float64(t.Casts)
				}
			}
		}
		minutes := res.AvgIterationDuration / 60 * float64(*iters)
		keys := make([]string, 0, len(casts))
		for k := range casts {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := []string{}
		for _, k := range keys {
			parts = append(parts, fmt.Sprintf("%s %.1f", k, casts[k]/minutes))
		}
		label := strings.TrimSuffix(aplPath[strings.LastIndex(aplPath, "/")+1:], ".apl.json")
		if isTank {
			tps := p.Threat
			perTarget := ""
			if *targets > 1 {
				// Each target's share of the total threat (threat not aimed at a target is spread evenly).
				sum := 0.0
				for _, v := range targetThreat {
					sum += v
				}
				lowest, list := math.Inf(1), []string{}
				for _, v := range targetThreat {
					share := tps.Avg * v / sum
					lowest = math.Min(lowest, share)
					list = append(list, fmt.Sprintf("%.0f", share))
				}
				perTarget = fmt.Sprintf("  lowest target %6.0f tps (%s)", lowest, strings.Join(list, "/"))
			}
			fmt.Printf("%-24s %7.1f tps +/- %4.1f %7.1f dps%s | per min: %s\n", label, tps.Avg,
				tps.Stdev/math.Sqrt(float64(*iters)), dps.Avg, perTarget, strings.Join(parts, ", "))
		} else {
			fmt.Printf("%-28s %8.1f dps  +/- %4.1f   | per min: %s\n", label, dps.Avg, dps.Stdev/math.Sqrt(float64(*iters)), strings.Join(parts, ", "))
		}
	}
}

func mustRead(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return data
}
