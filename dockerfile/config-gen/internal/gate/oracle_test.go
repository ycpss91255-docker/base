package gate

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
)

// loadOracleVerdicts reads the live tomllib verdicts file that
// CONFIG_GEN_TOML_ORACLE names (base#1441). An empty path or a file it
// cannot read fails closed with noOracleMsg.
func loadOracleVerdicts(path string) ([]string, error) {
	if path == "" {
		return nil, errors.New(noOracleMsg)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New(noOracleMsg + ": " + err.Error())
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n"), nil
}

// checkOracleRows holds the verdict rows (`<rel>\t<verdict>`) to the set
// of TOML files the differential reads (base#1441): every file needs a
// row and every row a file. Order does not matter; the error names each
// path on either side, sorted.
func checkOracleRows(rows, files []string) error {
	have := make(map[string]bool, len(rows))
	for _, r := range rows {
		rel, _, _ := strings.Cut(r, "\t")
		have[rel] = true
	}
	want := make(map[string]bool, len(files))
	var missing, extra []string
	for _, f := range files {
		want[f] = true
		if !have[f] {
			missing = append(missing, f)
		}
	}
	for rel := range have {
		if !want[rel] {
			extra = append(extra, rel)
		}
	}
	if len(missing) == 0 && len(extra) == 0 {
		return nil
	}
	sort.Strings(missing)
	sort.Strings(extra)
	var b strings.Builder
	for _, f := range missing {
		fmt.Fprintf(&b, "\n  no oracle verdict row for %s", f)
	}
	for _, rel := range extra {
		fmt.Fprintf(&b, "\n  oracle verdict row for %s names no testdata file", rel)
	}
	return errors.New("oracle verdict rows differ from the testdata TOML files:" + b.String())
}
