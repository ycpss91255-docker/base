package main

import (
	"testing"
)

// checkFrames runs `config-gen check` on src through runCheck (empty
// stdout, wholly frames, each naming the layer's path) and holds it to
// status and to want, one {event, line, col, key} per frame, in order.
func checkFrames(t *testing.T, src string, status int, want [][]string) {
	t.Helper()
	path := writeLayer(t, src)

	got, fr := runCheck(t, path)

	if got != status || len(fr) != len(want) {
		t.Fatalf("check = %d, frames %q; want %d and %d frames %q", got, fr, status, len(want), want)
	}
	for i, w := range want {
		if fr[i][2] != w[0] || fr[i][4] != w[1] || fr[i][5] != w[2] || fr[i][6] != w[3] {
			t.Errorf("frame %d = %q, want event %s line %s col %s key %q", i, fr[i], w[0], w[1], w[2], w[3])
		}
	}
}

// An array under a known table whose key no numbered family carries is
// refused however it is written, as the bridge refuses every array whose
// key _ARRAY_SPEC has no family for (toml_bridge.py _array_spec):
// an array of tables `[[security.privileged]]` and an inline array alike.
// At a key _setup_known_key knows -- a registered scalar key or a
// free-form [build] key -- it is a value of the wrong type for that key,
// conf_value_type_refused; at any other key it is conf_unknown_key. A
// header-form array is refused at its first header, once (base#1442 review
// round 1 finding 1).
func TestCheckArrayWithNoFamily(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want [][]string
	}{
		{"array of tables at a bool key", "[[security.privileged]]\nvalue = true\n",
			[][]string{{"conf_value_type_refused", "1", "1", "security.privileged"}}},
		{"array of tables written twice, refused once", "[[security.privileged]]\nvalue = true\n[[security.privileged]]\nvalue = false\n",
			[][]string{{"conf_value_type_refused", "1", "1", "security.privileged"}}},
		{"array of tables at a service key", "[[logging.web.driver]]\nname = \"local\"\n",
			[][]string{{"conf_value_type_refused", "1", "1", "logging.web.driver"}}},
		{"array of tables at a free-form key", "[[build.tz]]\nx = \"a\"\n",
			[][]string{{"conf_value_type_refused", "1", "1", "build.tz"}}},
		{"inline array at a free-form key", "[build]\ntz = [\"a\"]\n",
			[][]string{{"conf_value_type_refused", "2", "1", "build.tz"}}},
		{"array of tables at an unknown key", "[[build.install]]\nx = 1\n",
			[][]string{{"conf_unknown_key", "1", "1", "build.install"}}},
		{"inline array at a bool key", "[security]\nprivileged = [true]\n",
			[][]string{{"conf_value_type_refused", "2", "1", "security.privileged"}}},
		{"inline array of tables at a bool key", "[security]\nprivileged = [{ value = true }]\n",
			[][]string{{"conf_value_type_refused", "2", "1", "security.privileged"}}},
		// A known section that no array family carries, written as a
		// root array: the bridge's --kv gives rc 1 "deploy is an array,
		// and no numbered family of the shell view carries an array by
		// that name" for both (base#1443 review round 1 finding 1).
		{"inline array at a known section with no family", "deploy = []\n",
			[][]string{{"conf_top_level_key", "1", "1", "deploy"}}},
		{"array of tables at a known section with no family", "[[deploy]]\nzz = 1\n",
			[][]string{{"conf_unknown_table", "1", "1", "deploy"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checkFrames(t, tc.src, 1, tc.want)
		})
	}
}

// A key written inside an inline value, an inline table or a table item
// of an inline array, is reported at its own line and column, not at the
// key holding the inline value: an inline value may span lines. When the
// same path is written in several items, the refusal names the item it is
// in (base#1442 review round 1 finding 2). The cap_drop item is a table
// carrying cap, so the entry rule (base#1443) does not refuse it.
func TestCheckInlineKeyPositions(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want [][]string
	}{
		{"bad key in a multiline inline array", "volumes = [\n  { source = \"/a\", target = \"/b\", \"bad\\tkey\" = \"x\" }\n]\n",
			[][]string{{"conf_key_char_refused", "2", "35", "volumes.bad\tkey"}}},
		{"bad key in the second item", "volumes = [\n  { source = \"/a\" },\n  { source = \"/b\", \"x\\ty\" = 1 }\n]\n",
			[][]string{{"conf_key_char_refused", "3", "20", "volumes.x\ty"}}},
		{"bad value under a key written in two items", "volumes = [\n  {source = \"/a\"},\n  {source = \"/b\\u0000\"}\n]\n",
			[][]string{{"conf_value_nul_refused", "3", "4", "volumes.source"}}},
		{"wrong type in an inline table", "security = { privileged = \"yes\" }\n",
			[][]string{{"conf_value_type_refused", "1", "14", "security.privileged"}}},
		{"wrong type after a multiline array in an inline table", "security = { cap_drop = [\n  { cap = \"ALL\" },\n], privileged = \"yes\" }\n",
			[][]string{{"conf_value_type_refused", "3", "4", "security.privileged"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checkFrames(t, tc.src, 1, tc.want)
		})
	}
}

// A dotted key written inside an inline value creates a table for each of
// its parent components, as a dotted `key = value` line does. A refused
// parent component is reported at the line and column of the dotted key
// that creates it, not at the key holding the inline value (base#1442
// review round 2 finding 1).
func TestCheckInlineDottedParentPositions(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want [][]string
	}{
		{"bad parent in a multiline inline array", "volumes = [\n  { \"bad\\tkey\".x = 1 }\n]\n",
			[][]string{{"conf_key_char_refused", "2", "5", "volumes.bad\tkey"}}},
		{"bad middle parent in a multiline inline array", "volumes = [\n  { source = \"/a\" },\n  { a.\"b\\tc\".d = 1 }\n]\n",
			[][]string{{"conf_key_char_refused", "3", "5", "volumes.a.b\tc"}}},
		{"bad parent in a multiline inline table", "security = {\n  \"bad\\tkey\".x = 1 }\n",
			[][]string{{"conf_key_char_refused", "2", "3", "security.bad\tkey"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			checkFrames(t, tc.src, 1, tc.want)
		})
	}
}

// A header after a deeper header names its table from the root
// (base#1442 redesign r3, H1): `[logging.web]` then `[logging]` is one
// logging table holding web and driver. The bridge's `--kv` accepts it,
// rc 0, `logging.web<TAB>driver<TAB>json-file` then
// `logging<TAB>driver<TAB>local`, so check is 0 with nothing on stdout or
// stderr; a misnested locator tree would reach bind's shape panic, 4.
func TestCheckHeaderAfterDeeperHeader(t *testing.T) {
	checkFrames(t, "[logging.web]\ndriver = \"json-file\"\n[logging]\ndriver = \"local\"\n", 0, nil)
}
