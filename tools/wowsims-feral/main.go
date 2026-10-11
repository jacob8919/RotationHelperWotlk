// Runs feral cat rotations (APL JSON files) head to head with the same gear,
// talents, glyphs, buffs and seed, and prints DPS and casts per minute.
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
	"github.com/wowsims/wotlk/sim/druid/feral"
)

var names = map[int32]string{
	48566: "mangle", 48572: "shred", 48574: "rake", 49800: "rip", 52610: "roar", 48577: "bite",
	50213: "tf", 50334: "berserk", 16857: "ff", 768: "catform", 62078: "swipe",
}

func main() {
	gear := flag.String("gear", "ui/feral_druid/gear_sets/p1.gear.json", "gear set json")
	iters := flag.Int("iters", 3000, "iterations")
	dur := flag.Float64("dur", 180, "fight length, seconds")
	variation := flag.Float64("var", 15, "fight length +/- seconds")
	glyphs := flag.String("glyphs", "ooc,shred,rip", "major glyphs: ooc, shred, rip, berserk (comma separated), or none")
	selfDebuffs := flag.Bool("self", true, "the druid keeps up Mangle and Faerie Fire itself (no other raid members providing them)")
	seed := flag.Int64("seed", 101, "random seed")
	flag.Parse()

	feral.RegisterFeralDruid()

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
	}

	for _, aplPath := range flag.Args() {
		data, err := os.ReadFile(aplPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		spec := &proto.Player_FeralDruid{FeralDruid: &proto.FeralDruid{
			Options: &proto.FeralDruid_Options{
				InnervateTarget:   &proto.UnitReference{},
				LatencyMs:         100,
				AssumeBleedActive: false,
			},
			Rotation: &proto.FeralDruid_Rotation{},
		}}
		rsr := &proto.RaidSimRequest{
			Raid: core.SinglePlayerRaidProto(&proto.Player{
				Race:          proto.Race_RaceTauren,
				Class:         proto.Class_ClassDruid,
				Equipment:     core.EquipmentSpecFromJsonString(string(mustRead(*gear))),
				Consumes:      &proto.Consumes{},
				Spec:          spec,
				Buffs:         core.FullIndividualBuffs,
				TalentsString: "-503202132322010053120230310511-205503012",
				Glyphs:        g,
				Rotation:      core.APLRotationFromJsonString(string(data)),
				InFrontOfTarget: false,
			}, core.FullPartyBuffs, core.FullRaidBuffs, &debuffs),
			Encounter: &proto.Encounter{
				Duration:          *dur,
				DurationVariation: *variation,
				Targets:           []*proto.Target{core.NewDefaultTarget()},
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
		for _, a := range p.Actions {
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
		fmt.Printf("%-28s %8.1f dps  +/- %4.1f   | per min: %s\n", label, dps.Avg, dps.Stdev/math.Sqrt(float64(*iters)), strings.Join(parts, ", "))
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
