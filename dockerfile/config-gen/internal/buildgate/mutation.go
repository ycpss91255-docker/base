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

// PackageFailed is the event the gate prints for each package it fails
// (base#1467): pkg is the package's import path and reason why it failed,
// followed by the key-value pairs kv (`measured`, <e> for reason below).
func PackageFailed(pkg, reason string, kv ...string) Event {
	return ev("mutation_package_failed", append([]string{"pkg", pkg, "reason", reason}, kv...)...)
}

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
	// Removed are the module-relative directories of deleted paths that
	// map to a package the head tree no longer holds.
	Removed []string
}

// testcorpus is the one package that reads the module-root testdata/.
const testcorpus = "internal/testcorpus"

// moduleWide are the module-root files that change every package's
// build or test.
var moduleWide = map[string]bool{"go.mod": true, "go.sum": true, ".golangci.yml": true}

// Map returns the module-relative package directories the manifest
// makes the gate test, each manifest path classified once by classify: a
// Go file maps to its directory's package and a file under a package's own
// testdata/ to that package (a .go file there is a fixture, never a
// package), each refused as config_gen_mutation_no_such_package pkg= when
// pkgs holds no package there and the head tree should hold the path, and
// recorded in Removed instead when it is deleted (a D line, or the old side
// of an R line); go.mod, go.sum or .golangci.yml map to every package of
// the module, the root package included; a file under the module-root
// testdata/ to every package whose test binary depends on
// internal/testcorpus; a coverage-floors.d fragment (a name Ratchet reads
// as one) to no package. Any other module file is refused as
// config_gen_mutation_unmapped, and a manifest that holds the no-change
// marker beside any other line as config_gen_mutation_manifest_invalid
// reason=marker_beside_lines, and one with neither a record nor the marker
// after its header as reason=empty_manifest. module is the module path;
// pkgs is `go list -json -test -deps ./...` of the module.
func Map(manifest, module string, pkgs []Package) (Mapping, error) {
	marker, other := scanLines(manifest)
	if marker && other {
		return Mapping{}, errors.New(ev("mutation_manifest_invalid", "reason", "marker_beside_lines").String())
	}
	if !marker && !other {
		return Mapping{}, errors.New(ev("mutation_manifest_invalid", "reason", "empty_manifest").String())
	}
	targets, removed := map[string]bool{}, map[string]bool{}
	every, rootTestdata := false, false
	for _, p := range manifestPaths(manifest) {
		kind, dir := classify(p.rel)
		switch kind {
		case kindPackage:
			if !hasPackage(pkgs, module, dir) {
				if !p.deleted {
					return Mapping{}, errors.New(ev("mutation_no_such_package", "pkg", ImportPath(module, dir)).String())
				}
				removed[dir] = true
				continue
			}
			targets[dir] = true
		case kindModuleWide:
			every = true
		case kindRootTestdata:
			rootTestdata = true
		case kindFragment:
		case kindUnmapped:
			return Mapping{}, errors.New(ev("mutation_unmapped", "file", modulePrefix+p.rel).String())
		}
	}
	if every {
		for _, p := range pkgs {
			if dir, ok := moduleDir(module, p.ImportPath); ok {
				targets[dir] = true
			}
		}
	}
	if rootTestdata {
		for _, dir := range CorpusImporters(module, pkgs) {
			targets[dir] = true
		}
	}
	return Mapping{Targets: sortedKeys(targets), Removed: sortedKeys(removed)}, nil
}

// pathKind is what one module path maps to.
type pathKind int

const (
	kindUnmapped     pathKind = iota
	kindPackage               // a Go file, or a file under a package's own testdata/
	kindRootTestdata          // a file under the module-root testdata/
	kindModuleWide            // go.mod, go.sum or .golangci.yml
	kindFragment              // a coverage-floors.d fragment
)

// classify returns what the module-relative path rel maps to and, for
// kindPackage, the package's module-relative directory. testdata/ is
// looked at first, so a .go file under it is never a package of its own.
func classify(rel string) (pathKind, string) {
	if strings.HasPrefix(rel, "testdata/") {
		return kindRootTestdata, ""
	}
	if dir, _, ok := strings.Cut(rel, "/testdata/"); ok {
		return kindPackage, dir
	}
	if moduleWide[rel] {
		return kindModuleWide, ""
	}
	if dir, name := path.Split(rel); dir == "coverage-floors.d/" && fragmentName.MatchString(name) {
		return kindFragment, ""
	}
	if strings.HasSuffix(rel, ".go") {
		return kindPackage, path.Dir(rel)
	}
	return kindUnmapped, ""
}

// moduleDir returns the module-relative directory (`.` for the root) of
// the module package importPath names, and false for any other record of
// `go list -json -test -deps`: a package outside the module, a test
// variant (`<pkg> [<pkg>.test]`) or a test binary (`<pkg>.test`).
func moduleDir(module, importPath string) (string, bool) {
	if importPath == module {
		return ".", true
	}
	rel, ok := strings.CutPrefix(importPath, module+"/")
	if !ok || strings.Contains(rel, " ") || strings.HasSuffix(rel, ".test") {
		return "", false
	}
	return rel, true
}

// sortedKeys returns the keys of set, sorted.
func sortedKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
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

// manifestPath is one path a manifest line after the header names inside
// the module, module-relative, and whether the head tree no longer has it:
// the path of a D line or the old side of an R line.
type manifestPath struct {
	rel     string
	deleted bool
}

// manifestPaths returns every path a manifest line after the header names
// inside the module.
func manifestPaths(manifest string) []manifestPath {
	var out []manifestPath
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		status, _, _ := strings.Cut(line, "\t")
		for i, p := range linePaths(line) {
			rel, ok := strings.CutPrefix(p, modulePrefix)
			if !ok {
				continue
			}
			deleted := status == "D" || (strings.HasPrefix(status, "R") && i == 0)
			out = append(out, manifestPath{rel: rel, deleted: deleted})
		}
	}
	return out
}

// hasPackage reports whether pkgs holds the package at the
// module-relative directory dir (`.` for the module root).
func hasPackage(pkgs []Package, module, dir string) bool {
	want := ImportPath(module, dir)
	for _, p := range pkgs {
		if p.ImportPath == want {
			return true
		}
	}
	return false
}

// ImportPath returns the import path of the package at the module-relative
// directory dir (`.` for the module root).
func ImportPath(module, dir string) string {
	if dir == "." {
		return module
	}
	return module + "/" + dir
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
