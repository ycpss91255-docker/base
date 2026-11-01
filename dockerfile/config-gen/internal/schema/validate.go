package schema

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

// validators is SCHEMA_VALIDATOR by canonical key, each a port of the
// dist/script/docker/lib/_tui_conf.sh function it names. Only
// security.privileged so far; the other keys follow in later cycles of
// base#1442.
var validators = map[string]func(text string) bool{
	"security.privileged": validPrivileged,
}

// Validate judges s at section.key as _schema_validate does on the
// bridge's text (dist/script/docker/lib/schema.sh): a key with no
// validator accepts any value, an empty text is accepted (SCHEMA_EMPTY
// default allow), and otherwise the validator decides. A refused value
// is conf_value_type_refused: the only validated key so far is a bool,
// and every bool text passes, so a refused value is always of another
// kind. The same-kind event follows with the first key where a value of
// the declared kind can fail (base#1442).
func Validate(section, key string, s Scalar) error {
	v, ok := validators[section+"."+key]
	if !ok || s.Text == "" || v(s.Text) {
		return nil
	}
	return &ValueError{Event: "conf_value_type_refused", Section: section, Key: key, Text: s.Text}
}

// validPrivileged ports _validate_privileged (_tui_conf.sh).
func validPrivileged(text string) bool {
	return text == "true" || text == "false"
}
