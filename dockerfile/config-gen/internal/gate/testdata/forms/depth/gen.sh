#!/usr/bin/env bash
#
# gen.sh -- write the depth boundary forms the live tomllib oracle answers
# (base#1441 design-ahead r3 §1e). Run once from anywhere; it writes next
# to itself and is committed with its output.
#
# Each file is one shape nested N levels deep around one terminal, at
# tomllib's largest accepted N (measured in the pinned toml-bridge image,
# design-ahead r3 §1e) and at N+1. Their verdicts are never committed: the
# oracle step answers them on every `just test go`, and its calibration
# runs the real `toml-bridge --tables` on every file here.
#
# Names: <shape>-<terminal slug>-<N>.toml. Shapes: arr `a = [[…]]`, it
# `a = {b = {b = …}}`, mix `a = [{b = …}]` pairs, arr-in-hdr `[t.u]` then
# `x.y.z = [[…]]`, arr-in-aot `[[t]]` then `x = [[…]]`, arr-ws `[ # c`
# plus a line ending per level, it-arr `a = {b = [[…]]}`, warm-arr
# `x = {}` then the arr shape, so an inline table was read before the
# deepest one (base#1441). The shapes whose terminal is fixed are named
# <shape>-<N>.toml (see _fixed).
#
# The backslash of the escaped terminal is written from its byte code
# (\134), never typed: the six characters of a \u escape typed through
# another layer were twice decoded to `A` before they reached a file
# (design-ahead r3 §1e). esc-u0041 is the bytes 22 5C 75 30 30 34 31 22;
# plainA (22 41 22) is its control.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly _DIR

# _rep <text> <n> -- print text n times.
_rep() {
  local i
  for (( i = 0; i < $2; i++ )); do printf '%s' "$1"; done
}

# _doc <shape> <n> <terminal> -- print the document.
_doc() {
  local s="$1" n="$2" t="$3"
  case "${s}" in
    arr) printf 'a = %s%s%s\n' "$(_rep '[' "${n}")" "${t}" "$(_rep ']' "${n}")" ;;
    it) printf 'a = %s%s%s\n' "$(_rep '{b = ' "${n}")" "${t}" "$(_rep '}' "${n}")" ;;
    mix) printf 'a = %s%s%s\n' "$(_rep '[{b = ' "${n}")" "${t}" "$(_rep '}]' "${n}")" ;;
    arr-in-hdr) printf '[t.u]\nx.y.z = %s%s%s\n' "$(_rep '[' "${n}")" "${t}" "$(_rep ']' "${n}")" ;;
    arr-in-aot) printf '[[t]]\nx = %s%s%s\n' "$(_rep '[' "${n}")" "${t}" "$(_rep ']' "${n}")" ;;
    arr-ws) printf 'a = %s%s%s\n' "$(_rep $'[ # c\n' "${n}")" "${t}" "$(_rep $'\n]' "${n}")" ;;
    it-arr) printf 'a = {b = %s%s%s}\n' "$(_rep '[' "${n}")" "${t}" "$(_rep ']' "${n}")" ;;
    warm-arr) printf 'x = {}\na = %s%s%s\n' "$(_rep '[' "${n}")" "${t}" "$(_rep ']' "${n}")" ;;
    arr-e) printf 'a = [%s{}%s]\n' "$(_rep '{b = ' "${n}")" "$(_rep '}' "${n}")" ;;
    it-c) printf 'a = {b = %s#c\n1%s}\n' "$(_rep '[' "${n}")" "$(_rep ']' "${n}")" ;;
    ait-c) printf 'a = [{b = %s#c\n1%s}]\n' "$(_rep '[' "${n}")" "$(_rep ']' "${n}")" ;;
  esac
}

# _pair <shape> <slug> <max> <terminal> -- the files at max and max+1.
_pair() {
  _doc "$1" "$3" "$4" > "${_DIR}/$1-$2-$3.toml"
  _doc "$1" "$(( $3 + 1 ))" "$4" > "${_DIR}/$1-$2-$(( $3 + 1 )).toml"
}

# _fixed <shape> <n>... -- <shape>-<n>.toml for each n, for a shape whose
# terminal is part of it: arr-e `a = [{b = {b = … {}}}]`, an array
# holding n nested inline tables around an empty one; it-c
# `a = {b = [[… #c` a line ending `1 …]]}`, a comment in the innermost of
# n arrays inside an inline table; ait-c the same n arrays inside
# `a = [{b = …}]`. it-c and ait-c put the innermost array at the frame
# parity where only its comment's skip_until passes the limit
# (base#1441).
_fixed() {
  local s="$1" n
  shift
  for n in "$@"; do
    _doc "${s}" "${n}" '' > "${_DIR}/${s}-${n}.toml"
  done
}

main() {
  local esc
  esc="\"$(printf '\134')u0041\""
  _pair arr int 496 '1'
  _pair it int 330 '1'
  _pair mix int 198 '1'
  _pair arr-in-hdr int 496 '1'
  _pair arr-in-aot int 496 '1'
  _pair arr-ws int 496 '1'
  _pair it-arr int 495 '1'
  # slug arr-max it-max terminal
  local -a rows=(
    "s 496 330 \"s\""
    "plainA 496 330 \"A\""
    "esc-u0041 494 329 ${esc}"
    "lit 496 330 's'"
    "ml-basic 496 330 \"\"\"s\"\"\""
    "ml-lit 496 330 '''s'''"
    "odt 496 330 1979-05-27T07:32:00Z"
    "ld 496 330 1979-05-27"
    "lt 496 330 07:32:00"
    "true 496 330 true"
    "float 496 330 1.5"
    "inf 496 330 inf"
    "hex 496 330 0x1F"
    "arr-empty 495 330 []"
    "it-empty 496 330 {}"
    "it-quoted-key 494 329 {\"q\" = 1}"
    "it-dotted-key 494 329 {x.y = 1}"
    "arr-pair 495 330 [1, 2]"
  )
  local row slug amax imax term
  for row in "${rows[@]}"; do
    read -r slug amax imax term <<<"${row}"
    _pair arr "${slug}" "${amax}" "${term}"
    _pair it "${slug}" "${imax}" "${term}"
  done
  _pair it-arr it-empty 494 '{}'
  _pair warm-arr it-empty 495 '{}'
  _pair warm-arr int 496 '1'
  _fixed arr-e 329 330 331
  _fixed it-c 494 495
  _fixed ait-c 493 494
}

main "$@"
