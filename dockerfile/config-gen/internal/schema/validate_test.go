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

// Validate is _schema_validate on the bridge's text: for every
// class=value row of the shared table it gives schema.sh's verdict, exactly
// and with no exception (base#1442 AC "Validation matches schema.sh",
// review round 3 finding 2). The row's literal is decoded into a Scalar by
// the library, exactly as a layer's value is, and Validate judges its
// Text, the bridge's rendering of it; a refused text is conf_value_invalid.
// The bats half (config_gen_schema_values_spec.bats) runs the real
// _schema_validate on the bridge's --kv text of the same literal and holds
// every verdict to it, so the table is the shell's word. The type of a
// value is not Validate's to judge: a value outside its field's type
// (ADR-00000039) is refused by Decode before Validate is asked, and is
// tested through config-gen check on s6_kinds.tsv. So `privileged =
// "true"` is a row the shell accepts, and Validate accepts its text too.
// Rows cover every scalar key of SCHEMA_VALIDATOR, the three free-form
// build keys, both empty policies (`""` at gpu_count and
// gpu_capabilities is validated and refused, at any other key accepted),
// and the 12 numbered families at keys other than _1. What else the rows
// cover is checked, not claimed: TestEveryAlternativeHasAnAcceptedWitness
// requires an accepted row through every alternative s6_alternatives.tsv
// lists, and the bats half an accepted and a refused row at every key of
// schema.sh's SCHEMA_VALIDATOR.
func TestValidateMatchesSchemaSh(t *testing.T) {
	for _, row := range readValueRows(t) {
		name := row.section + "." + row.key + "=" + row.literal
		t.Run(name, func(t *testing.T) {
			text := rowText(t, row)

			err := Validate(row.section, row.key, text)

			switch row.verdict {
			case "accept":
				if err != nil {
					t.Errorf("tsv line %d (%s): Validate(%q) = %v, want accept", row.line, row.branch, text, err)
				}
			case "refuse":
				var ve *ValueError
				if !errors.As(err, &ve) {
					t.Fatalf("tsv line %d (%s): Validate(%q) = %v, want a *ValueError", row.line, row.branch, text, err)
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

// rowText writes a row's literal under a header naming its section, each
// dot-separated part of the section as a quoted key, so a section text
// such as `stage:dev.logging` (the bridge's dotted name for the table
// `["stage:dev".logging]`) is written as `["stage:dev"."logging"]`. It
// decodes that with the library, exactly as a layer's value is decoded,
// and returns its Text: the bridge's rendering Validate judges. The bats
// half writes the same header and holds the bridge's section text equal
// to the row's.
func rowText(t *testing.T, row valueRow) string {
	t.Helper()
	parts := strings.Split(row.section, ".")
	src := "[\"" + strings.Join(parts, "\".\"") + "\"]\n" + row.key + " = " + row.literal + "\n"
	var doc map[string]any
	if _, err := toml.Decode(src, &doc); err != nil {
		t.Fatalf("tsv line %d: decode %q: %v", row.line, src, err)
	}
	table := doc
	for _, p := range parts {
		next, ok := table[p].(map[string]any)
		if !ok {
			t.Fatalf("tsv line %d: decode %q gave no table %q", row.line, src, row.section)
		}
		table = next
	}
	v, ok := table[row.key]
	if !ok {
		t.Fatalf("tsv line %d: decode %q gave no %s.%s", row.line, src, row.section, row.key)
	}
	var s Scalar
	if err := s.UnmarshalTOML(v); err != nil {
		t.Fatalf("tsv line %d: %s.%s = %#v: %v", row.line, row.section, row.key, v, err)
	}
	return s.Text
}

// Every alternative of every list validator (a case word, an image rule
// prefix, a mount mode word, a size unit, container:, or a <placeholder>
// for a numeric or GID branch) is a row of corpus/s6/s6_alternatives.tsv,
// written from the validators in dist/script/docker/lib/_tui_conf.sh and
// not from this package, naming the s6_scalar_values.tsv row that goes
// through it (base#1442 review round 1: no row went through `string:`,
// so dropping it from the image rule left every test green; review round
// 2: the obligation is the table's, not the validator representation's).
// The witness row must be one the table accepts and Validate must accept
// its text, judged only through Validate (review round 2 of the
// implementation: no private validator detail). That the witness's key
// resolves to the alternative's validator key and that its text carries a
// word alternative are the shell contract's, so the bats half
// (config_gen_schema_values_spec.bats) holds them to _schema_canonical_key
// and _schema_validate.
func TestEveryAlternativeHasAnAcceptedWitness(t *testing.T) {
	paths := testcorpus.Glob(t, "corpus/s6/s6_alternatives.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	rows := map[[3]string]valueRow{}
	for _, row := range readValueRows(t) {
		rows[[3]string{row.section, row.key, row.literal}] = row
	}
	seen := map[[2]string]bool{}
	n := 0
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 5 {
			t.Fatalf("%s:%d: %d fields, want 5: %q", paths[0], i+1, len(f), line)
		}
		n++
		canon, alt := f[0], f[1]
		if seen[[2]string{canon, alt}] {
			t.Errorf("alternatives line %d: %s %q listed twice", i+1, canon, alt)
		}
		seen[[2]string{canon, alt}] = true
		row, ok := rows[[3]string{f[2], f[3], f[4]}]
		if !ok {
			t.Errorf("alternatives line %d: %s %q: no s6_scalar_values.tsv row %s.%s = %s", i+1, canon, alt, f[2], f[3], f[4])
			continue
		}
		if row.verdict != "accept" {
			t.Errorf("alternatives line %d: %s %q: witness tsv line %d is %s, want accept", i+1, canon, alt, row.line, row.verdict)
		}
		text := rowText(t, row)
		if err := Validate(row.section, row.key, text); err != nil {
			t.Errorf("alternatives line %d: %s %q: Validate(%q) = %v, want accept", i+1, canon, alt, text, err)
		}
	}
	if n == 0 {
		t.Fatalf("%s: no rows", paths[0])
	}
}

// Scalar's text for every TOML scalar kind is the bridge's --kv text for
// the same literal (base#1442): each row of corpus/s6/s6_scalar_texts.tsv
// names a literal, its toml-test kind and the text the bridge prints; the
// bats half (config_gen_schema_values_spec.bats) checks that text against
// the bridge itself. A local time, a local datetime and a fractional
// datetime are decoded like any other scalar, never left out.
func TestScalarTextMatchesBridge(t *testing.T) {
	paths := testcorpus.Glob(t, "corpus/s6/s6_scalar_texts.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	rows := 0
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 5 {
			t.Fatalf("%s:%d: %d fields, want 5: %q", paths[0], i+1, len(f), line)
		}
		rows++
		src := "[" + f[0] + "]\n" + f[1] + " = " + f[2] + "\n"
		var doc map[string]map[string]Scalar
		if _, err := toml.Decode(src, &doc); err != nil {
			t.Errorf("tsv line %d: decode %q: %v", i+1, src, err)
			continue
		}
		if got, want := doc[f[0]][f[1]], (Scalar{Kind: Kind(f[3]), Text: f[4]}); got != want {
			t.Errorf("tsv line %d: %s = %+v, want %+v", i+1, f[2], got, want)
		}
	}
	if rows == 0 {
		t.Fatalf("%s: no rows", paths[0])
	}
}
