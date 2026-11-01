package schema

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// valueRow is one class=value row of corpus/s6/s6_scalar_values.tsv:
// a TOML literal at section.key and the verdict schema.sh gives it.
type valueRow struct {
	line                   int
	section, key, literal  string
	verdict, event, branch string
}

// readValueRows reads the class=value rows of the shared table. The bats
// half (test/bats/unit/config_gen_schema_values_spec.bats) reads the same
// file and checks every verdict against _schema_validate on the bridge's
// text, so the verdict column is schema.sh's answer, not this package's.
func readValueRows(t *testing.T) []valueRow {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s6/s6_scalar_values.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	var rows []valueRow
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 7 {
			t.Fatalf("%s:%d: %d fields, want 7: %q", paths[0], i+1, len(f), line)
		}
		if f[0] != "value" {
			t.Fatalf("%s:%d: class %q, want value", paths[0], i+1, f[0])
		}
		rows = append(rows, valueRow{i + 1, f[1], f[2], f[3], f[4], f[5], f[6]})
	}
	if len(rows) == 0 {
		t.Fatalf("%s: no class=value rows", paths[0])
	}
	return rows
}

// Validate gives schema.sh's verdict for every class=value row of the
// shared table (base#1442, AC "Validation matches schema.sh"). The literal
// is decoded into a Scalar by the library, exactly as a layer's value is,
// and Validate judges it. A refused row names its event: a string at a
// bool key whose text fails (`privileged = "yes"`, `"TRUE"`) is
// conf_value_type_refused. An empty string is accepted by schema.sh's
// default empty policy, and `true` / `"true"` pass _validate_privileged.
func TestValidateMatchesSchemaSh(t *testing.T) {
	for _, row := range readValueRows(t) {
		name := row.section + "." + row.key + "=" + row.literal
		t.Run(name, func(t *testing.T) {
			src := "[" + row.section + "]\n" + row.key + " = " + row.literal + "\n"
			var doc map[string]map[string]Scalar
			if _, err := toml.Decode(src, &doc); err != nil {
				t.Fatalf("tsv line %d: decode %q: %v", row.line, src, err)
			}
			s, ok := doc[row.section][row.key]
			if !ok {
				t.Fatalf("tsv line %d: decode %q gave no %s.%s", row.line, src, row.section, row.key)
			}

			err := Validate(row.section, row.key, s)

			switch row.verdict {
			case "accept":
				if err != nil {
					t.Errorf("tsv line %d (%s): Validate = %v, want accept", row.line, row.branch, err)
				}
			case "refuse":
				var ve *ValueError
				if !errors.As(err, &ve) {
					t.Fatalf("tsv line %d (%s): Validate = %v, want a *ValueError", row.line, row.branch, err)
				}
				if ve.Event != row.event {
					t.Errorf("tsv line %d (%s): Event = %q, want %q", row.line, row.branch, ve.Event, row.event)
				}
			default:
				t.Fatalf("tsv line %d: verdict %q, want accept or refuse", row.line, row.verdict)
			}
		})
	}
}
