#!/usr/bin/env bats
#
# gomod_scan_spec.bats -- the go.mod reader of the pin registry (base#1463).
#
# why: config-gen's go.mod is a declaration site the pin registry cannot
# read. Before base#1463 no go.mod line is ever a declaration, so an
# unmarked or `// indirect` requirement passes the pin-coverage lint. The
# fix is a structural scanner in script/watch/lib.sh -- a bash port of Go's
# modfile lexer plus a verb state machine -- that emits one record per
# `require` entry and refuses, by name, every spelling it does not model.
#
#   _pin_go_mod_scan <file>        `lineno\tpath\tversion\tcomment` per entry;
#                                  a refusal is rc 1, EMPTY stdout and one
#                                  go_mod_unsupported_syntax (file= line=
#                                  reason=) or go_mod_indirect_requirement.
#   _pin_go_mod_version_ok <p> <v> 0 only for a version Go keeps byte-identical.
#   _pin_is_declaration <f> <l> [<n>]
#                                  for go.mod, DECL only on a line number the
#                                  scanner emitted; go.mod with no number is 2.
#
# The fixtures under test/fixtures/gomod/ carry Go's own verdict in their
# first line (`// class: supported|policy-refused|go-invalid [event reason]`),
# measured with `go mod edit -json` in the pinned golang image; the oracle
# step (script/test/config_gen_steps/20-gomod-oracle.sh) holds them to Go.
# This spec holds the SCANNER to the same headers, and pins each refusal by
# its reason so a guard that goes quiet fails here by name.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB=/source/script/watch/lib.sh
  FIX=/source/test/fixtures/gomod
  # lib.sh alone: it brings in the logger itself when _log_err is undefined.
  # shellcheck disable=SC1090
  source "${LIB}"
  export LOG_FORMAT=json
  W="${BATS_TEST_TMPDIR}/w"
  mkdir -p "${W}"
}

# _scan <fixture> -- the scanner over test/fixtures/gomod/<fixture>.mod.
_scan() {
  run --separate-stderr _pin_go_mod_scan "${FIX}/${1}.mod"
}

# _refused <fixture> <reason> <line> -- the scanner refuses <fixture> with
# go_mod_unsupported_syntax naming the file, <line> and <reason>.
_refused() {
  _scan "${1}"
  assert_refusal 1 go_mod_unsupported_syntax "file=${FIX}/${1}.mod" "line=${3}" "reason=${2}"
}

# _gomod <line>... -- a go.mod at ${W}/go.mod.
_gomod() {
  printf '%s\n' "$@" > "${W}/go.mod"
}

# ── records ─────────────────────────────────────────────────────────────────

# why: The first red. A block entry after a comment line is the form a real
# `go get` writes, and a line regex or a scanner that loses block state
# after a comment misses it. One record, numbered by the entry's own line.
@test "_pin_go_mod_scan: a tab-indented block entry after a comment is one record on its own line (base#1463)" {
  assert_spec_subject "${LIB}" "the pin registry (base#1463)"
  _scan block_tab
  assert_success
  assert_output "$(printf '5\tgolang.org/x/mod\tv0.21.0\t')"
  [[ -z "${stderr}" ]] || fail "a supported file logs nothing: ${stderr}"
}

# why: The line form is the other spelling `go mod edit -require` writes.
@test "_pin_go_mod_scan: the line form is one record with an empty comment column (base#1463)" {
  _scan line_form
  assert_success
  assert_output "$(printf '3\ta\tv1.0.0\t')"
}

# why: The comment column is where the marker grammar's `// tool-pin:` can
# ride on the entry itself; a scanner that drops it loses that.
@test "_pin_go_mod_scan: an end-of-line comment is carried in the fourth column (base#1463)" {
  _scan eol_comment
  assert_success
  run cut -f1-3 <<<"${output}"
  assert_output "$(printf '3\ta\tv1.0.0')"
  _scan eol_comment
  [[ "$(cut -f4 <<<"${output}")" == *"tool-pin: ignore -- x"* ]] \
    || fail "the comment column lost the comment: ${output}"
}

# why: Every supported fixture's records equal Go's, which the header
# measured and <name>.requires holds; this rules out a scanner that keeps
# quotes, drops a glued comment's entry, or rejects a hyphenated prerelease.
@test "_pin_go_mod_scan: every supported fixture yields exactly the requires Go reads (base#1463)" {
  assert_spec_subject_dir "${FIX}" "the go.mod oracle fixtures (base#1463)"
  local _m _n _bad="" _got _want _count=0
  for _m in "${FIX}"/*.mod; do
    head -n1 "${_m}" | grep -qx '// class: supported' || continue
    _n="${_m%.mod}"
    _count=$(( _count + 1 ))
    _got="$(_pin_go_mod_scan "${_m}" 2>/dev/null)" || { _bad+=" ${_m##*/}(rc)"; continue; }
    _got="$(cut -f2,3 <<<"${_got}")"
    _want="$(cat "${_n}.requires")"
    [[ "${_got}" == "${_want}" ]] || _bad+=" ${_m##*/}"
  done
  (( _count >= 10 )) || fail "only ${_count} supported fixtures were found"
  [[ -z "${_bad}" ]] || fail "records differ from Go's for:${_bad}"
}

# why: Every refused fixture is refused with the event and reason its header
# names, and with nothing on stdout. A scanner that streams records before
# a later refusal, or refuses for the wrong reason, fails here.
@test "_pin_go_mod_scan: every policy-refused and go-invalid fixture is refused with its header's event and reason (base#1463)" {
  local _m _h _ev _reason _bad="" _out _err _rc _count=0
  for _m in "${FIX}"/*.mod; do
    _h="$(head -n1 "${_m}")"
    [[ "${_h}" =~ ^//\ class:\ (policy-refused|go-invalid)\ ([a-z_]+)\ ([a-z_0-9]+)$ ]] || continue
    _ev="${BASH_REMATCH[2]}"
    _reason="${BASH_REMATCH[3]}"
    _count=$(( _count + 1 ))
    _rc=0
    _out="$(_pin_go_mod_scan "${_m}" 2>"${W}/err")" || _rc=$?
    _err="$(cat "${W}/err")"
    if [[ "${_rc}" -ne 1 || -n "${_out}" ]]; then
      _bad+=" ${_m##*/}(rc=${_rc},stdout=${#_out})"
    elif [[ "${_err}" != *"\"body\":\"${_ev}\""* || "${_err}" != *"\"reason\":\"${_reason}\""* ]]; then
      _bad+=" ${_m##*/}(log)"
    fi
  done
  (( _count >= 60 )) || fail "only ${_count} refused fixtures were found"
  [[ -z "${_bad}" ]] || fail "not refused as their header says:${_bad}"
}

# why: The scanner's go.mod reader is a closed set: no fixture may sit
# outside the three classes, or the two loops above would skip it.
@test "gomod fixtures: every fixture's first line is a class header (base#1463)" {
  local _m _bad=""
  for _m in "${FIX}"/*.mod; do
    head -n1 "${_m}" | grep -qE '^// class: (supported|policy-refused( [a-z_]+ [a-z_0-9]+)?|go-invalid( [a-z_]+ [a-z_0-9]+)?)$' \
      || _bad+=" ${_m##*/}"
  done
  [[ -z "${_bad}" ]] || fail "unclassified:${_bad}"
}

# ── the skipped directives: refused by name (the blocking review point) ─────

# why: Go rejects `exclude a` and the old design consumed exclude unread, so
# a valid require after it was emitted for a file Go refuses. exclude is now
# refused by name in any form: line and block, before and after a require.
@test "_pin_go_mod_scan: exclude is refused by name, line form before a require and block form after one (base#1463)" {
  _refused exclude_ok_pre exclude 3
  _refused exclude_block_post exclude 4
  _refused exclude_arity_pre exclude 3
  _refused exclude_arity_post exclude 4
}

# why: Same point for retract: its interval grammar is not ported, so every
# retract -- valid, unclosed or with a trailer -- is refused by name.
@test "_pin_go_mod_scan: retract is refused by name in the line, interval and block forms (base#1463)" {
  _refused retract_interval_pre retract 3
  _refused retract_block_post retract 4
  _refused retract_unclosed_post retract 4
  _refused retract_trailer_pre retract 3
}

# why: Same point for godebug: `godebug foo` and `godebug a=1,b=2` are Go
# errors the old scanner skipped.
@test "_pin_go_mod_scan: godebug is refused by name in the line and block forms (base#1463)" {
  _refused godebug_ok_post godebug 4
  _refused godebug_block_pre godebug 3
  _refused godebug_no_eq_pre godebug 3
  _refused godebug_comma_post godebug 4
}

# why: replace, tool and ignore are three separate arms, each its own guard.
@test "_pin_go_mod_scan: replace, tool and ignore are each refused by name (base#1463)" {
  _refused replace replace 4
  _refused tool tool 4
  _refused ignore ignore 4
}

# ── module, go, toolchain: Go's own f.add checks ────────────────────────────

# why: module takes exactly one argument; `module a b` is a Go error.
@test "_pin_go_mod_scan: module with two arguments is refused as module_arity (base#1463)" {
  _refused module_arity_pre module_arity 2
  _refused module_arity_post module_arity 3
}

# why: An unquoted module path cannot hold a quote character.
@test "_pin_go_mod_scan: module a'b is refused as module_quote (base#1463)" {
  _refused module_quote_pre module_quote 2
  _refused module_quote_post module_quote 3
}

# why: A second module line is a Go error wherever it sits.
@test "_pin_go_mod_scan: a repeated module line is refused as module_repeated (base#1463)" {
  _refused module_repeated_pre module_repeated 3
  _refused module_repeated_post module_repeated 4
}

# why: go takes exactly one argument.
@test "_pin_go_mod_scan: go with two arguments is refused as go_arity (base#1463)" {
  _refused go_arity_pre go_arity 3
  _refused go_arity_post go_arity 4
}

# why: go's argument must match Go's GoVersionRE.
@test "_pin_go_mod_scan: go abc is refused as go_version (base#1463)" {
  _refused go_bad_pre go_version 3
  _refused go_bad_post go_version 4
}

# why: `[a-z]` in a UTF-8 locale can match upper case; Go's regexp never
# does. 1.21RC1 must be refused whatever the caller's locale.
@test "_pin_go_mod_scan: go 1.21RC1 is refused as go_version under a UTF-8 locale (base#1463)" {
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 _refused go_locale_pre go_version 3
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 _refused go_locale_post go_version 4
}

# why: A second go line is a Go error wherever it sits.
@test "_pin_go_mod_scan: a repeated go line is refused as go_repeated (base#1463)" {
  _refused go_repeated_pre go_repeated 4
  _refused go_repeated_post go_repeated 5
}

# why: toolchain takes exactly one argument.
@test "_pin_go_mod_scan: toolchain with two arguments is refused as toolchain_arity (base#1463)" {
  _refused toolchain_arity_pre toolchain_arity 3
  _refused toolchain_arity_post toolchain_arity 4
}

# why: toolchain's argument must match Go's ToolchainRE.
@test "_pin_go_mod_scan: toolchain gox is refused as toolchain_version (base#1463)" {
  _refused toolchain_bad_pre toolchain_version 3
  _refused toolchain_bad_post toolchain_version 4
}

# why: A second toolchain line is a Go error wherever it sits.
@test "_pin_go_mod_scan: a repeated toolchain line is refused as toolchain_repeated (base#1463)" {
  _refused toolchain_repeated_pre toolchain_repeated 4
  _refused toolchain_repeated_post toolchain_repeated 5
}

# why: The checks above must not be tighter than Go: a release candidate go
# version, a gccgo toolchain suffix, a quoted module path and a file with no
# module line at all are all files Go reads, and the require is emitted.
@test "_pin_go_mod_scan: go 1.21rc1, toolchain go1.21.0-gccgo, module \"a b\" and no module line still emit the require (base#1463)" {
  _scan go_rc
  assert_success
  assert_output "$(printf '4\ta\tv1.0.0\t')"
  _scan toolchain_gccgo
  assert_success
  assert_output "$(printf '4\ta\tv1.0.0\t')"
  _scan module_quoted
  assert_success
  assert_output "$(printf '3\ta\tv1.0.0\t')"
  _scan no_module
  assert_success
  assert_output "$(printf '2\ta\tv1.0.0\t')"
}

# ── structure ───────────────────────────────────────────────────────────────

# why: Each of Go's lexer errors the scanner does not model is its own guard.
@test "_pin_go_mod_scan: a backquoted string is refused as backquote (base#1463)" {
  _refused backquote backquote 3
}

# why: Go refuses /* */ comments; the scanner must not read past one.
@test "_pin_go_mod_scan: a /* comment is refused as c_comment (base#1463)" {
  _refused c_comment c_comment 3
}

# why: A verb outside the closed set -- here a typo of require -- is refused.
@test "_pin_go_mod_scan: an unknown verb is refused as unknown_verb (base#1463)" {
  _refused unknown_verb unknown_verb 3
}

# why: [ { and , are tokens of their own in Go's lexer, never part of a word.
@test "_pin_go_mod_scan: [, { and , in a require are each refused as punctuation (base#1463)" {
  _refused punct_bracket punctuation 3
  _refused punct_brace punctuation 3
  _refused punct_comma punctuation 3
}

# why: A block that never closes emits nothing, not the entries read so far.
@test "_pin_go_mod_scan: an unterminated block is refused with no partial record (base#1463)" {
  _refused unterminated_block unterminated_block 4
}

# why: A string that never closes on its line is a Go error.
@test "_pin_go_mod_scan: an unterminated quote is refused as unterminated_quote (base#1463)" {
  _refused unterminated_quote unterminated_quote 3
}

# why: A require entry is exactly a path and a version.
@test "_pin_go_mod_scan: a require with one or three words is refused as arity (base#1463)" {
  _refused arity_1 arity 3
  _refused arity_3 arity 3
}

# why: module/go/toolchain are line-form only here (Go rejects go and
# toolchain blocks and accepts a module block the scanner does not model).
@test "_pin_go_mod_scan: a go, toolchain or module block is refused as block_form_verb (base#1463)" {
  _refused block_form_go block_form_verb 3
  _refused block_form_toolchain block_form_verb 3
  _refused block_form_module block_form_verb 2
}

# why: The byte check runs on the FILE, before bash holds a line: a bash
# variable cannot carry a NUL, so a check on the read-in copy never sees one
# and `require a v1.0.0<NUL>`, which Go rejects, was emitted (review round
# 1). Non-ASCII, a NUL in or after an entry, a control byte and a CR that
# does not end its line are each refused, so a byte bash and Go read
# differently can only refuse, never emit a record.
@test "_pin_go_mod_scan: a byte outside tab, printable ASCII and a line-ending CR is refused as unsupported_byte (base#1463)" {
  _refused non_ascii unsupported_byte 3
  _refused nul_post unsupported_byte 3
  _refused nul_comment unsupported_byte 3
  _refused control_byte unsupported_byte 3
  _refused cr_comment unsupported_byte 3
}

# why: A CR that ends its line is how a CRLF go.mod is written and Go reads
# it; the byte check must not turn that into a refusal.
@test "_pin_go_mod_scan: CRLF line endings are read (base#1463)" {
  _scan crlf
  assert_success
  assert_output "$(printf '3\ta\tv1.0.0\t')"
}

# why: A record is `lineno<TAB>path<TAB>version<TAB>comment`, so a tab inside
# a quoted path or a comment is a field separator to every reader of the
# record: `require "a<TAB>b" v1.0.0` read as path=a, version=b (review round
# 1). Whatever field carries it, line or block form, the entry is refused.
@test "_pin_go_mod_scan: a tab inside a path or a comment is refused as record_tab (base#1463)" {
  _refused tab_path record_tab 3
  _refused tab_path_block record_tab 4
  _refused tab_comment record_tab 3
}

# why: An empty quoted path left two adjacent tabs in the record, and a
# tab-split `read` collapses them, so the reader took the comment for the
# version: `require "" v1.0.0 // note` listed as current=`// note` (review
# round 2, base#1463). Go itself drops a requirement with an empty path,
# so no record agrees with Go; line and block form are refused by name.
@test "_pin_go_mod_scan: an empty quoted path is refused as path_empty (base#1463)" {
  _refused path_empty path_empty 3
  _refused path_empty_block path_empty 4
}

# why: A record is decoded by splitting on its tabs with every field kept,
# including an empty one, so no field can slide into its neighbour's
# column whatever the scanner emits (review round 2, base#1463).
@test "_pin_go_mod_record_fields: an empty field keeps its column (base#1463)" {
  local _gm_r_ln _gm_r_path _gm_r_ver _gm_r_cm
  _pin_go_mod_record_fields "$(printf '3\t\tv1.0.0\t// note')"
  assert_equal "${_gm_r_ln}" 3
  assert_equal "${_gm_r_path}" ""
  assert_equal "${_gm_r_ver}" v1.0.0
  assert_equal "${_gm_r_cm}" '// note'
  _pin_go_mod_record_fields "$(printf '5\ta\tv1.0.0\t')"
  assert_equal "${_gm_r_ln}" 5
  assert_equal "${_gm_r_path}" a
  assert_equal "${_gm_r_ver}" v1.0.0
  assert_equal "${_gm_r_cm}" ""
}

# why: `(` must end its line; `require ( a v1.0.0` is a Go error.
@test "_pin_go_mod_scan: text after an opening paren is refused as paren_trailer (base#1463)" {
  _refused paren_trailer paren_trailer 3
}

# why: `)` must stand alone on its line.
@test "_pin_go_mod_scan: a closing paren after an entry is refused as paren_not_alone (base#1463)" {
  _refused paren_not_alone paren_not_alone 4
}

# why: An indirect requirement is not this repo's declaration; it is refused
# by its own event in every spelling Go marks indirect.
@test "_pin_go_mod_scan: // indirect, //indirect and // indirect; ... are go_mod_indirect_requirement (base#1463)" {
  local _n
  for _n in indirect indirect_glued indirect_semicolon; do
    _scan "${_n}"
    assert_refusal 1 go_mod_indirect_requirement "file=${FIX}/${_n}.mod" "line=3"
  done
}

# why: An unreadable go.mod is not an empty one.
@test "_pin_go_mod_scan: an unreadable file is refused with pin_file_unreadable (base#1463)" {
  _gomod 'module example.com/m' 'require a v1.0.0'
  chmod 000 "${W}/go.mod"
  local _cmd="export LOG_FORMAT=json; source '${LIB}'; _pin_go_mod_scan '${W}/go.mod'"
  if (( EUID == 0 )); then
    su -s /bin/bash nobody -c true 2>/dev/null \
      || skip "running as root and cannot drop to nobody, so no unreadable file can be staged"
    chmod 755 "${BATS_TEST_TMPDIR}" "${W}"
    run --separate-stderr su -s /bin/bash nobody -c "${_cmd}"
  else
    run --separate-stderr bash -c "${_cmd}"
  fi
  assert_refusal 1 pin_file_unreadable "file=${W}/go.mod"
}

# why: The byte check reads the file a second way (od), and a read that
# fails there must refuse, not come back as "no bad byte" and let the file
# through unchecked. A stub od that fails stands in for that read.
@test "_pin_go_mod_scan: a byte read that fails is refused with pin_file_unreadable (base#1463)" {
  _gomod 'module example.com/m' 'require a v1.0.0'
  mkdir -p "${W}/bin"
  printf '#!/bin/sh\nexit 1\n' > "${W}/bin/od"
  chmod +x "${W}/bin/od"
  PATH="${W}/bin:${PATH}" run --separate-stderr _pin_go_mod_scan "${W}/go.mod"
  assert_refusal 1 pin_file_unreadable "file=${W}/go.mod"
}

# ── the version validator ───────────────────────────────────────────────────

# why: One witness per validator reason, through the scanner.
@test "_pin_go_mod_scan: a version Go rewrites or refuses is refused by its validator reason (base#1463)" {
  _refused short_v1 version_noncanonical 3
  _refused short_v1_2 version_noncanonical 3
  _refused build_meta version_build 3
  _refused incompat_v2 version_build 3
  _refused zero_major version_leading_zero 3
  _refused zero_minor version_leading_zero 3
  _refused no_v version_no_v 3
  _refused empty_pre version_prerelease_empty 3
  _refused empty_pre_ident version_prerelease_empty 3
  _refused pre_charset version_prerelease_charset 3
  _refused pre_zero version_prerelease_zero 3
  _refused gopkg_in gopkg_in_path 3
}

# why: The path-major rule has two arms (a /vN suffix and none) and an
# invalid-suffix arm; each is pinned separately. The huge major is compared
# as a string, so it cannot overflow into a pass.
@test "_pin_go_mod_scan: path major suffix, no suffix and invalid suffix each refuse by name (base#1463)" {
  _refused path_v2_v1 path_major_mismatch 3
  _refused path_v2_v3 path_major_mismatch 3
  _refused major_no_suffix path_major_mismatch 3
  _refused huge_major path_major_mismatch 3
  _refused path_v1 path_major_invalid 3
  _refused path_v0 path_major_invalid 3
  _refused path_v02 path_major_invalid 3
}

# why: The validator is callable on its own, and answers 0 only for a
# version Go keeps exactly as written.
@test "_pin_go_mod_version_ok: accepts canonical versions and refuses ones Go would rewrite (base#1463)" {
  run _pin_go_mod_version_ok a v1.0.0
  assert_success
  run _pin_go_mod_version_ok a/v2 v2.0.0-rc.1
  assert_success
  run _pin_go_mod_version_ok a v0.0.0-20240101000000-abcdefabcdef
  assert_success
  run _pin_go_mod_version_ok a v1.2
  assert_failure
  run _pin_go_mod_version_ok a v1.0.0+incompatible
  assert_failure
  run _pin_go_mod_version_ok a v18446744073709551616.0.0
  assert_failure
}

# ── _pin_is_declaration on go.mod ───────────────────────────────────────────

# why: For go.mod the scanner, not a line shape, decides: DECL only on a
# line number it emitted, so a comment, module or go line is never one.
@test "_pin_is_declaration: go.mod is DECL only on the line numbers the scanner emitted (base#1463)" {
  _gomod 'module example.com/m' '' 'go 1.27' '' 'require (' '	// c' '	golang.org/x/mod v0.21.0' ')'
  run _pin_is_declaration "${W}/go.mod" $'\tgolang.org/x/mod v0.21.0' 7
  assert_success
  run _pin_is_declaration "${W}/go.mod" $'\t// c' 6
  assert_failure 1
  run _pin_is_declaration "${W}/go.mod" 'go 1.27' 3
  assert_failure 1
  run _pin_is_declaration "${W}/go.mod" 'module example.com/m' 1
  assert_failure 1
}

# why: The bump rewrites only a line the scanner emitted; asked for the go
# directive it refuses rather than editing a line no pin can name, and on
# an entry it replaces the version token alone, not the same string in the
# comment (review round 2, base#1463).
@test "_pin_go_mod_set_line: refuses a line that is not a require entry and rewrites only the version token (base#1463)" {
  _gomod 'module example.com/m' 'go 1.27' 'require a v1.0.0 // v1.0.0 is held'
  run --separate-stderr _pin_go_mod_set_line "${W}/go.mod" 2 v1.1.0
  assert_failure 1
  assert_output ''
  run --separate-stderr _pin_go_mod_set_line "${W}/go.mod" 3 v1.1.0
  assert_success
  assert_output 'require a v1.1.0 // v1.0.0 is held'
}

# why: A go.mod line with no line number cannot be answered from the
# scanner; it is a caller error (2), not a "no".
@test "_pin_is_declaration: go.mod with no line number is rc 2 (base#1463)" {
  _gomod 'module example.com/m' 'require a v1.0.0'
  run _pin_is_declaration "${W}/go.mod" 'require a v1.0.0'
  assert_failure 2
}
