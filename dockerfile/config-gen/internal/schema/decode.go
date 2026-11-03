// Package schema decodes a setup.toml layer and refuses what schema.sh
// does not know (base#1442).
package schema

import (
	"bytes"
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
)

// Refusal is one key the decode refused: the event id, the TOML path of
// the key with its raw bytes, and the 1-based line and byte column it is
// written on (0 when no position is known).
type Refusal struct {
	Event string
	Path  []string
	Line  int
	Col   int
}

// Config is the decoded layer.
type Config struct {
	Deploy      Deploy
	Environment Environment
	Logging     Logging
	// Deprecated is every key of the layer written in a deprecated
	// spelling, owned by this decode.
	Deprecated []Deprecation
	// Tree is every accepted table node, in the bridge's traversal order.
	Tree Tree
	// Deferred is every accepted array with its payload, in the order its
	// ChildDeferred appears in the traversal; Child.Defer indexes it.
	Deferred []Deferred
	// Arrays is every accepted array of tables typed as a family, keyed by
	// its TOML path joined with "." (base#1443).
	Arrays map[string]Family
}

// known is the set of sections _setup_known_section accepts
// (dist/script/docker/lib/setup_cmd.sh) by name: schema.sh's
// SCHEMA_SECTIONS, every one of which carries at least one
// SCHEMA_VALIDATOR row, so it is derived from the sections of the
// validators and not listed a second time (base#1442).
// TestKnownSectionsAreSchemaSections and its bats half hold it equal to
// SCHEMA_SECTIONS.
var known = func() map[string]bool {
	m := map[string]bool{}
	for k := range validators {
		section, _, _ := strings.Cut(k, ".")
		m[section] = true
	}
	return m
}()

// KnownSections returns the section names Decode knows, sorted.
func KnownSections() []string {
	out := make([]string, 0, len(known))
	for s := range known {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// freeForm is the keys _setup_known_key knows with no validator: the
// pre-arg_N [build] named keys _setup_apply lifts into build args.
var freeForm = map[string]bool{
	"build.apt_mirror_ubuntu": true,
	"build.apt_mirror_debian": true,
	"build.tz":                true,
}

// knownKey is _setup_known_key: a key that resolves to a SCHEMA_VALIDATOR
// row, or a free-form key.
func knownKey(section, key string) bool {
	_, ok := canonical(section, key)
	return ok || freeForm[section+"."+key]
}

// stage reports whether the path lies in a `["stage:<name>"]` table,
// whose section text _setup_conf_check_known skips.
func stage(p []string) bool {
	return len(p) > 0 && strings.HasPrefix(p[0], "stage:")
}

// keyCharEvent is the refusal one key or table name draws: U+0000 is
// conf_value_nul_refused (ADR-00000039), and a tab, LF or CR, which the
// bridge's tab-separated view cannot carry (toml_bridge.py
// _check_transportable), is conf_key_char_refused; "" otherwise.
func keyCharEvent(name string) string {
	switch {
	case strings.ContainsRune(name, 0):
		return "conf_value_nul_refused"
	case strings.ContainsAny(name, "\t\n\r"):
		return "conf_key_char_refused"
	}
	return ""
}

// valueCharEvent is the refusal one string value draws: U+0000 is
// conf_value_nul_refused (ADR-00000039), and an LF or CR, which the
// bridge refuses in a value (_check_transportable), is
// conf_value_newline_refused; "" otherwise. A tab in a value is carried.
func valueCharEvent(text string) string {
	switch {
	case strings.ContainsRune(text, 0):
		return "conf_value_nul_refused"
	case strings.ContainsAny(text, "\n\r"):
		return "conf_value_newline_refused"
	}
	return ""
}

// Decode decodes src and returns its refusals, each at the position the
// locator gives the refused table or key (base#1442), sorted by line.
//
// A document the parser refuses is one conf_toml_parse_failed at the
// parser's line and column, naming the last table or key the locator
// found at or before that line, and no Config. A document the parser
// accepts whose bytes the bridge cannot read as text (undecodable) is the
// same refusal at the first such byte.
//
// Otherwise the locator's tree is joined to the parsed value (bind) and
// walked once, depth first, in written order; each table, key and array is
// judged at its own node, a key at its own record and a table at its
// earliest:
//   - a table or key name holding U+0000, a tab, LF or CR is refused
//     (keyCharEvent) once per path, and nothing under it is judged;
//   - every table whose section text schema.sh does not know is a
//     conf_unknown_table refusal, once per section text, as the shell's
//     --tables walk reports each one: `[foo.bar]` refuses both foo and
//     foo.bar. Keys under an unknown table get no refusal of their own;
//   - anything under an array is the array stage's: only its string
//     values are judged here, by valueCharEvent;
//   - a scalar at the root, whatever its name, is one conf_top_level_key;
//   - a string value under a known table holding U+0000, LF or CR is
//     refused (valueCharEvent);
//   - anything else under a `["stage:<name>"]` table is not judged, as
//     _setup_conf_check_known does not judge it;
//   - a scalar or an array under a known table is judged as
//     _setup_known_key and _schema_validate judge its section text and
//     key, the key registry first and the written kind second, so a
//     `[logging.<service>]` key is judged as a [logging] key: an unknown
//     key is conf_unknown_key, an array at a registered key is
//     conf_value_type_refused, a scalar outside its key's type
//     (kindRefused) is conf_value_type_refused, and a scalar whose text
//     Validate refuses is one refusal with Validate's event.
func Decode(src []byte) (*Config, []Refusal) {
	var doc map[string]any
	md, err := toml.Decode(string(src), &doc)
	lines := locate.Index(src)
	if err != nil {
		return nil, []Refusal{parseRefusal(lines, err)}
	}
	if line, col, ok := undecodable(src); ok {
		return nil, []Refusal{attributed(lines, line, col)}
	}
	root := bind(lines.Root(), doc, nil)
	d := decoder{refused: map[string]bool{}, tables: map[string]bool{}}
	d.walk(root, nil, judging)
	tree, deferred, arrays := buildTree(md, root)
	for i, def := range deferred {
		if !d.refusedUnder(def.Path) {
			refused := d.checkEntries(def.Path, arrays[i])
			line, col := arrays[i].declPos()
			for _, e := range arrays[i].children {
				if !refused[e] {
					d.judgeValues(def.Path, e, line, col)
				}
			}
		}
	}
	sort.SliceStable(d.refusals, func(i, j int) bool { return d.refusals[i].Line < d.refusals[j].Line })
	deploy, deprecated := projectDeploy(&tree)
	return &Config{
		Deploy:      deploy,
		Environment: projectEnvironment(&tree),
		Logging:     Logging{Services: ProjectServices(&tree)},
		Deprecated:  deprecated,
		Tree:        tree,
		Deferred:    deferred,
		Arrays:      projectArrays(deferred),
	}, d.refusals
}

// decoder collects the refusals of one Decode.
type decoder struct {
	refusals []Refusal
	// refused holds the pathID of every refused path.
	refused map[string]bool
	// tables holds the section text of every refused table.
	tables map[string]bool
}

// scope is what the walk judges under a node.
type scope int

const (
	// judging: under known tables, every node is judged.
	judging scope = iota
	// unknownTable: under a refused table only tables are judged, each by
	// its section text.
	unknownTable
	// inArray: under an array only names are judged here; values are the
	// array stage's (judgeValues).
	inArray
)

// walk judges every child of b, at path, in written order.
func (d *decoder) walk(b *bound, path []string, s scope) {
	for _, c := range b.children {
		if c.keyless() {
			d.walk(c, path, inArray)
			continue
		}
		p := append(append([]string{}, path...), c.node.Key)
		if event := keyCharEvent(c.node.Key); event != "" {
			if !d.refused[pathID(p)] {
				line, col := c.declPos()
				if c.isTable() {
					line, col = c.firstPos()
				}
				d.refuse(event, p, line, col)
			}
			continue
		}
		next := s
		switch s {
		case inArray:
		case unknownTable:
			if c.isTable() && !accepted(p) {
				d.refuseTable(p, c)
			}
		case judging:
			next = d.judge(c, p)
		}
		if c.isArray() {
			next = inArray
		}
		d.walk(c, p, next)
	}
}

// refuseTable refuses the table b at k as conf_unknown_table at its first
// record, once per section text: the shell reports a text once however
// many paths spell it (_setup_conf_check_known's _sck_reported).
func (d *decoder) refuseTable(k []string, b *bound) {
	text := strings.Join(k, ".")
	if d.tables[text] {
		d.refused[pathID(k)] = true
		return
	}
	d.tables[text] = true
	line, col := b.firstPos()
	d.refuse("conf_unknown_table", k, line, col)
}

func (d *decoder) refuse(event string, k []string, line, col int) {
	d.refused[pathID(k)] = true
	d.refusals = append(d.refusals, Refusal{Event: event, Path: k, Line: line, Col: col})
}

// refusedUnder reports whether p or a prefix of it is refused.
func (d *decoder) refusedUnder(p []string) bool {
	for i := 1; i <= len(p); i++ {
		if d.refused[pathID(p[:i])] {
			return true
		}
	}
	return false
}

// judge judges b at path k, which lies under no array and no refused
// table, and returns the scope of its children.
func (d *decoder) judge(b *bound, k []string) scope {
	section, key := strings.Join(k[:len(k)-1], "."), k[len(k)-1]
	tables := b.node.Kind == locate.NArrayTables
	line, col := b.declPos()
	switch {
	case b.isTable():
		if !accepted(k) {
			d.refuseTable(k, b)
			return unknownTable
		}
		return judging
	case len(k) == 1 && b.isArray():
		// An array at a known section name, `[[volumes]]` or the inline
		// `volumes = [{...}]`, is the legacy spelling the array stage
		// handles. Any other root array is refused as what it is written
		// as: an array-table header is a table, an inline array a root key.
		switch {
		case known[key]:
		case tables:
			d.refuseTable(k, b)
		default:
			d.refuse("conf_top_level_key", k, line, col)
		}
		return inArray
	case len(k) == 1:
		d.refuse("conf_top_level_key", k, line, col)
		return judging
	case stage(k):
		// A `["stage:<name>"]` table is not judged here; only a string
		// value's characters are (below).
	case b.isArray():
		// An array of a numbered family is judged by the row its first
		// entry takes: `[[security.cap_drop]]` and `cap_drop = []` are
		// security.cap_drop_1, as the shell's --kv and --empty-families
		// views name them. Its payload is the array stage's.
		//
		// Any other array, `[[k]]` or `k = [...]`, is refused, as the
		// bridge refuses every array whose key _ARRAY_SPEC has no family
		// for (toml_bridge.py _array_spec): at a key _setup_known_key
		// knows, a registered scalar key or a free-form one, it is a value
		// of the wrong type for that key; at any other key it is unknown.
		// It is refused once, at its first header when written as
		// `[[k]]` headers.
		switch prefix, ok := arrayFamily[key]; {
		case d.refused[pathID(k)]:
		case ok && knownKey(section, prefix+"_1"):
		case ok, !knownKey(section, key):
			d.refuse("conf_unknown_key", k, line, col)
		default:
			d.refuse("conf_value_type_refused", k, line, col)
		}
		return inArray
	}
	if text, ok := b.value.(string); ok {
		if event := valueCharEvent(text); event != "" {
			d.refuse(event, k, line, col)
			return judging
		}
	}
	switch {
	case stage(k):
	case !knownKey(section, key):
		d.refuse("conf_unknown_key", k, line, col)
	default:
		var s Scalar
		if s.UnmarshalTOML(b.value) != nil || kindRefused(section, key, s) {
			d.refuse("conf_value_type_refused", k, line, col)
			return judging
		}
		var ve *ValueError
		if err := Validate(section, key, s.Text); errors.As(err, &ve) {
			d.refuse(ve.Event, k, line, col)
		}
	}
	return judging
}

// judgeValues refuses each string in the deferred value b, written at
// path p, that valueCharEvent refuses, at the position of the innermost
// key holding it, line and col for b itself.
func (d *decoder) judgeValues(p []string, b *bound, line, col int) {
	if text, ok := b.value.(string); ok {
		if event := valueCharEvent(text); event != "" {
			d.refuse(event, p, line, col)
		}
		return
	}
	for _, c := range b.children {
		if c.keyless() {
			d.judgeValues(p, c, line, col)
			continue
		}
		ml, mc := c.declPos()
		d.judgeValues(append(append([]string{}, p...), c.node.Key), c, ml, mc)
	}
}

// parseRefusal is the conf_toml_parse_failed refusal for the parser's
// err: at the parser's line and column, naming the path of the last
// occurrence the locator found at or before that line.
func parseRefusal(lines *locate.Map, err error) Refusal {
	var line, col int
	var pe toml.ParseError
	if errors.As(err, &pe) {
		line, col = pe.Position.Line, pe.Position.Col
	}
	return attributed(lines, line, col)
}

// utf8Mark is the UTF-8 byte-order mark.
const utf8Mark = "\xef\xbb\xbf"

// undecodable reports the 1-based line and byte column of the first byte
// the bridge cannot read as TOML text, judged on src as read: a byte that
// is not UTF-8, or a leading UTF-8 byte-order mark, which the bridge
// decodes to U+FEFF and tomllib refuses at line 1 column 1. The parser
// strips a leading FF FE, FE FF or EF BB BF before it reads (BurntSushi
// v1.6.0 parse.go), so its success does not make the bytes text (base#1442
// review round 4).
func undecodable(src []byte) (line, col int, ok bool) {
	off := -1
	if bytes.HasPrefix(src, []byte(utf8Mark)) {
		off = 0
	} else {
		for i := 0; i < len(src); {
			r, n := utf8.DecodeRune(src[i:])
			if r == utf8.RuneError && n == 1 {
				off = i
				break
			}
			i += n
		}
	}
	if off < 0 {
		return 0, 0, false
	}
	head := src[:off]
	return bytes.Count(head, []byte("\n")) + 1, off - bytes.LastIndexByte(head, '\n'), true
}

// attributed is the conf_toml_parse_failed refusal at line and col, naming
// the path of the last occurrence the locator found at or before that
// line.
func attributed(lines *locate.Map, line, col int) Refusal {
	r := Refusal{Event: "conf_toml_parse_failed", Line: line, Col: col}
	for _, o := range lines.Entries() {
		if o.KeyLine > r.Line {
			break
		}
		r.Path = o.Path
	}
	return r
}

// accepted reports whether the table at p is one the shell accepts, judged
// on its section text, the dotted path the bridge names it by: a text
// _setup_known_section knows, or one starting with `stage:`, which
// _setup_conf_check_known skips. So `[logging.""]` is the text
// `logging.` and refused, while `["logging.web"]` and `[logging.web.x]`
// name a service.
func accepted(p []string) bool {
	text := strings.Join(p, ".")
	return strings.HasPrefix(text, "stage:") || knownSection(text)
}

// knownSection is _setup_known_section (dist/script/docker/lib/
// setup_cmd.sh): a SCHEMA_SECTIONS name, or `logging.` followed by at
// least one byte.
func knownSection(text string) bool {
	return known[text] || serviceText(text)
}

// arrayFamily maps an array's key to the numbered-family prefix its
// entries take in the shell view: the first element of toml_bridge.py's
// _ARRAY_SPEC, ported verbatim.
var arrayFamily = map[string]string{
	"rules":               "rule",
	"args":                "arg",
	"ports":               "port",
	"cap_add":             "cap_add",
	"cap_drop":            "cap_drop",
	"security_opt":        "security_opt",
	"volumes":             "mount",
	"tmpfs":               "tmpfs",
	"devices":             "device",
	"bindings":            "device",
	"cgroup_rules":        "cgroup_rule",
	"additional_contexts": "context",
}

// projectDeploy resolves the legacy alias in the [deploy] node of t as
// deploy.sh's _resolve_deploy_config does: GPURuntime is gpu_runtime when
// it is set to a non-empty value, and the legacy runtime's field
// otherwise. A non-empty legacy runtime, which deploy.sh reports as
// conf_runtime_key_deprecated, is returned as a Deprecation allocated for
// this call (base#1442).
func projectDeploy(t *Tree) (Deploy, []Deprecation) {
	var out Deploy
	if len(t.Nodes) == 0 {
		return out, nil
	}
	for _, c := range t.Nodes[0].Children {
		if c.Kind != ChildNode || c.Key != "deploy" {
			continue
		}
		for _, r := range t.Nodes[c.Node].Children {
			switch {
			case r.Kind != ChildRow:
			case r.Key == "gpu_runtime":
				out.GPURuntime = r.Row
			case r.Key == "runtime":
				out.Runtime = r.Row
			}
		}
	}
	if (out.GPURuntime.State != Set || out.GPURuntime.Value.Text == "") && out.Runtime.State == Set {
		out.GPURuntime = out.Runtime
	}
	if out.Runtime.State != Set || out.Runtime.Value.Text == "" {
		return out, nil
	}
	return out, []Deprecation{{
		Path:      []string{"deploy", "runtime"},
		Canonical: []string{"deploy", "gpu_runtime"},
		Line:      out.Runtime.Line,
	}}
}

// projectEnvironment is the [environment] node of t: Absent when there is
// none, Empty when it has no scalar row, Set with its rows otherwise
// (base#1309, base#1442).
func projectEnvironment(t *Tree) Environment {
	var out Environment
	if len(t.Nodes) == 0 {
		return out
	}
	for _, c := range t.Nodes[0].Children {
		if c.Kind != ChildNode || c.Key != "environment" {
			continue
		}
		out.Table.State = Empty
		for _, r := range t.Nodes[c.Node].Children {
			if r.Kind != ChildRow {
				continue
			}
			if out.Env == nil {
				out.Env = map[string]Field{}
			}
			out.Env[r.Key] = r.Row
			out.Table.State = Set
		}
	}
	return out
}

// serviceName is the logging service a section text names: the text
// after `logging.`, when the text is `logging.` plus at least one byte.
func serviceName(text string) (string, bool) {
	svc, ok := strings.CutPrefix(text, "logging.")
	return svc, ok && svc != ""
}

// serviceText reports whether a section text names a logging service.
func serviceText(text string) bool {
	_, ok := serviceName(text)
	return ok
}

// pathID is a collision-free string form of a TOML path, used as a map
// key and for path equality. It takes []string so a toml.Key is quoted
// element by element rather than through its String method.
func pathID(path []string) string {
	return fmt.Sprintf("%q", path)
}

// buildTree records the accepted table nodes of the layer in the bridge's
// traversal order (toml_bridge.py _emit_table, the loop at line 407): the
// parsed tree walked depth first, each node entered before its children,
// each table's children in the order they were first created, the
// locator's node order. The root, the known sections, every table whose
// text is under logging and every `["stage:<name>"]` table are accepted; a
// refused table and everything under it is left out, and so is a root
// scalar. Each accepted array is returned in the second result with its
// payload, and its bound node in the third (base#1442).
func buildTree(md toml.MetaData, root *bound) (Tree, []Deferred, []*bound) {
	t := Tree{Nodes: []Node{{}}}
	var deferred []Deferred
	var arrays []*bound
	var walk func(at int, path []string, b *bound)
	walk = func(at int, path []string, b *bound) {
		for _, c := range b.children {
			name := c.node.Key
			p := append(append([]string{}, path...), name)
			switch {
			case c.isTable():
				if !accepted(p) {
					continue
				}
				// Line and Implicit are the node's earliest record's: its
				// header, or its first creator's when it is created first.
				n := Node{Path: p, Text: strings.Join(p, "."), Inline: c.node.Kind == locate.NKey}
				if first := c.node.First(); first != nil {
					n.Line, n.Implicit = first.KeyLine, first.Implicit && !n.Inline
				}
				i := len(t.Nodes)
				t.Nodes = append(t.Nodes, n)
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildNode, Key: name, Node: i})
				walk(i, p, c)
			case c.isArray():
				// At the root only an array at a known section name,
				// `[[volumes]]` or `volumes = [...]`, is accepted; any
				// other root key is refused.
				if len(path) == 0 && !known[name] {
					continue
				}
				def := Deferred{Path: p, Type: md.Type(p...), Value: c.payload()}
				def.Line = def.Value.Line
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildDeferred, Key: name, Defer: len(deferred)})
				deferred = append(deferred, def)
				arrays = append(arrays, c)
			default:
				if len(path) == 0 {
					continue
				}
				var s Scalar
				// Scalar decodes every TOML scalar kind; a value it cannot
				// decode is refused by Decode, so leaving it out loses
				// nothing silently.
				if s.UnmarshalTOML(c.value) != nil {
					continue
				}
				line, _ := c.declPos()
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildRow, Key: name, Row: Field{State: Set, Value: s, Line: line}})
			}
		}
	}
	walk(0, nil, root)
	return t, deferred, arrays
}

// ProjectServices walks t depth first in Children order and appends each
// row of a node whose text is `logging.` plus at least one byte to the
// Rows of the service named by the rest of the text; each typed field is
// the last row with its key (the `_conf_get` rule). Decode builds
// Logging.Services with it, and a merged tree projects the same way
// (base#1442).
func ProjectServices(t *Tree) map[string]*Service {
	out := map[string]*Service{}
	if len(t.Nodes) == 0 {
		return out
	}
	var walk func(i int)
	walk = func(i int) {
		for _, c := range t.Nodes[i].Children {
			switch c.Kind {
			case ChildNode:
				walk(c.Node)
			case ChildRow:
				svc, ok := serviceName(t.Nodes[i].Text)
				if !ok {
					continue
				}
				if out[svc] == nil {
					out[svc] = &Service{}
				}
				out[svc].Rows = append(out[svc].Rows, Row{Key: c.Key, Field: c.Row})
				switch c.Key {
				case "driver":
					out[svc].Driver = c.Row
				case "max_file":
					out[svc].MaxFile = c.Row
				}
			case ChildDeferred:
				// An array is no service row.
			}
		}
	}
	walk(0)
	return out
}

// projectArrays types each deferred array as a family: every table
// element is one entry at its own position, a field-less one included
// (base#1443).
func projectArrays(deferred []Deferred) map[string]Family {
	out := map[string]Family{}
	for _, def := range deferred {
		fam := Family{State: Set, Line: def.Line}
		for _, item := range def.Value.Items {
			if item.Kind != VTable {
				continue
			}
			e := Entry{Index: len(fam.Entries) + 1, Line: item.Line}
			for _, m := range item.Members {
				e.Fields = append(e.Fields, EntryField{Key: m.Key, Value: m.Value})
			}
			fam.Entries = append(fam.Entries, e)
		}
		out[strings.Join(def.Path, ".")] = fam
	}
	return out
}
