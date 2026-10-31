#!/usr/bin/env bats
#
# config_gen_mutation_lang_spec.bats -- the constructors of the config-gen
# mutation baseline language, script/test/config_gen_mutation_lang.sh
# (base#1465, slice S1e of base#1395).
#
# why: The producer (config_gen_mutation_targets.sh, S1d) writes every
# manifest and sha256 line through these constructors, and admission
# (config_gen_admit.sh) re-renders every line it reads through the same
# ones. A constructor that renders a value faithfully without validating it
# would let admission accept any header or record by re-rendering it, so
# each guard is pinned here beside the value next to it that passes.
#
# Each row sources the library in a fresh bash with no logger, as admission
# does inside the build: a refusal is rc 1, nothing on stdout and exactly
# one stderr line `cg_event config_gen_manifest_stale file=<f> reason=<r>`.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LANG_LIB="/source/script/test/config_gen_mutation_lang.sh"
  S="${BATS_TEST_TMPDIR}"
  H40="$(printf 'a%.0s' {1..40})"
  H64="$(printf 'b%.0s' {1..64})"
  P="dockerfile/config-gen"
}

# _lang <function> [args...] -- run one library function with no logger.
_lang() {
  assert_spec_subject "${LANG_LIB}" "the config-gen mutation baseline language (base#1465)"
  run --separate-stderr bash -c 'source "$1"; shift; "$@"' _ "${LANG_LIB}" "$@"
}

# _refused <file> <reason> -- the refusal shape.
_refused() {
  assert_equal "${status}" 1
  assert_equal "${output}" ""
  assert_equal "${stderr}" "cg_event config_gen_manifest_stale file=${1} reason=${2}"
}

# why: The header is the one line that binds the baseline to two commits
# and a context; a value S1d never writes (mixed hash lengths, an unknown
# dirty flag or context) must not round-trip. (base#1465)
@test "config_gen_mutation_lang: _cgm_header prints the S1d header for valid values and refuses each invalid one as header (base#1465)" {
  _lang _cgm_header "${H40}" "${H40}" no pr
  assert_success
  assert_equal "${output}" "base=${H40} head=${H40} dirty=no context=pr"
  assert_equal "${stderr}" ""
  _lang _cgm_header "${H64}" "${H64}" yes main-push
  assert_success
  assert_equal "${output}" "base=${H64} head=${H64} dirty=yes context=main-push"
  local -a bad
  local row
  for row in "${H40}|${H64}|no|pr" "${H64}|${H40}|no|pr" "${H40}|${H40}|maybe|pr" \
      "${H40}|${H40}|no|x" "${H40^^}|${H40}|no|pr" "${H40:1}|${H40:1}|no|pr" \
      "${H40}|${H40}|no|pr\r"; do
    IFS='|' read -r -a bad <<<"${row}"
    bad[3]="${bad[3]//\\r/$'\r'}"
    _lang _cgm_header "${bad[@]}"
    _refused manifest header
  done
  _lang _cgm_header "${H40}" "${H40}" no
  _refused manifest header
}

# why: git diff --name-status -M writes A, D, M, T, U with one path and
# R<score> with two; C never (observed, base#1465 redesign r2 §1), and a
# score past 100 or not three digits is no git score. (base#1465)
@test "config_gen_mutation_lang: _cgm_record accepts each git status with its arity and refuses any other status, score or arity as record (base#1465)" {
  local st
  for st in A D M T U; do
    _lang _cgm_record "${st}" "${P}/a.go"
    assert_success
    assert_equal "${output}" "${st}"$'\t'"${P}/a.go"
  done
  for st in R000 R058 R100; do
    _lang _cgm_record "${st}" "${P}/a.go" "${P}/b.go"
    assert_success
    assert_equal "${output}" "${st}"$'\t'"${P}/a.go"$'\t'"${P}/b.go"
  done
  for st in C100 R101 R999 R10 R1000 Rgarbage X '' a; do
    _lang _cgm_record "${st}" "${P}/a.go" "${P}/b.go"
    _refused manifest record
  done
  _lang _cgm_record M "${P}/a.go" "${P}/b.go"
  _refused manifest record
  _lang _cgm_record R100 "${P}/a.go"
  _refused manifest record
  _lang _cgm_record A
  _refused manifest record
}

# why: Every record path names a file of the module, in one canonical
# spelling; a path outside the prefix or one holding an empty, . or ..
# segment could name the same file twice or a file outside it. (base#1465)
@test "config_gen_mutation_lang: _cgm_record refuses a path outside the module or not canonical as path (base#1465)" {
  local p
  for p in "${P}x/a.go" "${P}/" "dockerfile/a.go" "${P}/../a.go" "${P}/./a.go" \
      "${P}//a.go" "${P}/a/" "/${P}/a.go" "${P}/a/.." ""; do
    _lang _cgm_record A "${p}"
    _refused manifest path
    _lang _cgm_record R100 "${P}/ok.go" "${p}"
    _refused manifest path
  done
  _lang _cgm_record A "${P}/..a/b..go"
  assert_success
}

# why: The quoted spelling is the producer's; admission reads a spelling
# back with _cgm_unquote and must get the name on disk for every byte but
# / and NUL. (base#1465)
@test "config_gen_mutation_lang: _cgm_unquote inverts _cgm_quote for one name holding every byte 0x01-0xff but / (base#1465)" {
  local name='' i
  for (( i = 1; i < 256; i++ )); do
    (( i == 0x2f )) && continue
    name+="$(printf "\\x$(printf '%02x' "${i}")")"
  done
  # \x0a is dropped by the command substitution above; add it back.
  name+=$'\n'
  run bash -c 'source "$1"; q="$(_cgm_quote "$2")"; _cgm_unquote "$q" || exit 3; [[ "$_cgm_raw" == "$2" ]] || exit 4; printf %s "$q"' \
    _ "${LANG_LIB}" "${name}"
  assert_success
  [[ "${output}" == '"'*'\n"' ]] || fail "the name was not C-quoted ending in \\n: ${output}"
  _lang _cgm_quote "${P}/café a.go"
  assert_equal "${output}" "${P}/café a.go"
  _lang _cgm_quote "${P}/a\"b"
  assert_equal "${output}" "\"${P}/a\\\"b\""
  local s
  for s in '"abc' '"a\qb"' '"a\000b"' '"a\8"' '"'; do
    run bash -c 'source "$1"; _cgm_unquote "$2"' _ "${LANG_LIB}" "${s}"
    assert_failure
  done
}

# why: A sha256 line binds a spelling to the bytes of a regular file; a
# path [[ -f ]] refuses (a dangling symlink, a fifo) has no bytes to bind.
# (base#1465)
@test "config_gen_mutation_lang: _cgm_hash_line prints spelling TAB sha256 for a regular file and rc 1 for anything else (base#1465)" {
  printf 'x\n' > "${S}/f"
  ln -s f "${S}/l"
  ln -s nowhere "${S}/d"
  mkfifo "${S}/p"
  _lang _cgm_hash_line "${P}/a b.go" "${S}/f"
  assert_success
  assert_equal "${output}" "${P}/a b.go"$'\t'"$(sha256sum < "${S}/f" | cut -d' ' -f1)"
  _lang _cgm_hash_line "${P}/l.go" "${S}/l"
  assert_success
  assert_equal "${output}" "${P}/l.go"$'\t'"$(sha256sum < "${S}/f" | cut -d' ' -f1)"
  local x
  for x in d p; do
    _lang _cgm_hash_line "${P}/x.go" "${S}/${x}"
    assert_equal "${status}" 1
    assert_equal "${output}" ""
  done
}

# why: A refusal value is one word whatever the name holds: each byte
# outside ! to ~, and the % itself, is %XX. (base#1465)
@test "config_gen_mutation_lang: _cgm_stale writes file= as one word, %XX outside ! to ~ and for % (base#1465)" {
  _lang _cgm_stale "${P}/a b%"$'\n'"é.go" sha_mismatch
  _refused "${P}/a%20b%25%0A%C3%A9.go" sha_mismatch
}
