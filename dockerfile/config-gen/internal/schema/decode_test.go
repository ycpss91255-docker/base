package schema

import (
	"reflect"
	"testing"
)

// An unregistered scalar name beside a known one in a known table is one
// conf_unknown_key refusal at the line the key is written on (base#1442).
// The verdicts are schema.sh's: `deploy gpu_count` is a known key and
// `deploy gpu_cuont` is not. Line 3 is counted from the input bytes.
// BurntSushi's Undecoded() carries no position, so the line rules it out
// as the source of the refusal.
func TestDecodeUnknownKeyInKnownTable(t *testing.T) {
	src := []byte("[deploy]\ngpu_count = \"all\"\ngpu_cuont = \"1\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_key" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_key")
	}
	if want := []string{"deploy", "gpu_cuont"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 3 {
		t.Errorf("Line = %d, want 3", got.Line)
	}
}

// A table schema.sh does not know is one conf_unknown_table refusal at its
// header line, and the keys under it get no refusal of their own
// (base#1442). The verdict is the shell's: `_setup_known_section deploy2`
// fails and setup_cmd.sh reports apply_unknown_table once for the table,
// with no apply_unknown_key for `deploy2.x`. Line 3 is counted from the
// input bytes.
func TestDecodeUnknownTable(t *testing.T) {
	src := []byte("[deploy]\ngpu_count = \"all\"\n[deploy2]\nx = 1\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_table" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_table")
	}
	if want := []string{"deploy2"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 3 {
		t.Errorf("Line = %d, want 3", got.Line)
	}
}

// A scalar written at the root, above any table header, is one
// conf_top_level_key refusal naming that key at its line (base#1308,
// base#1442). schema.sh has no root section, so no root scalar is a
// known key; the event id is the base#1442 design's. Line 1 is counted from the
// input bytes. The table that follows it gets no refusal of its own.
func TestDecodeTopLevelScalar(t *testing.T) {
	src := []byte("top = \"v\"\n[deploy]\ngpu_count = \"all\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_top_level_key" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_top_level_key")
	}
	if want := []string{"top"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 1 {
		t.Errorf("Line = %d, want 1", got.Line)
	}
}

// A wrong-typed value at a known key is refused by Decode, not only by
// Validate (base#1314, base#1442). `privileged = "yes"` is a string at the
// bool key security.privileged whose text fails: schema.sh's verdict is
// refuse (`_schema_validate security privileged yes` returns 1 under
// LC_ALL=C), and the design's event for a value of another kind whose
// text fails is conf_value_type_refused. Line 2 is counted from the input
// bytes. The table [security] is known, so it gets no refusal of its own.
func TestDecodeWrongTypedScalar(t *testing.T) {
	src := []byte("[security]\nprivileged = \"yes\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_value_type_refused" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_value_type_refused")
	}
	if want := []string{"security", "privileged"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 2 {
		t.Errorf("Line = %d, want 2", got.Line)
	}
}

// A scalar in a table whose name also holds deferred arrays is the
// schema's, not deferred: deferral goes by TOML type, not by path
// (base#1442). `[volumes]\nmount_1 = "/a"` is a string in a scalar table,
// so it is validated like any other known key. The verdicts are the
// shell's under LC_ALL=C: `_setup_known_section volumes` and
// `_setup_known_key volumes mount_1` return 0, and `_schema_validate
// volumes mount_1 /a` returns 1. A string at a string key whose text
// fails is conf_value_invalid (the shared value table's volumes.mount_5
// row). Line 2 is counted from the input bytes. The table [volumes] is
// known, so it gets no refusal of its own.
func TestDecodeScalarInDeferrableTableIsValidated(t *testing.T) {
	src := []byte("[volumes]\nmount_1 = \"/a\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_value_invalid" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_value_invalid")
	}
	if want := []string{"volumes", "mount_1"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 2 {
		t.Errorf("Line = %d, want 2", got.Line)
	}
}

// A table whose name also holds deferred arrays of tables is still a
// scalar table when written as `[devices]`, so an unregistered key in it
// is refused, not deferred (base#1442). The verdicts are the shell's
// under LC_ALL=C: `_setup_known_section devices` returns 0 and
// `_setup_known_key devices typo` returns 1. Line 2 is counted from the
// input bytes. The table [devices] is known, so it gets no refusal of its
// own.
func TestDecodeUnknownKeyInDeferrableTable(t *testing.T) {
	src := []byte("[devices]\ntypo = \"x\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_key" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_key")
	}
	if want := []string{"devices", "typo"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 2 {
		t.Errorf("Line = %d, want 2", got.Line)
	}
}

// An array of tables at a known section name is the deferred legacy
// spelling, not a scalar table, so its keys are not looked up in the
// schema and get no refusal: deferral goes by TOML type (base#1442).
// The bridge accepts `[[volumes]]\nsource = "/a"` with rc 0 and turns it
// into the row `volumes\tmount_1\t/a` (`_ARRAY_SPEC["volumes"]`,
// dockerfile/toml_bridge.py line 53),
// so the element's `source` never reaches _setup_known_key; checking it
// is left to the array stage. The library types the path as ArrayHash,
// unlike `[volumes]`, which is Hash.
func TestDecodeArrayOfTablesIsDeferred(t *testing.T) {
	src := []byte("[[volumes]]\nsource = \"/a\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 0 {
		t.Fatalf("Decode refusals = %d (%+v), want none", len(refusals), refusals)
	}
}

// An array of tables nested under a known scalar table is deferred by
// its TOML type, while the scalar table's own keys are still checked
// (base#1442). In `[devices]` beside `[[devices.bindings]]` the library
// types devices as Hash and devices.bindings as ArrayHash. The verdicts
// are the shell's under LC_ALL=C: `_setup_known_key devices bogus` and
// `_setup_known_key devices bindings` both return 1, so a lookup by name
// would refuse bindings too; the array stage owns it instead. device_1
// holds a value the shared value table accepts (`/dev/x:/dev/x`,
// mount:pair), but it is also block 1 of the bindings family spelled as
// a table scalar: main's dockerfile/toml_bridge.py `--kv` on this input
// gives rc 1, "devices.device_1 is carried two ways in one
// configuration" (base#1443). The refusals are conf_family_two_spellings
// at devices.device_1, line 2, and conf_unknown_key at devices.bogus,
// line 3, counted from the input bytes.
func TestDecodeNestedArrayOfTablesIsDeferred(t *testing.T) {
	src := []byte("[devices]\ndevice_1 = \"/dev/x:/dev/x\"\nbogus = 1\n\n[[devices.bindings]]\npath = \"/dev/y\"\n")

	_, refusals := Decode(src)

	want := []Refusal{
		{Event: "conf_family_two_spellings", Path: []string{"devices", "device_1"}, Line: 2, Col: 1},
		{Event: "conf_unknown_key", Path: []string{"devices", "bogus"}, Line: 3, Col: 1},
	}
	if !reflect.DeepEqual(refusals, want) {
		t.Errorf("Decode refusals =\n  %+v\nwant\n  %+v", refusals, want)
	}
}

// A plain table nested under a known section is a section of its own,
// and schema.sh does not know it, so it is one conf_unknown_table refusal
// at its header line, with no refusal for the key under it (base#1442).
// The verdicts are the shell's under LC_ALL=C: `_setup_known_section
// devices.bindings` returns 1 (apply_unknown_table), while
// `_setup_known_section devices` returns 0. Line 1 is counted from the
// input bytes.
func TestDecodeNestedTableUnderKnownSectionIsUnknownTable(t *testing.T) {
	src := []byte("[devices.bindings]\npath = \"/dev/y\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_unknown_table" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_unknown_table")
	}
	if want := []string{"devices", "bindings"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 1 {
		t.Errorf("Line = %d, want 1", got.Line)
	}
}

// An array written at a registered scalar key is a value of the wrong
// type for that key, so it is one conf_value_type_refused refusal at the
// key's line: it is neither deferred as an array nor a parse failure
// (base#1442). The verdicts are the shell's under LC_ALL=C:
// `_setup_known_section environment` and `_setup_known_key environment
// env_1` both return 0, so the key is known, and `_schema_validate
// environment env_1 '["x"]'` returns 1. The input is valid TOML, so the
// refusal is the value's type, not conf_toml_parse_failed. Line 2 is
// counted from the input bytes.
func TestDecodeArrayAtScalarKeyIsTypeRefused(t *testing.T) {
	src := []byte("[environment]\nenv_1 = [\"x\"]\n")

	_, refusals := Decode(src)

	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %d (%+v), want exactly 1", len(refusals), refusals)
	}
	got := refusals[0]
	if got.Event != "conf_value_type_refused" {
		t.Errorf("Event = %q, want %q", got.Event, "conf_value_type_refused")
	}
	if want := []string{"environment", "env_1"}; !reflect.DeepEqual(got.Path, want) {
		t.Errorf("Path = %q, want %q", got.Path, want)
	}
	if got.Line != 2 {
		t.Errorf("Line = %d, want 2", got.Line)
	}
}

// [logging] is a known section, and a table under it is a per-service
// section, classified by its TOML type before any key name is matched,
// so `[logging]` with `driver = "local"` beside `[logging.web]` with
// `driver = "json-file"` gets no refusal (base#1442). The verdicts are
// the shell's under LC_ALL=C: `_setup_known_section logging` and
// `_setup_known_section logging.web` return 0, `_setup_known_key logging
// driver` and `_setup_known_key logging.web driver` return 0, and
// `_schema_validate logging driver local` and `_schema_validate
// logging.web driver json-file` return 0. `_setup_known_key logging web`
// returns 1, so a lookup of `web` as a key name of [logging] would refuse
// the service.
func TestDecodeLoggingSectionWithService(t *testing.T) {
	src := []byte("[logging]\ndriver = \"local\"\n\n[logging.web]\ndriver = \"json-file\"\n")

	_, refusals := Decode(src)

	if len(refusals) != 0 {
		t.Fatalf("Decode refusals = %d (%+v), want none", len(refusals), refusals)
	}
}

// Rows that land on one service's section text from different TOML paths
// under [logging] come out in the bridge's traversal order, not in
// document order, and each typed field is the last row with its key
// (base#1442). The bridge walks the parsed tree depth first in key
// creation order (toml_bridge.py _emit_table, the loop at line 407), so
// in the first case `"a.b".driver` (line 4) comes before `a.b.driver`
// (line 3). Rows and resolved values are the real bridge's `--kv` output
// and the shell's `_conf_get` for the same bytes (base#1442 design r4
// section 1o, bridge_b1.out and resolve_b1.out): codex.toml gives
// `logging.a.b>max_file>1 | logging.a.b>driver>local |
// logging.a.b>driver>json-file` and driver json-file, max_file 1;
// f2_quoted_first gives `local | json-file` and json-file; f3_dotted_first
// gives `json-file | local` and local. Lines are counted from the input
// bytes. `_validate_log_driver` and the max_file rule accept every value,
// so no case has a refusal.
func TestDecodeServiceRowsInBridgeTraversalOrder(t *testing.T) {
	type row struct {
		key, text string
		line      int
	}
	cases := []struct {
		name, src, service string
		rows               []row
		driver, maxFile    *row
	}{
		{
			name:    "codex",
			src:     "[logging]\n\"a.b\".max_file = 1\na.b.driver = \"json-file\"\n\"a.b\".driver = \"local\"\n",
			service: "a.b",
			rows:    []row{{"max_file", "1", 2}, {"driver", "local", 4}, {"driver", "json-file", 3}},
			driver:  &row{"driver", "json-file", 3},
			maxFile: &row{"max_file", "1", 2},
		},
		{
			name:    "f2_quoted_first",
			src:     "[logging.\"a.b\"]\ndriver = \"local\"\n\n[logging.a.b]\ndriver = \"json-file\"\n",
			service: "a.b",
			rows:    []row{{"driver", "local", 2}, {"driver", "json-file", 5}},
			driver:  &row{"driver", "json-file", 5},
		},
		{
			name:    "f3_dotted_first",
			src:     "[logging.a.b]\ndriver = \"json-file\"\n\n[logging.\"a.b\"]\ndriver = \"local\"\n",
			service: "a.b",
			rows:    []row{{"driver", "json-file", 2}, {"driver", "local", 5}},
			driver:  &row{"driver", "local", 5},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %d (%+v), want none", len(refusals), refusals)
			}
			svc := cfg.Logging.Services[tc.service]
			if svc == nil {
				t.Fatalf("Logging.Services[%q] missing", tc.service)
			}
			var got []row
			for _, r := range svc.Rows {
				got = append(got, row{r.Key, r.Field.Value.Text, r.Field.Line})
			}
			if !reflect.DeepEqual(got, tc.rows) {
				t.Errorf("Rows = %+v, want %+v", got, tc.rows)
			}
			for _, f := range []struct {
				name  string
				field Field
				want  *row
			}{{"Driver", svc.Driver, tc.driver}, {"MaxFile", svc.MaxFile, tc.maxFile}} {
				if f.want == nil {
					if f.field.State != Absent {
						t.Errorf("%s.State = %v, want Absent", f.name, f.field.State)
					}
					continue
				}
				if f.field.State != Set || f.field.Value.Text != f.want.text || f.field.Line != f.want.line {
					t.Errorf("%s = {%v %q line %d}, want {Set %q line %d}",
						f.name, f.field.State, f.field.Value.Text, f.field.Line, f.want.text, f.want.line)
				}
			}
		})
	}
}
