package buildgate

import "strings"

// IgnoredInputs returns one config_gen_mutation_ignored_input file= event
// for each path list (the producer's ignored.sha256: `<spelling>\t<sha256>`
// lines, a spelling C-quoted as the manifest's are) names inside the
// module that present reports is in the build context (base#1467). present
// takes the module-relative path.
func IgnoredInputs(list string, present func(rel string) bool) []Event {
	var out []Event
	for _, line := range strings.Split(list, "\n") {
		spelling, _, _ := strings.Cut(line, "\t")
		p := unquote(spelling)
		if rel, ok := strings.CutPrefix(p, modulePrefix); ok && rel != "" && present(rel) {
			out = append(out, ev("mutation_ignored_input", "file", p))
		}
	}
	return out
}
