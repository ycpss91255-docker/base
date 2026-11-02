package schema

import (
	"fmt"
	"reflect"
	"testing"
)

// decodeNoPanic runs Decode and turns a panic into a test failure, so one
// input that crashes the decoder does not hide the verdicts of the others.
func decodeNoPanic(t *testing.T, src []byte) (cfg *Config, refusals []Refusal) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Decode(%q) panicked: %v", src, r)
		}
	}()
	return Decode(src)
}

// TestDecodeRefusalClasses checks Decode's refusals over the classes
// review round 1 of base#1442 found unhandled. Each want row is the
// event, path and line; every line is counted from the input bytes.
//
//   - A root scalar is refused whatever its name, a known section name
//     included: `deploy = true` is no table (conf_top_level_key).
//   - A key under a `[logging.<service>]` section text is judged as a
//     [logging] key, as _schema_canonical_key normalises `logging.*`:
//     `typo` is unknown, `max_file = 0` fails _validate_log_max_file (an
//     int at an int key, conf_value_invalid), whether the section is
//     written `[logging.web]`, `["logging.web"]`, a dotted key or a
//     deeper `[logging.web.x]`.
//   - The line of a refused key is the locator's, so a comment after the
//     header, a quoted key, an indented header, an escaped quote, an
//     inline table and a header-like line inside a multi-line string all
//     leave the key at its own line.
//   - A value of any TOML scalar kind is judged, never dropped: a local
//     time, a local datetime and a fractional offset datetime at a known
//     key are refused (their text fails the key's validator, and their
//     kind is not the key's).
//   - A table under an unknown table is not refused again: the outermost
//     unknown table, implicit or not, is the one refusal.
func TestDecodeRefusalClasses(t *testing.T) {
	type want struct {
		event string
		path  []string
		line  int
	}
	cases := []struct {
		name string
		src  string
		want []want
	}{
		{"root scalar at a known section name", "deploy = true\n[security]\nprivileged = true\n",
			[]want{{"conf_top_level_key", []string{"deploy"}, 1}}},
		{"root string at [logging]", "logging = \"x\"\n",
			[]want{{"conf_top_level_key", []string{"logging"}, 1}}},
		{"unknown key in [logging.web]", "[logging.web]\ntypo = 1\n",
			[]want{{"conf_unknown_key", []string{"logging", "web", "typo"}, 2}}},
		{"invalid max_file in [logging.web]", "[logging.web]\nmax_file = 0\n",
			[]want{{"conf_value_invalid", []string{"logging", "web", "max_file"}, 2}}},
		{"unknown key in [\"logging.web\"]", "[\"logging.web\"]\ntypo = 1\n",
			[]want{{"conf_unknown_key", []string{"logging.web", "typo"}, 2}}},
		{"dotted service key under [logging]", "[logging]\ndriver = \"local\"\nweb.max_file = 0\n",
			[]want{{"conf_value_invalid", []string{"logging", "web", "max_file"}, 3}}},
		{"unknown key in [logging.web.x]", "[logging.web.x]\ntypo = 1\n",
			[]want{{"conf_unknown_key", []string{"logging", "web", "x", "typo"}, 2}}},
		{"valid service keys", "[logging.web]\ndriver = \"json-file\"\nmax_file = 3\n", nil},
		{"comment after the header", "[deploy] # a comment\ngpu_cuont = 1\n",
			[]want{{"conf_unknown_key", []string{"deploy", "gpu_cuont"}, 2}}},
		{"quoted key", "[deploy]\n\"gpu_cuont\" = 1\n",
			[]want{{"conf_unknown_key", []string{"deploy", "gpu_cuont"}, 2}}},
		{"indented header", "[security]\nprivileged = true\n  [deploy]\ngpu_cuont = 1\n",
			[]want{{"conf_unknown_key", []string{"deploy", "gpu_cuont"}, 4}}},
		{"header-like line in a multi-line string", "[deploy]\ngpu_capabilities = \"\"\"\n[security]\n\"\"\"\nprivileged = true\n",
			[]want{
				// The value holds an LF, which the bridge refuses
				// (_check_transportable).
				{"conf_value_newline_refused", []string{"deploy", "gpu_capabilities"}, 2},
				{"conf_unknown_key", []string{"deploy", "privileged"}, 5},
			}},
		{"escaped quote in a value", "[deploy]\ngpu_mode = \"a\\\"b\"\ngpu_cuont = 1\n",
			[]want{
				{"conf_value_invalid", []string{"deploy", "gpu_mode"}, 2},
				{"conf_unknown_key", []string{"deploy", "gpu_cuont"}, 3},
			}},
		{"escaped quote in a valid value", "[environment]\nenv_1 = \"A=a\\\"b\"\n", nil},
		{"inline table nested under a known section", "[security]\nprivileged = true\ndeploy = { gpu_cuont = 1 }\n",
			[]want{{"conf_unknown_table", []string{"security", "deploy"}, 3}}},
		{"key in an inline table at a known section", "deploy = { gpu_cuont = 1 }\n",
			[]want{{"conf_unknown_key", []string{"deploy", "gpu_cuont"}, 1}}},
		{"local time at gpu_count", "[deploy]\ngpu_count = 07:32:00\n",
			[]want{{"conf_value_type_refused", []string{"deploy", "gpu_count"}, 2}}},
		{"local datetime at env_1", "[environment]\nenv_1 = 1979-05-27T07:32:00\n",
			[]want{{"conf_value_type_refused", []string{"environment", "env_1"}, 2}}},
		{"fractional datetime at gpu_mode", "[deploy]\ngpu_mode = 1979-05-27T07:32:00.5Z\n",
			[]want{{"conf_value_type_refused", []string{"deploy", "gpu_mode"}, 2}}},
		// Every unknown table text is reported once, as the shell's
		// --tables walk reports it: `[foo.bar]` is foo and foo.bar
		// (s6_sec_unknown_nested.toml, held to _setup_conf_check_known by
		// config_gen_schema_values_spec.bats).
		{"table under an implicit unknown table", "[foo.bar]\nx = 1\n[foo.baz]\ny = 1\n",
			[]want{{"conf_unknown_table", []string{"foo"}, 1}, {"conf_unknown_table", []string{"foo", "bar"}, 1}, {"conf_unknown_table", []string{"foo", "baz"}, 3}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, refusals := decodeNoPanic(t, []byte(tc.src))

			var got []want
			for _, r := range refusals {
				got = append(got, want{r.Event, r.Path, r.Line})
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("Decode(%q) refusals =\n  %s\nwant\n  %s", tc.src, fmt.Sprint(got), fmt.Sprint(tc.want))
			}
		})
	}
}

// A value whose kind Decode refuses stays in the model: the refusal is
// returned and the row keeps its kind and the bridge's text, so nothing is
// dropped silently (base#1442). `07:32:00` is a TOML local time; the
// bridge's --kv text for it is `07:32:00` (corpus/s6/s6_scalar_texts.tsv).
func TestDecodeKeepsEveryScalarKindInTheTree(t *testing.T) {
	cfg, _ := decodeNoPanic(t, []byte("[deploy]\ngpu_count = 07:32:00\n"))

	var rows []Child
	for _, c := range cfg.Tree.Nodes {
		for _, ch := range c.Children {
			if ch.Kind == ChildRow {
				rows = append(rows, ch)
			}
		}
	}
	want := []Child{{Kind: ChildRow, Key: "gpu_count", Row: Field{State: Set, Value: Scalar{Kind: Kind("time-local"), Text: "07:32:00"}, Line: 2}}}
	if !reflect.DeepEqual(rows, want) {
		t.Errorf("tree rows = %+v, want %+v", rows, want)
	}
}
