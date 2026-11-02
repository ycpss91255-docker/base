package schema

import "regexp"

// ValueError is a value Validate refused, with the event that names it.
type ValueError struct {
	Event   string
	Section string
	Key     string
	Text    string
}

func (e *ValueError) Error() string {
	return e.Event + ": " + e.Section + "." + e.Key + " = " + e.Text
}

// rule is one SCHEMA_VALIDATOR row: the port of the
// dist/script/docker/lib/_tui_conf.sh function it names, the kinds
// dist/setup.toml declares for the key, and whether SCHEMA_EMPTY sends
// the empty string to the validator (`validate`) instead of accepting it.
type rule struct {
	valid         func(text string) bool
	kinds         []Kind
	validateEmpty bool
}

// validators is SCHEMA_VALIDATOR by canonical key. Only
// security.privileged and deploy.gpu_count so far; the other keys follow
// in later cycles of base#1442.
var validators = map[string]rule{
	"security.privileged": {valid: validPrivileged, kinds: []Kind{KindBool}},
	"deploy.gpu_count":    {valid: validGPUCount, kinds: []Kind{KindString, KindInt}, validateEmpty: true},
}

// Validate judges s at section.key as _schema_validate does on the
// bridge's text (dist/script/docker/lib/schema.sh): a key with no
// validator accepts any value, an empty text is accepted unless the key's
// SCHEMA_EMPTY policy is `validate`, and otherwise the validator decides.
// A refused value of a kind the key declares is conf_value_invalid; one
// of another kind is conf_value_type_refused.
func Validate(section, key string, s Scalar) error {
	r, ok := validators[section+"."+key]
	if !ok || (s.Text == "" && !r.validateEmpty) || r.valid(s.Text) {
		return nil
	}
	event := "conf_value_type_refused"
	for _, k := range r.kinds {
		if k == s.Kind {
			event = "conf_value_invalid"
		}
	}
	return &ValueError{Event: event, Section: section, Key: key, Text: s.Text}
}

// validPrivileged ports _validate_privileged (_tui_conf.sh).
func validPrivileged(text string) bool {
	return text == "true" || text == "false"
}

// gpuCount is _validate_gpu_count's `^[1-9][0-9]*$`. Go's [0-9] matches
// ASCII digits only, so a fullwidth digit fails.
var gpuCount = regexp.MustCompile(`^[1-9][0-9]*$`)

// validGPUCount ports _validate_gpu_count (_tui_conf.sh).
func validGPUCount(text string) bool {
	return text == "all" || gpuCount.MatchString(text)
}
