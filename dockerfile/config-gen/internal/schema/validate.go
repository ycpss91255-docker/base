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
type rule struct {
	valid         func(text string) bool
	kinds         []Kind
	validateEmpty bool
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
	"resources.shm_size":              {valid: shmSize.MatchString, kinds: kindsString},
	"lifecycle.restart":               {valid: validRestart, kinds: kindsString},
	"lifecycle.init":                  {valid: validBool, kinds: kindsBool},
	"lifecycle.watchdog_check":        {valid: validWatchdogCmd, kinds: kindsString},
	"lifecycle.watchdog_interval":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_timeout":      {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_start_period": {valid: nonNegInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_failures":     {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_on_fail":      {valid: oneOf("restart-container", "restart-service"), kinds: kindsString},
	"lifecycle.watchdog_max_restarts": {valid: posInt.MatchString, kinds: kindsInt},
	"lifecycle.watchdog_notify":       {valid: validWatchdogCmd, kinds: kindsString},
	"build.target_arch":               {valid: oneOf("", "amd64", "arm64", "arm", "386", "ppc64le", "s390x", "riscv64"), kinds: kindsString},
	"build.network":                   {valid: oneOf("", "auto", "host", "bridge", "none", "default", "off"), kinds: kindsString},
	"network.network_name":            {valid: networkName.MatchString, kinds: kindsString},
	"network.mode":                    {valid: containerOr("host", "bridge", "none"), kinds: kindsString},
	"network.ipc":                     {valid: containerOr("host", "private", "shareable", "none"), kinds: kindsString},
	"network.pid":                     {valid: containerOr("host", "private"), kinds: kindsString},
	"logging.driver":                  {valid: logDriver.MatchString, kinds: kindsString},
	"logging.max_size":                {valid: logMaxSize.MatchString, kinds: kindsString},
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

// canonical is schema.sh's _schema_canonical_key lookup: a per-service
// section text `logging.<service>` shares the [logging] key set, then the
// exact section.key is looked up first, then a numbered key
// (`^(.+_)[0-9]+$`) by its trailing-_ prefix.
func canonical(section, key string) (rule, bool) {
	if strings.HasPrefix(section, "logging.") {
		section = "logging"
	}
	if r, ok := validators[section+"."+key]; ok {
		return r, true
	}
	i := len(key)
	for i > 0 && key[i-1] >= '0' && key[i-1] <= '9' {
		i--
	}
	if i == len(key) || i < 2 || key[i-1] != '_' {
		return rule{}, false
	}
	r, ok := validators[section+"."+key[:i]]
	return r, ok
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
// ASCII too, so a fullwidth digit fails. `(?i)` is the validators'
// `shopt -s nocasematch`.
var (
	posInt      = regexp.MustCompile(`^[1-9][0-9]*$`)
	nonNegInt   = regexp.MustCompile(`^[0-9]+$`)
	gid         = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)
	projectName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
	networkName = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)
	logDriver   = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]*$`)
	shmSize     = regexp.MustCompile(`(?i)^[0-9]+(b|k|m|g|kb|mb|gb)$`)
	logMaxSize  = regexp.MustCompile(`(?i)^[0-9]+[bkmg]$`)
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

// oneOf is a validator whose `case` arm lists the accepted words.
func oneOf(words ...string) func(string) bool {
	return func(text string) bool {
		for _, w := range words {
			if text == w {
				return true
			}
		}
		return false
	}
}

// containerOr ports _validate_network_mode / _ipc_mode / _pid_mode: one of
// the words, or `container:` followed by at least one character.
func containerOr(words ...string) func(string) bool {
	word := oneOf(words...)
	return func(text string) bool {
		return word(text) || (strings.HasPrefix(text, "container:") && len(text) > len("container:"))
	}
}

// fields is bash's `read -ra` with the default IFS: words split on runs
// of space, tab and newline. A non-breaking space does not split.
func fields(text string) []string {
	return strings.FieldsFunc(text, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// validBool ports _validate_privileged, _init, _log_compress and
// _wrapper_transcript.
func validBool(text string) bool {
	return text == "true" || text == "false"
}

// validGPUCount ports _validate_gpu_count.
func validGPUCount(text string) bool {
	return text == "all" || posInt.MatchString(text)
}

// validProjectName ports _validate_project_name.
func validProjectName(text string) bool {
	return projectName.MatchString(text)
}

// validDetectMode ports _validate_detect_mode.
var validDetectMode = oneOf("", "auto", "force", "off")

// validRuntime ports _validate_runtime.
var validRuntime = oneOf("", "auto", "nvidia", "off")

// validRestart ports _validate_restart.
func validRestart(text string) bool {
	if n, ok := strings.CutPrefix(text, "on-failure:"); ok {
		return posInt.MatchString(n)
	}
	return oneOf("no", "always", "unless-stopped", "on-failure")(text)
}

// validGPUCapabilities ports _validate_gpu_capabilities: not empty, and
// every word one of _VALID_GPU_CAPABILITIES.
func validGPUCapabilities(text string) bool {
	if text == "" {
		return false
	}
	known := oneOf("gpu", "compute", "utility", "graphics", "all", "video", "display", "compat32", "ngx")
	for _, w := range fields(text) {
		if !known(w) {
			return false
		}
	}
	return true
}

// validDRIGroups ports _validate_dri_groups: empty, auto or off, or one
// or more GIDs; a byte outside [:print:] (LC_ALL=C: 0x20-0x7e) refuses.
func validDRIGroups(text string) bool {
	if oneOf("", "auto", "off")(text) {
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

// validImageRule ports _validate_image_rule: @basename, or one of the
// prefixes followed by at least one byte.
func validImageRule(text string) bool {
	if text == "" || text == "@basename" {
		return true
	}
	for _, p := range []string{"prefix:", "suffix:", "string:", "@default:"} {
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
	if len(parts) == 3 {
		mode := oneOf("ro", "rw", "rslave", "rshared", "rprivate", "slave", "shared", "private")
		for _, m := range readSplit(parts[2], ",") {
			if !mode(m) {
				return false
			}
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
