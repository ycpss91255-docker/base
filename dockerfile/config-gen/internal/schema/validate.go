package schema

import (
	"regexp"
	"slices"
	"strings"
)

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
// A validator that accepts a text through one of a fixed list of
// alternatives is a choice; any other is valid.
type rule struct {
	valid         func(text string) bool
	choice        *choice
	kinds         []Kind
	validateEmpty bool
}

// accepts is the rule's validator on text.
func (r rule) accepts(text string) bool {
	if r.choice != nil {
		_, ok := r.choice.took(text)
		return ok
	}
	return r.valid(text)
}

// choice is a validator that accepts a text through one of a fixed list
// of alternatives: a word of a `case` arm, a prefix, a unit. took reports
// whether text is accepted and the alternatives it went through, so a
// test can require an accepted row through every alternative of every
// choice (base#1442 review round 1: no row went through `string:`).
type choice struct {
	alts []string
	took func(text string) ([]string, bool)
}

// words is a `case` arm that accepts exactly one of ws. An empty word is
// accepted but is not an alternative: Validate never asks a choice about
// the empty string, which only a gpu_count or gpu_capabilities key sends
// to its validator.
func words(ws ...string) *choice {
	var alts []string
	for _, w := range ws {
		if w != "" {
			alts = append(alts, w)
		}
	}
	return &choice{alts: alts, took: func(text string) ([]string, bool) {
		if slices.Contains(ws, text) {
			return []string{text}, true
		}
		return nil, false
	}}
}

var (
	kindsString = []Kind{KindString}
	kindsInt    = []Kind{KindInt}
	kindsBool   = []Kind{KindBool}
)

// validators is the scalar half of SCHEMA_VALIDATOR by canonical key.
// The kinds are dist/setup.toml's: bool for init, privileged, compress
// and wrapper_transcript, int for max_file, the *_keep / *_days and the
// watchdog counts, string|int for gpu_count, string otherwise.
var validators = map[string]rule{
	"project.name":                    {valid: validProjectName, kinds: kindsString},
	"deploy.gpu_mode":                 {choice: validDetectMode, kinds: kindsString},
	"deploy.gpu_count":                {choice: validGPUCount, kinds: []Kind{KindString, KindInt}, validateEmpty: true},
	"deploy.gpu_capabilities":         {choice: validGPUCapabilities, kinds: kindsString, validateEmpty: true},
	"deploy.gpu_runtime":              {choice: validRuntime, kinds: kindsString},
	"deploy.runtime":                  {choice: validRuntime, kinds: kindsString},
	"deploy.dri_groups":               {choice: validDRIGroups, kinds: kindsString},
	"gui.mode":                        {choice: validDetectMode, kinds: kindsString},
	"security.privileged":             {choice: validBool, kinds: kindsBool},
	"resources.shm_size":              {choice: shmSize, kinds: kindsString},
	"lifecycle.restart":               {choice: validRestart, kinds: kindsString},
	"lifecycle.init":                  {choice: validBool, kinds: kindsBool},
	"lifecycle.watchdog_check":        {valid: validWatchdogCmd, kinds: kindsString},
	"lifecycle.watchdog_interval":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_timeout":      {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_start_period": {valid: nonNegInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_failures":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_on_fail":      {choice: words("restart-container", "restart-service"), kinds: kindsString},
	"lifecycle.watchdog_max_restarts": {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_notify":       {valid: validWatchdogCmd, kinds: kindsString},
	"build.target_arch":               {choice: words("", "amd64", "arm64", "arm", "386", "ppc64le", "s390x", "riscv64"), kinds: kindsString},
	"build.network":                   {choice: words("", "auto", "host", "bridge", "none", "default", "off"), kinds: kindsString},
	"network.network_name":            {valid: networkName.MatchString, kinds: kindsString},
	"network.mode":                    {choice: containerOr("host", "bridge", "none"), kinds: kindsString},
	"network.ipc":                     {choice: containerOr("host", "private", "shareable", "none"), kinds: kindsString},
	"network.pid":                     {choice: containerOr("host", "private"), kinds: kindsString},
	"logging.driver":                  {valid: logDriver.MatchString, kinds: kindsString},
	"logging.max_size":                {choice: logMaxSize, kinds: kindsString},
	"logging.max_file":                {valid: posInt.MatchString, kinds: kindsInt},
	"logging.compress":                {choice: validBool, kinds: kindsBool},
	"logging.local_path":              {valid: validLogLocalPath, kinds: kindsString},
	"logging.container_log_keep":      {valid: posInt.MatchString, kinds: kindsInt},
	"logging.container_log_days":      {valid: posInt.MatchString, kinds: kindsInt},
	"logging.wrapper_transcript":      {choice: validBool, kinds: kindsBool},
	"logging.wrapper_transcript_keep": {valid: posInt.MatchString, kinds: kindsInt},
	"logging.wrapper_transcript_days": {valid: posInt.MatchString, kinds: kindsInt},
	// The numbered families, keyed by schema.sh's trailing-_ prefix.
	"image.rule_":                  {choice: validImageRule, kinds: kindsString},
	"security.security_opt_":       {valid: validSecurityOpt, kinds: kindsString},
	"build.arg_":                   {valid: validEnvKV, kinds: kindsString},
	"volumes.mount_":               {choice: validMount, kinds: kindsString},
	"devices.device_":              {choice: validMount, kinds: kindsString},
	"devices.cgroup_rule_":         {valid: cgroupRule.MatchString, kinds: kindsString},
	"environment.env_":             {valid: validEnvKV, kinds: kindsString},
	"tmpfs.tmpfs_":                 {valid: validTmpfs, kinds: kindsString},
	"network.port_":                {valid: portMapping.MatchString, kinds: kindsString},
	"additional_contexts.context_": {valid: validAdditionalContext, kinds: kindsString},
	"security.cap_add_":            {valid: capability.MatchString, kinds: kindsString},
	"security.cap_drop_":           {valid: capability.MatchString, kinds: kindsString},
}

// canonicalKey is schema.sh's _schema_canonical_key lookup: a per-service
// section text `logging.<service>` shares the [logging] key set, then the
// exact section.key is looked up first, then a numbered key
// (`^(.+_)[0-9]+$`) by its trailing-_ prefix. It returns the validators
// key that matched.
func canonicalKey(section, key string) (string, bool) {
	if strings.HasPrefix(section, "logging.") {
		section = "logging"
	}
	if _, ok := validators[section+"."+key]; ok {
		return section + "." + key, true
	}
	i := len(key)
	for i > 0 && key[i-1] >= '0' && key[i-1] <= '9' {
		i--
	}
	if i == len(key) || i < 2 || key[i-1] != '_' {
		return "", false
	}
	_, ok := validators[section+"."+key[:i]]
	return section + "." + key[:i], ok
}

// canonical is the rule canonicalKey finds.
func canonical(section, key string) (rule, bool) {
	k, ok := canonicalKey(section, key)
	return validators[k], ok
}

// Validate is _schema_validate (dist/script/docker/lib/schema.sh) on the
// bridge's text for a value at section.key: a key with no validator
// accepts any text, an empty text is accepted unless the key's
// SCHEMA_EMPTY policy is `validate`, and otherwise the key's validator
// decides. A refused text is conf_value_invalid. The value's TOML kind is
// not judged here; Decode refuses a value outside its key's type
// (kindRefused) before it asks Validate.
func Validate(section, key, text string) error {
	r, ok := canonical(section, key)
	if !ok || (text == "" && !r.validateEmpty) || r.accepts(text) {
		return nil
	}
	return &ValueError{Event: "conf_value_invalid", Section: section, Key: key, Text: text}
}

// kindRefused reports whether s is outside the type of section.key
// (ADR-00000039: a value outside its field's type is refused at load,
// base#1314). A key whose kinds are more than the string kind, a bool or
// an int key or gpu_count's string|int, takes only its kinds, so
// `privileged = "true"` and `max_file = 3.0` are refused although
// schema.sh passes their text. Any other key takes any scalar kind and is
// judged on its text (ADR-00000039 l.121: a date or a number in a string
// field is an accepted spelling). The empty string stays the default
// empty policy's at a typed key, as schema.sh accepts it there.
func kindRefused(section, key string, s Scalar) bool {
	r, ok := canonical(section, key)
	if !ok || slices.Equal(r.kinds, kindsString) || slices.Contains(r.kinds, s.Kind) {
		return false
	}
	return s.Kind != KindString || s.Text != ""
}

// The regular expressions of the _tui_conf.sh validators. schema.sh runs
// under LC_ALL=C, where a bracket range is ASCII bytes; Go's ranges are
// ASCII too, so a fullwidth digit fails. No pattern here folds case: the
// two validators that run under `shopt -s nocasematch` are sizeWithUnit.
var (
	posInt      = regexp.MustCompile(`^[1-9][0-9]*$`)
	nonNegInt   = regexp.MustCompile(`^[0-9]+$`)
	gid         = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)
	projectName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
	networkName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)
	logDriver   = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]*$`)
	portMapping = regexp.MustCompile(`^[0-9]+:[0-9]+(/(tcp|udp))?$`)
	cgroupRule  = regexp.MustCompile(`^[cba][[:space:]]+([0-9]+|\*):([0-9]+|\*)[[:space:]]+[rwm]+$`)
	capability  = regexp.MustCompile(`^[A-Z_]+$`)
	envKV       = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	securityOpt = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]*[:=].`)
	contextName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)
	tmpfsOpt    = `[A-Za-z_][A-Za-z0-9_-]*(=[^,:]+)?`
	tmpfsPath   = regexp.MustCompile(`^/[^:]+$`)
	tmpfsOpts   = regexp.MustCompile(`^/[^:]+:` + tmpfsOpt + `(,` + tmpfsOpt + `)*$`)
)

// shmSize ports _validate_shm_size and logMaxSize _validate_log_max_size.
// Each unit is an alternative.
var (
	shmSize    = sizeWithUnit("b", "k", "m", "g", "kb", "mb", "gb")
	logMaxSize = sizeWithUnit("b", "k", "m", "g")
)

// sizeWithUnit is a validator `[[ $v =~ ^[0-9]+(<unit>|...)$ ]]` run under
// `shopt -s nocasematch` and LC_ALL=C: one or more ASCII digits, then one
// of units (lower case) in any ASCII case. Under LC_ALL=C only A-Z and a-z
// have a case, so "1"+U+212A KELVIN SIGN is refused; a Go `(?i)` regexp
// accepted it as "1k" (s6_scalar_values.tsv, base#1442 review round 1).
func sizeWithUnit(units ...string) *choice {
	return &choice{alts: units, took: func(text string) ([]string, bool) {
		i := 0
		for i < len(text) && text[i] >= '0' && text[i] <= '9' {
			i++
		}
		u := asciiLower(text[i:])
		if i == 0 || !slices.Contains(units, u) {
			return nil, false
		}
		return []string{u}, true
	}}
}

// asciiLower maps A-Z to a-z and keeps every other byte.
func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// cSpace is a byte of LC_ALL=C [[:space:]]: space, \t, \n, \v, \f, \r.
func cSpace(text string) bool {
	return strings.ContainsAny(text, " \t\n\v\f\r")
}

// readSplit is bash's `IFS=<sep> read -ra` for one non-whitespace sep:
// the fields between separators, with one trailing empty field dropped
// (`a:b:` is two fields, `a:b::` three) and none for the empty string.
func readSplit(text string, sep string) []string {
	if text == "" {
		return nil
	}
	parts := strings.Split(text, sep)
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// containerOr ports _validate_network_mode / _ipc_mode / _pid_mode: one of
// ws, or `container:` followed by at least one character. The
// alternatives are ws and `container:`.
func containerOr(ws ...string) *choice {
	return &choice{alts: append(slices.Clip(ws), "container:"), took: func(text string) ([]string, bool) {
		if slices.Contains(ws, text) {
			return []string{text}, true
		}
		if strings.HasPrefix(text, "container:") && len(text) > len("container:") {
			return []string{"container:"}, true
		}
		return nil, false
	}}
}

// fields is bash's `read -ra` with the default IFS: words split on runs
// of space, tab and newline. A non-breaking space does not split.
func fields(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// validBool ports _validate_privileged, _init, _log_compress and
// _wrapper_transcript.
var validBool = words("true", "false")

// validGPUCount ports _validate_gpu_count: `all`, or a positive integer
// (the alternative `<n>`).
var validGPUCount = &choice{alts: []string{"all", "<n>"}, took: func(text string) ([]string, bool) {
	switch {
	case text == "all":
		return []string{"all"}, true
	case posInt.MatchString(text):
		return []string{"<n>"}, true
	}
	return nil, false
}}

// validProjectName ports _validate_project_name.
func validProjectName(text string) bool {
	return projectName.MatchString(text)
}

// validDetectMode ports _validate_detect_mode.
var validDetectMode = words("", "auto", "force", "off")

// validRuntime ports _validate_runtime.
var validRuntime = words("", "auto", "nvidia", "off")

// validRestart ports _validate_restart: one of the words, or
// `on-failure:` and a positive integer (the alternative `on-failure:<n>`).
var validRestart = &choice{
	alts: []string{"no", "always", "unless-stopped", "on-failure", "on-failure:<n>"},
	took: func(text string) ([]string, bool) {
		if n, ok := strings.CutPrefix(text, "on-failure:"); ok {
			if posInt.MatchString(n) {
				return []string{"on-failure:<n>"}, true
			}
			return nil, false
		}
		if slices.Contains([]string{"no", "always", "unless-stopped", "on-failure"}, text) {
			return []string{text}, true
		}
		return nil, false
	},
}

// gpuCapabilities is _VALID_GPU_CAPABILITIES.
var gpuCapabilities = []string{"gpu", "compute", "utility", "graphics", "all", "video", "display", "compat32", "ngx"}

// validGPUCapabilities ports _validate_gpu_capabilities: not empty, and
// every word one of _VALID_GPU_CAPABILITIES; each word is an alternative.
var validGPUCapabilities = &choice{alts: gpuCapabilities, took: func(text string) ([]string, bool) {
	if text == "" {
		return nil, false
	}
	ws := fields(text)
	for _, w := range ws {
		if !slices.Contains(gpuCapabilities, w) {
			return nil, false
		}
	}
	return ws, true
}}

// validDRIGroups ports _validate_dri_groups: empty, auto or off, or one
// or more GIDs (the alternative `<gids>`); a byte outside [:print:]
// (LC_ALL=C: 0x20-0x7e) refuses.
var validDRIGroups = &choice{alts: []string{"auto", "off", "<gids>"}, took: func(text string) ([]string, bool) {
	if slices.Contains([]string{"", "auto", "off"}, text) {
		return []string{text}, true
	}
	for i := 0; i < len(text); i++ {
		if text[i] < 0x20 || text[i] > 0x7e {
			return nil, false
		}
	}
	gids := fields(text)
	if len(gids) == 0 {
		return nil, false
	}
	for _, g := range gids {
		if !gid.MatchString(g) {
			return nil, false
		}
	}
	return []string{"<gids>"}, true
}}

// validWatchdogCmd ports _validate_watchdog_cmd: one non-empty line.
func validWatchdogCmd(text string) bool {
	return text != "" && !strings.Contains(text, "\n")
}

// validLogLocalPath ports _validate_log_local_path: one line that is not
// empty and not only spaces.
func validLogLocalPath(text string) bool {
	return strings.ReplaceAll(text, " ", "") != "" && !strings.Contains(text, "\n")
}

// imageRulePrefixes are _validate_image_rule's `<prefix>?*` patterns.
var imageRulePrefixes = []string{"prefix:", "suffix:", "string:", "@default:"}

// validImageRule ports _validate_image_rule: @basename, or one of the
// prefixes followed by at least one byte. @basename and each prefix are
// the alternatives.
var validImageRule = &choice{alts: append([]string{"@basename"}, imageRulePrefixes...), took: func(text string) ([]string, bool) {
	if text == "" || text == "@basename" {
		return []string{text}, true
	}
	for _, p := range imageRulePrefixes {
		if strings.HasPrefix(text, p) && len(text) > len(p) {
			return []string{p}, true
		}
	}
	return nil, false
}}

// validSecurityOpt ports _validate_security_opt: no whitespace, and a
// key followed by `:` or `=` and at least one byte.
func validSecurityOpt(text string) bool {
	return !cSpace(text) && securityOpt.MatchString(text)
}

// validEnvKV ports _validate_env_kv: one line `KEY=` with any value.
func validEnvKV(text string) bool {
	return !strings.Contains(text, "\n") && envKV.MatchString(text)
}

// mountModes are _validate_mount's propagation and access words.
var mountModes = []string{"ro", "rw", "rslave", "rshared", "rprivate", "slave", "shared", "private"}

// validMount ports _validate_mount: no whitespace, `host:container` or
// `host:container:mode` split as `IFS=: read -ra` splits it, both paths
// non-empty, and every comma-separated mode word a known propagation or
// access word. The alternatives are `<host>:<container>` with no mode and
// each mode word.
var validMount = &choice{alts: append([]string{"<host>:<container>"}, mountModes...), took: func(text string) ([]string, bool) {
	if text == "" || cSpace(text) {
		return nil, false
	}
	parts := readSplit(text, ":")
	if (len(parts) != 2 && len(parts) != 3) || parts[0] == "" || parts[1] == "" {
		return nil, false
	}
	if len(parts) == 2 {
		return []string{"<host>:<container>"}, true
	}
	modes := readSplit(parts[2], ",")
	for _, m := range modes {
		if !slices.Contains(mountModes, m) {
			return nil, false
		}
	}
	return modes, true
}}

// validTmpfs ports _validate_tmpfs: no whitespace, an absolute path with
// no `:`, then optionally `:` and a comma-separated option list.
func validTmpfs(text string) bool {
	return !cSpace(text) && (tmpfsPath.MatchString(text) || tmpfsOpts.MatchString(text))
}

// validAdditionalContext ports _validate_additional_context: one line
// `name=value`, split at the first `=`, both halves non-empty and the
// name a BuildKit context name.
func validAdditionalContext(text string) bool {
	name, val, ok := strings.Cut(text, "=")
	return ok && !strings.Contains(text, "\n") && name != "" && val != "" && contextName.MatchString(name)
}
