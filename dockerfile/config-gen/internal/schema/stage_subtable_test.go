package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A sub-table of a stage is modelled as one table member: the header
// `["stage:dev".deploy]` and the dotted `deploy.gpu_mode = ...` inside
// `["stage:dev"]` both give the stage one member `deploy` of kind
// MemberTable whose own Members hold `gpu_mode`, and no flat scalar
// member (base#1443, design r1 cycle 14, r3 cycle 17 a48/a53). A decode
// that keeps only the stage's flat scalar rows drops the sub-table.
//
// Expected values: the bridge on a48 and a53 (p1443 bridge.out, rc 0
// both, `--kv` `stage:dev.deploy\tgpu_mode\toff`, `--tables`
// `stage:dev|stage:dev.deploy`; json.out a48 `{"stage:dev": {"deploy":
// {"gpu_mode": "off"}}}`): one stage `dev` holding one table `deploy`
// that holds one key `gpu_mode` = `off`. Neither is refused (bridge rc
// 0; `_setup_known_key deploy gpu_mode -> 0`, p1443 known.out). Lines
// are counted from the fixture bytes: the header form opens the stage
// and the table on line 1 with the key on line 2; the dotted form opens
// the stage on line 1 and writes the table and the key on line 2.
func TestDecodeStageSubTableIsATableMember(t *testing.T) {
	cases := []struct {
		file      string
		stageLine int
		tableLine int
	}{
		{"s7_stage_subtable_header.toml", 1, 1},
		{"s7_stage_subtable_dotted.toml", 1, 2},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			files := testcorpus.Glob(t, "corpus/s7/"+c.file)
			if len(files) != 1 {
				t.Fatalf("Glob = %v, want %s", files, c.file)
			}
			src, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}

			cfg, refusals := Decode(src)

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %+v, want none", refusals)
			}
			if cfg == nil {
				t.Fatal("Decode returned no Config")
			}
			if len(cfg.Stages) != 1 {
				t.Fatalf("Stages = %+v, want exactly one", cfg.Stages)
			}
			s := cfg.Stages[0]
			if s.Name != "dev" || s.Line != c.stageLine {
				t.Errorf("stage = {Name %q, Line %d}, want {Name \"dev\", Line %d}", s.Name, s.Line, c.stageLine)
			}
			if len(s.Members) != 1 {
				t.Fatalf("Members = %+v, want exactly one (the table deploy)", s.Members)
			}
			m := s.Members[0]
			if m.Key != "deploy" || m.Kind != MemberTable || m.Line != c.tableLine {
				t.Errorf("Members[0] = {Key %q, Kind %v, Line %d}, want {Key \"deploy\", MemberTable, Line %d}",
					m.Key, m.Kind, m.Line, c.tableLine)
			}
			if m.Table == nil {
				t.Fatal("Members[0].Table = nil, want the deploy table")
			}
			if len(m.Table.Members) != 1 {
				t.Fatalf("deploy Members = %+v, want exactly one", m.Table.Members)
			}
			k := m.Table.Members[0]
			if k.Key != "gpu_mode" || k.Kind != MemberScalar || k.Line != 2 || k.Value.Text != "off" {
				t.Errorf("deploy Members[0] = {Key %q, Kind %v, Line %d, Text %q}, want {Key \"gpu_mode\", MemberScalar, Line 2, Text \"off\"}",
					k.Key, k.Kind, k.Line, k.Value.Text)
			}
		})
	}
}
