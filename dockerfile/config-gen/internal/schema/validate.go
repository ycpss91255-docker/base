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
// Every alternative a list validator accepts through has a witness row
// in corpus/s6/s6_alternatives.tsv, written from _tui_conf.sh.
type rule struct {
	valid         func(text string) bool
	kinds         []Kind
	validateEmpty bool
}

// words is a `case` arm that accepts exactly one of ws.
func words(ws ...string) func(string) bool {
	return func(text string) bool { return slices.Contains(ws, text) }
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
	"deploy.gpu_mode":                 {valid: validDetectMode, kinds: kindsString},
	"deploy.gpu_count":                {valid: validGPUCount, kinds: []Kind{KindString, KindInt}, validateEmpty: true},
	"deploy.gpu_capabilities":         {valid: validGPUCapabilities, kinds: kindsString, validateEmpty: true},
	"deploy.gpu_runtime":              {valid: validRuntime, kinds: kindsString},
	"deploy.runtime":                  {valid: validRuntime, kinds: kindsString},
	"deploy.dri_groups":               {valid: validDRIGroups, kinds: kindsString},
	"gui.mode":                        {valid: validDetectMode, kinds: kindsString},
	"security.privileged":             {valid: validBool, kinds: kindsBool},
	"resources.shm_size":              {valid: shmSize, kinds: kindsString},
	"lifecycle.restart":               {valid: validRestart, kinds: kindsString},
	"lifecycle.init":                  {valid: validBool, kinds: kindsBool},
	"lifecycle.watchdog_check":        {valid: validWatchdogCmd, kinds: kindsString},
	"lifecycle.watchdog_interval":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_timeout":      {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_start_period": {valid: nonNegInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_failures":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_on_fail":      {valid: words("restart-container", "restart-service"), kinds: kindsString},
	"lifecycle.watchdog_max_restarts": {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_notify":       {valid: validWatchdogCmd, kinds: kindsString},
	"build.target_arch":               {valid: words("", "amd64", "arm64", "arm", "386", "ppc64le", "s390x", "riscv64"), kinds: kindsString},
	"build.network":                   {valid: words("", "auto", "host", "bridge", "none", "default", "off"), kinds: kindsString},
	"network.network_name":            {valid: networkName.MatchString, kinds: kindsString},
	"network.mode":                    {valid: containerOr("host", "bridge", "none"), kinds: kindsString},
	"network.ipc":                     {valid: containerOr("host", "private", "shareable", "none"), kinds: kindsString},
	"network.pid":                     {valid: containerOr("host", "private"), kinds: kindsString},
	"logging.driver":                  {valid: logDriver.MatchString, kinds: kindsString},
	"logging.max_size":                {valid: logMaxSize, kinds: kindsString},
	"logging.max_file":                {valid: posInt.MatchString, kinds: kindsInt},
	"logging.compress":                {valid: validBool, kinds: kindsBool},
	"logging.local_path":              {valid: validLogLocalPath, kinds: kindsString},
	"logging.container_log_keep":      {valid: posInt.MatchString, kinds: kindsInt},
	"logging.container_log_days":      {valid: posInt.MatchString, kinds: kindsInt},
	"logging.wrapper_transcript":      {valid: validBool, kinds: kindsBool},
	"logging.wrapper_transcript_keep": {valid: posInt.MatchString, kinds: kindsInt},
	"logging.wrapper_transcript_days": {valid: posInt.MatchString, kinds: kindsInt},
	// The numbered families, keyed by schema.sh's trailing-_ prefix.
	"image.rule_":                  {valid: validImageRule, kinds: kindsString},
	"security.security_opt_":       {valid: validSecurityOpt, kinds: kindsString},
	"build.arg_":                   {valid: validEnvKV, kinds: kindsString},
	"volumes.mount_":               {valid: validMount, kinds: kindsString},
	"devices.device_":              {valid: validMount, kinds: kindsString},
	"devices.cgroup_rule_":         {valid: cgroupRule.MatchString, kinds: kindsString},
	"environment.env_":             {valid: validEnvKV, kinds: kindsString},
	"tmpfs.tmpfs_":                 {valid: validTmpfs, kinds: kindsString},
	"network.port_":                {valid: portMapping.MatchString, kinds: kindsString},
	"additional_contexts.context_": {valid: validAdditionalContext, kinds: kindsString},
	"security.cap_add_":            {valid: capability.MatchString, kinds: kindsString},
	"security.cap_drop_":           {valid: capability.MatchString, kinds: kindsString},
}

// canonicalKey is schema.sh's _schema_canonical_key lookup. A stage
// section text `stage:<name>.<section>` is the same setting as
// <section>, so `stage:` and the name up to the first `.` are stripped
// first (`${section#stage:*.}`, shortest match: stage:dev.logging.web is
// logging.web, stage:a.b.logging is b.logging; a bare stage:<name> is
// kept and has no key set). Then a per-service section text
// `logging.<service>` shares the [logging] key set, the exact
// section.key is looked up first, then a numbered key (`^(.+_)[0-9]+$`)
// by its trailing-_ prefix. It returns the validators key that matched.
func canonicalKey(section, key string) (string, bool) {
	if rest, ok := strings.CutPrefix(section, "stage:"); ok {
		if _, after, found := strings.Cut(rest, "."); found {
			section = after
		}
	}
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
// bridge's text for a value at section.key, section being the shell's
// section text, a stage or a per-service one included (canonicalKey,
// base#1442 review round 2): a key with no validator
// accepts any text, an empty text is accepted unless the key's
// SCHEMA_EMPTY policy is `validate`, and otherwise the key's validator
// decides. A refused text is conf_value_invalid. The value's TOML kind is
// not judged here; Decode refuses a value outside its key's type
// (kindRefused) before it asks Validate.
func Validate(section, key, text string) error {
	r, ok := canonical(section, key)
	if !ok || (text == "" && !r.validateEmpty) || r.valid(text) {
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
var (
	shmSize    = sizeWithUnit("b", "k", "m", "g", "kb", "mb", "gb")
	logMaxSize = sizeWithUnit("b", "k", "m", "g")
)

// sizeWithUnit is a validator `[[ $v =~ ^[0-9]+(<unit>|...)$ ]]` run under
// `shopt -s nocasematch` and LC_ALL=C: one or more ASCII digits, then one
// of units (lower case) in any ASCII case. Under LC_ALL=C only A-Z and a-z
// have a case, so "1"+U+212A KELVIN SIGN is refused; a Go `(?i)` regexp
// accepted it as "1k" (s6_scalar_values.tsv, base#1442 review round 1).
func sizeWithUnit(units ...string) func(string) bool {
	return func(text string) bool {
		i := 0
		for i < len(text) && text[i] >= '0' && text[i] <= '9' {
			i++
		}
		return i > 0 && slices.Contains(units, asciiLower(text[i:]))
	}
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
// ws, or `container:` followed by at least one character.
func containerOr(ws ...string) func(string) bool {
	return func(text string) bool {
		return slices.Contains(ws, text) ||
			(strings.HasPrefix(text, "container:") && len(text) > len("container:"))
	}
}

// fields is bash's `read -ra` with the default IFS: words split on runs
// of space, tab and newline. A non-breaking space does not split.
func fields(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// validBool ports _validate_privileged, _init, _log_compress and
// _wrapper_transcript.
var validBool = words("true", "false")

// validGPUCount ports _validate_gpu_count: `all`, or a positive integer.
func validGPUCount(text string) bool {
	return text == "all" || posInt.MatchString(text)
}

// validProjectName ports _validate_project_name.
func validProjectName(text string) bool {
	return projectName.MatchString(text)
}

// validDetectMode ports _validate_detect_mode.
var validDetectMode = words("", "auto", "force", "off")

// validRuntime ports _validate_runtime.
var validRuntime = words("", "auto", "nvidia", "off")

// validRestart ports _validate_restart: one of the words, or
// `on-failure:` and a positive integer.
func validRestart(text string) bool {
	if n, ok := strings.CutPrefix(text, "on-failure:"); ok {
		return posInt.MatchString(n)
	}
	return slices.Contains([]string{"no", "always", "unless-stopped", "on-failure"}, text)
}

// gpuCapabilities is _VALID_GPU_CAPABILITIES.
var gpuCapabilities = []string{"gpu", "compute", "utility", "graphics", "all", "video", "display", "compat32", "ngx"}

// validGPUCapabilities ports _validate_gpu_capabilities: not empty, and
// every word one of _VALID_GPU_CAPABILITIES.
func validGPUCapabilities(text string) bool {
	if text == "" {
		return false
	}
	for _, w := range fields(text) {
		if !slices.Contains(gpuCapabilities, w) {
			return false
		}
	}
	return true
}

// validDRIGroups ports _validate_dri_groups: empty, auto or off, or one
// or more GIDs; a byte outside [:print:] (LC_ALL=C: 0x20-0x7e) refuses.
func validDRIGroups(text string) bool {
	if slices.Contains([]string{"", "auto", "off"}, text) {
		return true
	}
	for i := 0; i < len(text); i++ {
		if text[i] < 0x20 || text[i] > 0x7e {
			return false
		}
	}
	gids := fields(text)
	if len(gids) == 0 {
		return false
	}
	for _, g := range gids {
		if !gid.MatchString(g) {
			return false
		}
	}
	return true
}

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
// prefixes followed by at least one byte.
func validImageRule(text string) bool {
	if text == "" || text == "@basename" {
		return true
	}
	for _, p := range imageRulePrefixes {
		if strings.HasPrefix(text, p) && len(text) > len(p) {
			return true
		}
	}
	return false
}

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
// access word.
func validMount(text string) bool {
	if text == "" || cSpace(text) {
		return false
	}
	parts := readSplit(text, ":")
	if (len(parts) != 2 && len(parts) != 3) || parts[0] == "" || parts[1] == "" {
		return false
	}
	if len(parts) == 2 {
		return true
	}
	for _, m := range readSplit(parts[2], ",") {
		if !slices.Contains(mountModes, m) {
			return false
		}
	}
	return true
}

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
