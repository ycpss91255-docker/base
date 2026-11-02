package schema

import (
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// layerRow is one row of corpus/s6/s6_layers.tsv: a whole layer and the
// verdict the shell gives it.
type layerRow struct {
	line                   int
	src                    []byte
	verdict, event, branch string
	refusedLine            int
}

// unescapeLayer decodes the layer column as bash's `printf %b` decodes
// it, for the escapes the table uses: `\\`, `\n`, `\t`, `\r` and `\xHH`.
func unescapeLayer(t *testing.T, s string) []byte {
	t.Helper()
	var out []byte
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 == len(s) {
			out = append(out, s[i])
			continue
		}
		i++
		switch s[i] {
		case '\\':
			out = append(out, '\\')
		case 'n':
			out = append(out, '\n')
		case 't':
			out = append(out, '\t')
		case 'r':
			out = append(out, '\r')
		case 'x':
			b, err := strconv.ParseUint(s[i+1:i+3], 16, 8)
			if err != nil {
				t.Fatalf("layer %q: bad \\x escape: %v", s, err)
			}
			out = append(out, byte(b))
			i += 2
		default:
			t.Fatalf("layer %q: escape \\%c is not one the table uses", s, s[i])
		}
	}
	return out
}

// readLayerRows reads the shared layer table. The bats half
// (test/bats/unit/config_gen_schema_values_spec.bats) feeds each layer to
// the bridge and to apply's checks (_setup_known_section, _setup_known_key,
// _schema_validate on every --kv row, a [stage:*] table skipped as
// _setup_conf_check_known skips it) and asserts the verdict column, so the
// column is the shell's word.
func readLayerRows(t *testing.T) []layerRow {
	t.Helper()
	paths := testcorpus.Glob(t, "corpus/s6/s6_layers.tsv")
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	var rows []layerRow
	for i, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 6 || f[0] != "layer" {
			t.Fatalf("%s:%d: want 6 fields of class layer: %q", paths[0], i+1, line)
		}
		n, err := strconv.Atoi(f[4])
		if err != nil {
			t.Fatalf("%s:%d: line column %q: %v", paths[0], i+1, f[4], err)
		}
		rows = append(rows, layerRow{line: i + 1, src: unescapeLayer(t, f[1]), verdict: f[2], event: f[3], refusedLine: n, branch: f[5]})
	}
	if len(rows) == 0 {
		t.Fatalf("%s: no rows", paths[0])
	}
	return rows
}

// Decode gives the shell's verdict on every whole layer of the shared
// table (base#1442 review round 2, findings 3, 6 and 8). An accept row
// decodes with no refusal; a refuse row, or a differs:<exception> row the
// shell accepts and ADR-00000039 refuses on purpose (wrong type, U+0000),
// gives the row's event as its first refusal, at the row's line.
//
// The rows cover every SCHEMA_SECTIONS section, written bare and with a
// key ([project] name = "demo" is a layer apply accepts); the free-form
// [build] keys; a [stage:<name>] table; the bridge's transport refusals of
// a tab, CR or LF in a table or key name and of a CR or LF in a value, an
// array entry's value included (toml_bridge.py _check_transportable);
// invalid UTF-8 in a value and in a key, refused by the parser at its
// line; a unicode value, a unicode env name and a unicode key.
func TestDecodeMatchesShellOnLayers(t *testing.T) {
	for _, row := range readLayerRows(t) {
		t.Run(row.branch, func(t *testing.T) {
			_, refusals := decodeNoPanic(t, row.src)

			switch {
			case row.verdict == "accept":
				if len(refusals) != 0 {
					t.Errorf("tsv line %d: Decode(%q) refusals = %+v, want none", row.line, row.src, refusals)
				}
			case row.verdict == "refuse" || strings.HasPrefix(row.verdict, "differs:"):
				if len(refusals) == 0 {
					t.Fatalf("tsv line %d: Decode(%q) accepted, want %s at line %d", row.line, row.src, row.event, row.refusedLine)
				}
				if got := refusals[0]; got.Event != row.event || got.Line != row.refusedLine {
					t.Errorf("tsv line %d: Decode(%q) first refusal = %+v, want %s at line %d", row.line, row.src, got, row.event, row.refusedLine)
				}
			default:
				t.Fatalf("tsv line %d: verdict %q", row.line, row.verdict)
			}
		})
	}
}

// The sections Decode knows are exactly the table's section:<name> rows,
// and the bats half holds those rows equal to schema.sh's SCHEMA_SECTIONS,
// so a section added to the shell and not to Go fails here (base#1442
// review round 2, finding 6).
func TestKnownSectionsAreSchemaSections(t *testing.T) {
	var want []string
	for _, row := range readLayerRows(t) {
		if name, ok := strings.CutPrefix(row.branch, "section:"); ok && name != "stage" {
			want = append(want, name)
		}
	}
	slices.Sort(want)
	got := slices.Clone(KnownSections())
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Errorf("KnownSections() = %q, want the table's section rows %q", got, want)
	}
}
