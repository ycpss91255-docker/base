package buildgate

import (
	"bytes"
	"encoding/json"
	"errors"
	"path"
	"sort"
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
}

// testcorpus is the one package that reads the module-root testdata/.
const testcorpus = "internal/testcorpus"

// Map returns the module-relative package directories the manifest
// makes the gate test: the directory of every Go file (as Targets), and,
// when the manifest lists a file under the module-root testdata/, every
// package whose test binary depends on internal/testcorpus. module is the
// module path; pkgs is `go list -json -test -deps ./...` of the module.
func Map(manifest, module string, pkgs []Package) (Mapping, error) {
	seen := map[string]bool{}
	out := []string{}
	add := func(dir string) {
		if !seen[dir] {
			seen[dir] = true
			out = append(out, dir)
		}
	}
	for _, dir := range Targets(manifest) {
		add(dir)
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
	return Mapping{Targets: out}, nil
}

// listsRootTestdata reports whether a manifest line after the header
// names a path under the module-root testdata/.
func listsRootTestdata(manifest string) bool {
	lines := strings.Split(manifest, "\n")
	for _, line := range lines[1:] {
		for _, p := range strings.Split(line, "\t")[1:] {
			if strings.HasPrefix(p, modulePrefix+"testdata/") {
				return true
			}
		}
	}
	return false
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
// its KILLED and LIVED ones, in integer tenths of a percent. It never
// reads gremlins' own efficacy field. An error is a report it cannot
// decode or one that holds neither status.
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
			case "LIVED":
				judged++
			}
		}
	}
	if judged == 0 {
		return 0, errors.New("report holds no KILLED or LIVED mutant")
	}
	return killed * 1000 / judged, nil
}
