package buildgate

import (
	"bytes"
	"encoding/json"
	"errors"
	"path"
	"sort"
	"strconv"
	"strings"
)

// The mutation gate's inputs (base#1467): which packages the change
// manifest makes it test, and how a gremlins report is read.

// modulePrefix starts every manifest path inside the module.
const modulePrefix = "dockerfile/config-gen/"

// MutationFloor is the lowest efficacy a tested package may have, in
// integer tenths of a percent.
const MutationFloor = 900

// Targets returns the module-relative directory (`.` for the root) of
// every Go file the change manifest lists, sorted and once each. The
// manifest's first line is its header; every later line is a status
// followed by one or more tab-separated paths.
func Targets(manifest string) []string {
	seen := map[string]bool{}
	out := []string{}
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		for _, p := range strings.Split(line, "\t")[1:] {
			rel, ok := strings.CutPrefix(p, modulePrefix)
			if !ok || !strings.HasSuffix(rel, ".go") {
				continue
			}
			dir := path.Dir(rel)
			if !seen[dir] {
				seen[dir] = true
				out = append(out, dir)
			}
		}
	}
	sort.Strings(out)
	return out
}

// Package is the part of one `go list -json -test -deps` record the
// mapping reads.
type Package struct {
	ImportPath string
	Deps       []string
}

// DecodeList reads the concatenated JSON records `go list -json` prints.
func DecodeList(body []byte) ([]Package, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	var out []Package
	for dec.More() {
		var p Package
		if err := dec.Decode(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// Mapping is what the change manifest makes the mutation gate test.
type Mapping struct {
	Targets []string
	// Removed are the module-relative directories of deleted Go paths
	// where the head tree holds no package any more.
	Removed []string
}

// testcorpus is the one package that reads the module-root testdata/.
const testcorpus = "internal/testcorpus"

// moduleWide are the module-root files that change every package's
// build or test.
var moduleWide = map[string]bool{"go.mod": true, "go.sum": true, ".golangci.yml": true}

// Map returns the module-relative package directories the manifest
// makes the gate test: the directory of every Go file (as Targets, except
// that a deleted Go path whose directory holds no package in pkgs is
// recorded in Removed instead, and any other Go path whose directory holds
// no package is refused as config_gen_mutation_no_such_package pkg=), the
// package that owns a file under its own testdata/, every package of the
// module for go.mod, go.sum or .golangci.yml, and, when the manifest
// lists a file under the module-root testdata/, every package whose test
// binary depends on internal/testcorpus. A coverage-floors.d fragment maps
// to no package. Any other module file is
// refused as config_gen_mutation_unmapped, and a manifest that holds the
// no-change marker beside any other line as config_gen_mutation_manifest_invalid
// reason=marker_beside_lines, and one with neither a record nor the
// marker after its header as reason=empty_manifest. module is the module
// path; pkgs is `go list -json -test -deps ./...` of the module.
func Map(manifest, module string, pkgs []Package) (Mapping, error) {
	marker, other := scanLines(manifest)
	if marker && other {
		return Mapping{}, errors.New(ev("mutation_manifest_invalid", "reason", "marker_beside_lines").String())
	}
	if !marker && !other {
		return Mapping{}, errors.New(ev("mutation_manifest_invalid", "reason", "empty_manifest").String())
	}
	seen := map[string]bool{}
	out := []string{}
	add := func(dir string) {
		if !seen[dir] {
			seen[dir] = true
			out = append(out, dir)
		}
	}
	removed := map[string]bool{}
	for _, g := range goPaths(manifest) {
		dir := path.Dir(g.rel)
		if !hasPackage(pkgs, module, dir) {
			if !g.deleted {
				return Mapping{}, errors.New(ev("mutation_no_such_package", "pkg", importPath(module, dir)).String())
			}
			removed[dir] = true
			continue
		}
		add(dir)
	}
	every := false
	for _, rel := range modulePaths(manifest) {
		switch dir, _, inPkgTestdata := strings.Cut(rel, "/testdata/"); {
		case moduleWide[rel]:
			every = true
		case inPkgTestdata:
			add(dir)
		case strings.HasSuffix(rel, ".go"), strings.HasPrefix(rel, "testdata/"),
			strings.HasPrefix(rel, "coverage-floors.d/"):
		default:
			return Mapping{}, errors.New(ev("mutation_unmapped", "file", modulePrefix+rel).String())
		}
	}
	if every {
		for _, p := range pkgs {
			if rel, ok := strings.CutPrefix(p.ImportPath, module+"/"); ok &&
				!strings.Contains(rel, " ") && !strings.HasSuffix(rel, ".test") {
				add(rel)
			}
		}
	}
	if listsRootTestdata(manifest) {
		corpus := module + "/" + testcorpus
		for _, p := range pkgs {
			under, ok := strings.CutSuffix(p.ImportPath, ".test")
			if !ok {
				continue
			}
			rel, ok := strings.CutPrefix(under, module+"/")
			if !ok {
				continue
			}
			for _, d := range p.Deps {
				if d == corpus || strings.HasPrefix(d, corpus+" [") {
					add(rel)
					break
				}
			}
		}
	}
	sort.Strings(out)
	gone := []string{}
	for dir := range removed {
		gone = append(gone, dir)
	}
	sort.Strings(gone)
	return Mapping{Targets: out, Removed: gone}, nil
}

// noChange is the producer's no-change marker line
// (config_gen_mutation_targets.sh _CGM_NONE), which stands alone after the
// header.
const noChange = "none: no-go-change"

// scanLines reports whether a manifest holds the no-change marker after
// the header, and whether it holds any other non-empty line there.
func scanLines(manifest string) (marker, other bool) {
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		switch line {
		case noChange:
			marker = true
		case "":
		default:
			other = true
		}
	}
	return marker, other
}

// goPath is one Go path a manifest line names inside the module, and
// whether the head tree no longer has it: the path of a D line or the
// old side of an R line.
type goPath struct {
	rel     string
	deleted bool
}

// goPaths returns every Go path a manifest line after the header names
// inside the module.
func goPaths(manifest string) []goPath {
	var out []goPath
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		fields := strings.Split(line, "\t")
		for i, p := range linePaths(line) {
			rel, ok := strings.CutPrefix(p, modulePrefix)
			if !ok || !strings.HasSuffix(rel, ".go") {
				continue
			}
			deleted := fields[0] == "D" || (strings.HasPrefix(fields[0], "R") && i == 0)
			out = append(out, goPath{rel: rel, deleted: deleted})
		}
	}
	return out
}

// hasPackage reports whether pkgs holds the package at the
// module-relative directory dir (`.` for the module root).
func hasPackage(pkgs []Package, module, dir string) bool {
	want := importPath(module, dir)
	for _, p := range pkgs {
		if p.ImportPath == want {
			return true
		}
	}
	return false
}

// importPath returns the import path of the package at the module-relative
// directory dir (`.` for the module root).
func importPath(module, dir string) string {
	if dir == "." {
		return module
	}
	return module + "/" + dir
}

// modulePaths returns the module-relative form of every path a manifest
// line after the header names inside the module.
func modulePaths(manifest string) []string {
	var out []string
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		for _, p := range linePaths(line) {
			if rel, ok := strings.CutPrefix(p, modulePrefix); ok {
				out = append(out, rel)
			}
		}
	}
	return out
}

// listsRootTestdata reports whether a manifest line after the header
// names a path under the module-root testdata/.
func listsRootTestdata(manifest string) bool {
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		for _, p := range linePaths(line) {
			if strings.HasPrefix(p, modulePrefix+"testdata/") {
				return true
			}
		}
	}
	return false
}

// linePaths returns the raw paths one manifest line names: every field
// after the status, each read back from the C-quoted spelling the producer
// writes for a path that holds a control byte, a double quote or a
// backslash (config_gen_mutation_lang.sh _cgm_quote). A spelling that does
// not read back is kept as written.
func linePaths(line string) []string {
	fields := strings.Split(line, "\t")[1:]
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		out = append(out, unquote(f))
	}
	return out
}

// unquote reads back a C-quoted spelling: each escape the producer writes
// (\a \b \t \n \v \f \r \" \\ and \ooo) as the one byte it stands for, every
// other byte as is. A spelling that is not quoted, or does not read back,
// is returned as written.
func unquote(s string) string {
	body, open := strings.CutPrefix(s, `"`)
	body, closed := strings.CutSuffix(body, `"`)
	if !open || !closed {
		return s
	}
	var b strings.Builder
	for body != "" {
		if body[0] != '\\' {
			b.WriteByte(body[0])
			body = body[1:]
			continue
		}
		r, _, tail, err := strconv.UnquoteChar(body, '"')
		if err != nil {
			return s
		}
		b.WriteByte(byte(r))
		body = tail
	}
	return b.String()
}

// report is the part of a gremlins -o report the gate reads.
type report struct {
	Files []struct {
		Mutations []struct {
			Status string `json:"status"`
		} `json:"mutations"`
	} `json:"files"`
}

// Efficacy reads a gremlins -o report and returns its KILLED mutants over
// its KILLED, LIVED and TIMED OUT ones, in integer tenths of a percent: a
// timed-out mutant is judged and not killed (base#1467). It never reads
// gremlins' own efficacy field. An error is a report it cannot decode or
// one that holds none of those statuses.
func Efficacy(body []byte) (int, error) {
	var r report
	if err := json.Unmarshal(body, &r); err != nil {
		return 0, err
	}
	killed, judged := 0, 0
	for _, f := range r.Files {
		for _, m := range f.Mutations {
			switch m.Status {
			case "KILLED":
				killed++
				judged++
			case "LIVED", "TIMED OUT":
				judged++
			}
		}
	}
	if judged == 0 {
		return 0, errors.New("report holds no KILLED, LIVED or TIMED OUT mutant")
	}
	return killed * 1000 / judged, nil
}
