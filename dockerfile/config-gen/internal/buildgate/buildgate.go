// Package buildgate is the config generator's per-package coverage floor
// ratchet (base#1465). It is built and run only in the Dockerfile's test
// stage, by cmd/cg-gates, after admission has bound the build context to
// the host mutation baseline; it never ships in final.
//
// The floors are the union of every coverage-floors.d/<slice>.txt fragment
// (no index file). Each non-blank line that is not a # comment is
// `<pkg> <floor>`, pkg relative to the module (`.` for its root package)
// and floor either one decimal in 0.0..100.0 or `none`. The base's union,
// floors.base, is what the 05-floors-base step wrote from the merge base:
// the same lines, or the single line `absent` when the base had no
// coverage-floors.d. All comparisons are per package across the unions,
// in integer tenths of a percent, so no float rounding moves a package
// across a floor and moving an entry between fragments changes nothing.
package buildgate

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// None is the floor of a package marked `none`: it has no statements.
const None = -1

// Event is one refusal the ratchet found. String gives the line the
// coverage RUN prints, which config_gen_gates.sh re-emits as the event
// config_gen_<ID>.
type Event struct {
	ID    string
	Attrs [][2]string
}

// String renders `cg_event config_gen_<ID> k=v...`, each value with every
// byte outside 0x21-0x7e, and the % itself, written as %XX.
func (e Event) String() string {
	var b strings.Builder
	b.WriteString("cg_event config_gen_")
	b.WriteString(e.ID)
	for _, a := range e.Attrs {
		b.WriteString(" ")
		b.WriteString(a[0])
		b.WriteString("=")
		for i := 0; i < len(a[1]); i++ {
			c := a[1][i]
			if c < 0x21 || c > 0x7e || c == '%' {
				_, _ = fmt.Fprintf(&b, "%%%02X", c)
				continue
			}
			b.WriteByte(c)
		}
	}
	return b.String()
}

func ev(id string, kv ...string) Event {
	e := Event{ID: id}
	for i := 0; i+1 < len(kv); i += 2 {
		e.Attrs = append(e.Attrs, [2]string{kv[i], kv[i+1]})
	}
	return e
}

var (
	fragmentName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*\.txt$`)
	floorValue   = regexp.MustCompile(`^(100\.0|[0-9]{1,2}\.[0-9])$`)
	pkgPath      = regexp.MustCompile(`^(\.|[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*)$`)
)

// floor is one fragment entry.
type floor struct {
	pkg    string
	tenths int
	file   string
}

// parseLine reads one fragment line; ok is false for a malformed one.
// skip is true for a blank or comment line.
func parseLine(line string) (pkg string, tenths int, skip, ok bool) {
	if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
		return "", 0, true, true
	}
	f := strings.Fields(line)
	if len(f) != 2 || !pkgPath.MatchString(f[0]) {
		return "", 0, false, false
	}
	if f[1] == "none" {
		return f[0], None, false, true
	}
	if !floorValue.MatchString(f[1]) {
		return "", 0, false, false
	}
	whole, frac, _ := strings.Cut(f[1], ".")
	w, _ := strconv.Atoi(whole)
	d, _ := strconv.Atoi(frac)
	return f[0], w*10 + d, false, true
}

// readFragments reads every fragment under dir. exists is false when dir
// does not exist; events holds the fragment_invalid and duplicate
// refusals.
func readFragments(dir string) (floors []floor, events []Event, exists bool, err error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, false, nil
	}
	if err != nil {
		return nil, nil, false, err
	}
	seen := map[string]string{}
	for _, e := range entries {
		name := e.Name()
		if !fragmentName.MatchString(name) {
			events = append(events, ev("coverage_fragment_invalid", "file", name, "reason", "name"))
			continue
		}
		if !e.Type().IsRegular() {
			events = append(events, ev("coverage_fragment_invalid", "file", name, "reason", "not_file"))
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, nil, true, err
		}
		sc := bufio.NewScanner(strings.NewReader(string(body)))
		for n := 1; sc.Scan(); n++ {
			pkg, tenths, skip, ok := parseLine(sc.Text())
			if !ok {
				events = append(events, ev("coverage_fragment_invalid", "file", name, "line", strconv.Itoa(n), "reason", "line"))
				continue
			}
			if skip {
				continue
			}
			if first, dup := seen[pkg]; dup {
				events = append(events, ev("coverage_floor_duplicate", "pkg", pkg, "file", first, "other", name))
				continue
			}
			seen[pkg] = name
			floors = append(floors, floor{pkg: pkg, tenths: tenths, file: name})
		}
	}
	return floors, events, true, nil
}

// readBase reads floors.base: absent, or the base's floors by package; a
// non-nil Event is floors_base_invalid.
func readBase(path string) (base map[string]int, absent bool, bad *Event) {
	body, err := os.ReadFile(path)
	if err != nil {
		e := ev("coverage_floors_base_invalid", "reason", "unreadable")
		return nil, false, &e
	}
	if string(body) == "absent\n" {
		return nil, true, nil
	}
	base = map[string]int{}
	sc := bufio.NewScanner(strings.NewReader(string(body)))
	for sc.Scan() {
		pkg, tenths, skip, ok := parseLine(sc.Text())
		if !ok {
			e := ev("coverage_floors_base_invalid", "reason", "line")
			return nil, false, &e
		}
		if skip {
			continue
		}
		if _, dup := base[pkg]; dup {
			e := ev("coverage_floors_base_invalid", "reason", "duplicate")
			return nil, false, &e
		}
		base[pkg] = tenths
	}
	return base, false, nil
}

// measure is one package's statement counts.
type measure struct {
	stmts, covered int
}

// readMeasured reads coverage.sh --measure's `<import path>\t<stmts>\t
// <covered>` lines, keyed by the path relative to module.
func readMeasured(path, module string) (map[string]measure, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := map[string]measure{}
	sc := bufio.NewScanner(strings.NewReader(string(body)))
	for sc.Scan() {
		f := strings.Split(sc.Text(), "\t")
		if len(f) != 3 {
			return nil, fmt.Errorf("measured line %q is not <pkg>\\t<stmts>\\t<covered>", sc.Text())
		}
		rel := ""
		switch {
		case f[0] == module:
			rel = "."
		case strings.HasPrefix(f[0], module+"/"):
			rel = strings.TrimPrefix(f[0], module+"/")
		default:
			return nil, fmt.Errorf("measured package %q is outside module %q", f[0], module)
		}
		s, err1 := strconv.Atoi(f[1])
		c, err2 := strconv.Atoi(f[2])
		if err1 != nil || err2 != nil || s < 0 || c < 0 || c > s {
			return nil, fmt.Errorf("measured counts in %q are not 0 <= covered <= statements", sc.Text())
		}
		out[rel] = measure{stmts: s, covered: c}
	}
	return out, nil
}

func tenthsString(t int) string {
	return fmt.Sprintf("%d.%d", t/10, t%10)
}

// Ratchet judges the measured counts against the head fragments in
// floorsDir and the base union in basePath. It returns every refusal, in
// a fixed order (fragment refusals, then by package); an error is a
// measurement or a floors directory it could not read at all.
func Ratchet(measuredPath, floorsDir, basePath, module string) ([]Event, error) {
	measured, err := readMeasured(measuredPath, module)
	if err != nil {
		return nil, err
	}
	head, events, exists, err := readFragments(floorsDir)
	if err != nil {
		return nil, err
	}
	base, absent, bad := readBase(basePath)
	if bad != nil {
		return append(events, *bad), nil
	}
	if !exists && !absent {
		return append(events, ev("coverage_floors_dir_deleted")), nil
	}
	byPkg := map[string]floor{}
	pkgs := []string{}
	for _, f := range head {
		byPkg[f.pkg] = f
		pkgs = append(pkgs, f.pkg)
	}
	for pkg := range measured {
		if _, ok := byPkg[pkg]; !ok {
			pkgs = append(pkgs, pkg)
		}
	}
	sort.Strings(pkgs)
	for _, pkg := range pkgs {
		events = append(events, judge(pkg, byPkg, base, measured)...)
	}
	return events, nil
}

// judge applies every per-package rule to pkg.
func judge(pkg string, head map[string]floor, base map[string]int, measured map[string]measure) []Event {
	f, listed := head[pkg]
	got, exists := measured[pkg]
	switch {
	case !exists:
		return []Event{ev("coverage_floor_orphan", "pkg", pkg, "file", f.file)}
	case !listed:
		if _, was := base[pkg]; was {
			return []Event{ev("coverage_floor_dropped", "pkg", pkg)}
		}
		return []Event{ev("coverage_floor_missing", "pkg", pkg)}
	case got.stmts == 0 && f.tenths != None:
		return []Event{ev("coverage_floor_none_misuse", "pkg", pkg, "reason", "no_statements_without_none")}
	case got.stmts == 0:
		return nil
	case f.tenths == None:
		return []Event{ev("coverage_floor_none_misuse", "pkg", pkg, "reason", "none_with_statements")}
	}
	var out []Event
	if f.tenths < 900 {
		out = append(out, ev("coverage_floor_too_low", "pkg", pkg, "floor", tenthsString(f.tenths)))
	}
	if b, was := base[pkg]; was && b != None && f.tenths < b {
		out = append(out, ev("coverage_floor_lowered", "pkg", pkg, "floor", tenthsString(f.tenths), "base", tenthsString(b)))
	}
	measuredTenths := tenthsString(got.covered * 1000 / got.stmts)
	switch {
	case got.covered*1000 < f.tenths*got.stmts:
		out = append(out, ev("coverage_floor_below", "pkg", pkg, "measured", measuredTenths, "floor", tenthsString(f.tenths)))
	case got.covered*1000 >= (f.tenths+10)*got.stmts:
		out = append(out, ev("coverage_floor_stale", "pkg", pkg, "measured", measuredTenths, "floor", tenthsString(f.tenths)))
	}
	return out
}
