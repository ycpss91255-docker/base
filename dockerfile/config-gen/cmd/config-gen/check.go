package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/schema"
)

func init() {
	Register("check", check)
}

// frame is one diagnostic (ADR-00000039 section 3, Diagnostics).
type frame struct {
	event, file, key, display string
	line, col                 int
}

// encode is the frame as eight NUL-terminated fields: the tag D, the
// severity, the event id, the file, the line, the column, the key and the
// display text. A field holding U+0000 shows the six characters \u0000 in
// its place, so the frame stays eight fields.
func (f frame) encode() string {
	var b strings.Builder
	for _, field := range []string{"D", "error", f.event, f.file, strconv.Itoa(f.line), strconv.Itoa(f.col), f.key, f.display} {
		b.WriteString(diagField(field))
		b.WriteByte(0)
	}
	return b.String()
}

// diagField replaces each U+0000 in s with the six characters \u0000.
func diagField(s string) string {
	return strings.ReplaceAll(s, "\x00", `\u0000`)
}

// displays is the display text of each refusal event, given the key.
var displays = map[string]string{
	"conf_unknown_key":           "unknown key %s; no reader reads it, so the default would apply instead",
	"conf_unknown_table":         "unknown table [%s]; no reader knows it, so its settings would be dropped",
	"conf_top_level_key":         "key %s is written outside any table",
	"conf_value_type_refused":    "the value of %s is not of the type the key takes",
	"conf_value_invalid":         "the value of %s is not one the key accepts",
	"conf_key_char_refused":      "the name %s holds a tab, LF or CR",
	"conf_value_newline_refused": "the value of %s holds an LF or CR",
	"conf_value_nul_refused":     "%s holds U+0000",
	"conf_toml_parse_failed":     "the layer is not valid TOML (near %s)",
	"conf_entry_not_table":       "%s is not a table, so the entry cannot be read",
	"conf_entry_no_gating_field": "%s carries none of the fields its family is read from",
	"conf_entry_unknown_field":   "%s is a field its family does not read",
	"conf_entry_field_needs":     "%s is written without the field it is read beside",
	"conf_family_two_spellings":  "%s is carried two ways: as a numbered key and in its family's array",
}

// check is `config-gen check [--] <layer>...` (base#1442): it reads and
// decodes each layer and reports every refusal as one diagnostic frame on
// stderr, naming the file, line, column and key. stdout is never written.
//
//	0  every layer decoded with no refusal; nothing is written
//	1  a layer was refused
//	2  usage: no layer, or an argument before `--` starting with `-`;
//	   one config_gen_check_usage frame
//	4  a layer is missing, not a regular file or unreadable (one
//	   config_gen_check_input_failed frame each), or a frame could not be
//	   written; nothing is written after the first failed write
func check(args []string, _, stderr io.Writer) error {
	layers, err := checkArgs(args)
	if err != nil {
		return writeFrames(stderr, exitUsage, err, frame{event: "config_gen_check_usage", display: err.Error()})
	}
	var frames []frame
	status := exitOK
	for _, path := range layers {
		src, err := readLayer(path)
		if err != nil {
			frames = append(frames, frame{event: "config_gen_check_input_failed", file: path, display: err.Error()})
			status = exitPanic
			continue
		}
		_, refusals := schema.Decode(src)
		for _, r := range refusals {
			key := r.Key()
			frames = append(frames, frame{event: r.Event, file: path, line: r.Line, col: r.Col, key: key, display: fmt.Sprintf(displays[r.Event], key)})
			if status == exitOK {
				status = exitError
			}
		}
	}
	if status == exitOK {
		return nil
	}
	return writeFrames(stderr, status, fmt.Errorf("%d diagnostic(s)", len(frames)), frames...)
}

// checkArgs is the layer list of check's arguments.
func checkArgs(args []string) ([]string, error) {
	var layers []string
	dashes := false
	for _, a := range args {
		switch {
		case !dashes && a == "--":
			dashes = true
		case !dashes && strings.HasPrefix(a, "-"):
			return nil, fmt.Errorf("check: unknown flag %q; usage: config-gen check [--] <layer>...", a)
		default:
			layers = append(layers, a)
		}
	}
	if len(layers) == 0 {
		return nil, errors.New("check: no layer given; usage: config-gen check [--] <layer>...")
	}
	return layers, nil
}

// readLayer reads the regular file at path. It is opened non-blocking and
// checked on the open descriptor, so a FIFO in a layer's place is refused
// rather than waited on (base#1400). A descriptor fstat cannot describe is
// not known to be a regular file, so it takes the same refusal (base#1442
// review round 1): one rule, not a second branch no input reaches.
func readLayer(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	if info, err := f.Stat(); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file", path)
	}
	return io.ReadAll(f)
}

// writeFrames writes each frame to w and returns reported(status, cause).
// The first write that fails stops the writing, and the status is then 4.
func writeFrames(w io.Writer, status int, cause error, frames ...frame) error {
	for _, f := range frames {
		if _, err := io.WriteString(w, f.encode()); err != nil {
			return reported(exitPanic, fmt.Errorf("write diagnostic: %w", err))
		}
	}
	return reported(status, cause)
}
