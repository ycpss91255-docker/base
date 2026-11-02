package schema

import (
	"regexp"
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
)

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
