package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A field that takes a single value accepts a string or any other TOML
// scalar: a number, a float, a bool, a date or a date-time, each kept
// in its entry with its TOML kind and the bridge's text for it -- a
// date as its literal text, an offset date-time as Python's str() of it
// (base#1443 review round 1 finding 4, design r1 cycle 8). Only a list
// or a table is refused (TestDecodeEntryFieldListOrTableIsRefused); a
// check that took a non-string scalar for a list or a table, or that
// read only string fields, refuses one of these.
//
// Expected values: main's dockerfile/toml_bridge.py `--kv` on each
// fixture, rc 0 (scratchpad r1/bridge.out): `network port_1 8080:80`,
// `volumes mount_1 1:/d`, `volumes mount_1 1979-05-27:/d`,
// `image rule_1 1979-05-27 07:32:00+00:00`, `build arg_1 A=1.5`,
// `build arg_1 A=true`; each field's text is the part of that row it
// contributes, its kind the TOML kind written in the fixture.
func TestDecodeEntryScalarFieldOfAnyKindIsKept(t *testing.T) {
	type field struct {
		key  string
		kind Kind
		text string
	}
	cases := []struct {
		file   string
		family string
		want   []field
	}{
		{"s7_accept_ports_int.toml", "network.ports", []field{{"host", KindInt, "8080"}, {"container", KindInt, "80"}}},
		{"s7_accept_volume_int.toml", "volumes", []field{{"source", KindInt, "1"}, {"target", KindString, "/d"}}},
		{"s7_accept_volume_date.toml", "volumes", []field{{"source", KindLocalDate, "1979-05-27"}, {"target", KindString, "/d"}}},
		{"s7_accept_rule_datetime.toml", "image.rules", []field{{"rule", KindDatetime, "1979-05-27 07:32:00+00:00"}}},
		{"s7_accept_args_float.toml", "build.args", []field{{"key", KindString, "A"}, {"value", KindFloat, "1.5"}}},
		{"s7_accept_args_bool.toml", "build.args", []field{{"key", KindString, "A"}, {"value", KindBool, "true"}}},
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
			fam, _ := arrayAt(cfg, c.family)
			if fam.State != Set || len(fam.Entries) != 1 {
				t.Fatalf("Arrays[%s] = %+v, want a Set family of one entry", c.family, fam)
			}
			var got []field
			for _, f := range fam.Entries[0].Fields {
				if f.Value.Kind != VScalar {
					t.Fatalf("field %s = %+v, want a scalar", f.Key, f.Value)
				}
				got = append(got, field{f.Key, f.Value.Scalar.Kind, f.Value.Scalar.Text})
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("fields = %+v, want %+v", got, c.want)
			}
		})
	}
}
