package schema

import (
	"errors"
	"maps"
	"os"
	"slices"
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
// cover is checked, not claimed: TestEveryChoiceAlternativeHasAnAcceptedRow
// requires an accepted row through every alternative of every list
// validator, and TestEveryValidatorKeyAcceptsAndRefuses an accepted and a
// refused row at every validator key.
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

// rowText decodes a row's literal with the library, exactly as a layer's
// value is decoded, and returns its Text: the bridge's rendering Validate
// judges.
func rowText(t *testing.T, row valueRow) string {
	t.Helper()
	src := "[" + row.section + "]\n" + row.key + " = " + row.literal + "\n"
	var doc map[string]map[string]Scalar
	if _, err := toml.Decode(src, &doc); err != nil {
		t.Fatalf("tsv line %d: decode %q: %v", row.line, src, err)
	}
	s, ok := doc[row.section][row.key]
	if !ok {
		t.Fatalf("tsv line %d: decode %q gave no %s.%s", row.line, src, row.section, row.key)
	}
	return s.Text
}

// Every alternative of every list validator (a choice: a case word, an
// image rule prefix, a mount mode, a size unit, container:) has a row of
// the shared table that the shell accepts through it, at that validators
// key (base#1442 review round 1: no row went through `string:`, so
// dropping it from the image rule left every test green). The
// alternatives a row went through are the choice's own report, so a new
// alternative needs a new row, and an alternative dropped from the code
// fails the row that went through it in TestValidateMatchesSchemaSh.
func TestEveryChoiceAlternativeHasAnAcceptedRow(t *testing.T) {
	took := map[string]map[string]bool{}
	for _, row := range readValueRows(t) {
		k, ok := canonicalKey(row.section, row.key)
		if !ok || row.verdict != "accept" || validators[k].choice == nil {
			continue
		}
		text := rowText(t, row)
		if text == "" && !validators[k].validateEmpty {
			continue
		}
		alts, ok := validators[k].choice.took(text)
		if !ok {
			t.Errorf("tsv line %d: %s refuses accepted %q", row.line, k, text)
			continue
		}
		if took[k] == nil {
			took[k] = map[string]bool{}
		}
		for _, a := range alts {
			took[k][a] = true
		}
	}
	for _, k := range slices.Sorted(maps.Keys(validators)) {
		c := validators[k].choice
		if c == nil {
			continue
		}
		for _, a := range c.alts {
			if !took[k][a] {
				t.Errorf("%s: no accepted row goes through alternative %q", k, a)
			}
		}
	}
}

// Every validator key has a row the shell accepts with a non-empty text
// and a row it refuses, so no validator is judged on the empty policy
// alone or only ever accepts (base#1442 review round 1). The watchdog
// commands are the exception: _validate_watchdog_cmd refuses only an
// empty or a multi-line text, the empty one never reaches it, and the
// bridge's --kv refuses a value holding a newline ("the tab-separated
// shell view cannot carry" it), so no table row can be refused there. An
// exception with a refused row fails, so the list cannot go stale.
func TestEveryValidatorKeyAcceptsAndRefuses(t *testing.T) {
	neverRefused := map[string]bool{"lifecycle.watchdog_check": true, "lifecycle.watchdog_notify": true}
	accepted, refused := map[string]bool{}, map[string]bool{}
	for _, row := range readValueRows(t) {
		k, ok := canonicalKey(row.section, row.key)
		if !ok {
			continue
		}
		switch {
		case row.verdict == "refuse":
			refused[k] = true
		case rowText(t, row) != "":
			accepted[k] = true
		}
	}
	for _, k := range slices.Sorted(maps.Keys(validators)) {
		if !accepted[k] {
			t.Errorf("%s: no accepted row with a non-empty text", k)
		}
		if !refused[k] && !neverRefused[k] {
			t.Errorf("%s: no refused row", k)
		}
		if refused[k] && neverRefused[k] {
			t.Errorf("%s: a refused row, but listed as never refused", k)
		}
	}
}

// Every rule has exactly one validator: a list (choice) or a predicate
// (valid). accepts reads choice first, so a rule with both would have
// its valid ignored, and a rule with neither would panic.
func TestEveryRuleHasOneValidator(t *testing.T) {
	for _, k := range slices.Sorted(maps.Keys(validators)) {
		r := validators[k]
		if (r.valid == nil) == (r.choice == nil) {
			t.Errorf("%s: valid set %v, choice set %v; want exactly one", k, r.valid != nil, r.choice != nil)
		}
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
