#!/usr/bin/env bash
#
# toml_fixture_lint.sh - every fixture body a spec writes to a `*.toml`
# path has to parse as TOML.
#
# A fixture named `setup.toml` that holds INI (`mode = bridge`, bare
# `[section]` headers, `mount_1 = ...` numbered keys) is refused by the
# bridge, and until the bridge's exit status stopped being swallowed the
# refusal left an empty config handle whose every value fell back to the
# default the test happened to assert. Such a test is green for a reason
# that has nothing to do with what its name claims -- measured on this
# tree: a `[logging]` fixture spelled as INI and a file configuring no
# logging at all produce the SAME empty read, so the test asserting the
# second was never able to disagree with the first. This gate reads the
# fixture bodies out of the spec files STATICALLY and hands each one to
# the same parser the shipped readers use, so the next INI body written
# to a `.toml` path is caught at the gate rather than by the next person
# who trips on it.
#
# What counts as a fixture body (the forms the spec tree uses):
#   - a heredoc redirected into a `.toml` path:
#       cat > "${DIR}/setup.toml" <<'EOF' ... EOF
#     with any delimiter, quoted or not, `<<` or `<<-` (leading tabs
#     stripped), `>` or `>>`;
#   - a heredoc redirected into a VARIABLE holding a `.toml` path:
#       local _repo="${BATS_TEST_TMPDIR}/setup.toml"
#       cat > "${_repo}" <<'EOF' ... EOF
#     The name has to be assigned a literal `*.toml` path and never
#     anything else, judged inside the `@test` block that assigns it and
#     at file scope only for a name the block does not assign. One spec
#     spells `toml_file` as a `.toml` literal in one test and
#     `$(mktemp)` in another, so a file-wide verdict would read the
#     second test's unrelated heredoc as a fixture;
#   - a heredoc fed to a spec-local helper whose body is a bare
#     `cat > "...toml"` (`_stage_logging_conf <<'CONF'`);
#   - a `printf` / `echo` command redirected into either of those two
#     target forms, on one logical line (backslash continuations are
#     joined first). The command is evaluated in an empty environment
#     with the redirect removed, so
#     `printf '%s\n' "[gui]" "mode = off" > x.toml` yields the two lines
#     the spec would write.
#
# WHAT IT DELIBERATELY DOES NOT SEE, so the bound is read rather than
# discovered: a fixture written from inside a shell STRING -- a spec that
# passes `printf "..." > "${3}/setup.toml"` as a quoted argument to a
# helper which then evals it, the shape `unit/init_spec.bats` uses three
# times. Reading those would mean parsing the spec's own quoting and then
# the string's, and the string's content is not a redirect of the spec at
# all. The gate covers the forms a fixture is actually written in; the
# eval'd-string form is a gap, named here rather than left to be found.
#
# EVERY heredoc is tracked, not only the ones that open a fixture,
# because a heredoc body is text rather than code: a spec that writes a
# SCRIPT with a heredoc, and that script writes a `setup.toml`, must not
# have the inner line read as a fixture of the spec. Tracking only the
# interesting heredocs would scan those bodies as code and report a
# fixture at a line that writes nothing.
#
# An unquoted heredoc expands `${VAR}` at test time; the body is checked
# with every `${...}` / `$NAME` reference replaced by a placeholder word,
# so `name = "${_name}"` parses and `name = ${_name}` is refused for the
# same reason the real file would be.
#
# A body appended with `>>` is checked on its own: a fragment that
# parses alone is one that can be appended to a parsing file without
# breaking it.
#
# DELIBERATELY INVALID FIXTURES, which a spec needs when the behaviour
# under test IS the refusal of a malformed file, carry a marker in the
# comment block directly above them:
#
#   # toml-fixture-lint: allow the bridge's refusal is the assertion
#   cat > "${_f}" <<'EOF'
#
# The reason is mandatory. A marker with nothing after it is itself a
# failure, because an unexplained opt-out is the hole this gate exists to
# close, and an opt-out nobody has to justify is the shape every such
# hole starts as.
#
# Usage:
#   ./script/test/toml_fixture_lint.sh            # scan REPO_ROOT/test/bats
#   ./script/test/toml_fixture_lint.sh <root>     # scan <root>/test/bats
#
# Sourced: `_toml_fixture_lint <root>` is the entry point.
#
# Exit status: 0 = every fixture parses; 1 = at least one does not (each
# is named `file:line: <parser message>` on stderr), or no fixture could
# be found under <root> at all (a gate over nothing would be green for
# the wrong reason).
#
# Parser: `toml-bridge` when it is on PATH (the test-tools image), else
# `python3` with `tomllib` (3.11+); neither present is a refusal, not a
# pass.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_TOML_FIXTURE_LINT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# _toml_fixture_err <message> -- diagnostic to stderr. Block-redirected
# because this is a standalone, log.sh-free CI tool and the bare-stderr
# lint scans script/test/.
_toml_fixture_err() {
  {
    printf 'toml_fixture_lint: %s\n' "$1"
  } >&2
}

# _toml_fixture_parse < body -- parse stdin as TOML; the parser's own
# message on stderr and a non-zero status when it does not parse.
_toml_fixture_parse() {
  if command -v toml-bridge >/dev/null 2>&1; then
    toml-bridge >/dev/null
    return
  fi
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 -c 'import sys, tomllib
try:
    tomllib.loads(sys.stdin.read())
except Exception as exc:
    print("toml: %s" % exc, file=sys.stderr)
    raise SystemExit(1)'
    return
  fi
  _toml_fixture_err "no TOML parser: neither toml-bridge nor python3 with tomllib is on PATH"
  return 2
}

# The extractor. Two passes over one spec; see _toml_fixture_extract for
# the record stream it prints. Held as a string constant, the idiom
# drivers/issueref.sh uses, so the program is one artifact rather than a
# quoting puzzle inside a function body. `\47` is a single quote.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _TOML_FIXTURE_AWK='
  # The redirect target of a logical line: the text after its LAST `>`,
  # unquoted and trimmed. Empty when the line redirects nowhere.
  function redirect_target(head,   i, p, t) {
    p = 0
    for (i = 1; i <= length(head); i++) if (substr(head, i, 1) == ">") p = i
    if (p == 0) return ""
    t = substr(head, p + 1)
    gsub(/^[ \t]+/, "", t); gsub(/[ \t]+$/, "", t)
    gsub(/"/, "", t); gsub(/\47/, "", t)
    return t
  }

  # The variable name a target names, or "" when the target is not a
  # single `${NAME}` / `$NAME` reference.
  function target_var(t,   v) {
    if (substr(t, 1, 2) == "${") {
      v = substr(t, 3)
      if (substr(v, length(v), 1) == "}") v = substr(v, 1, length(v) - 1)
    } else if (substr(t, 1, 1) == "$") {
      v = substr(t, 2)
    } else return ""
    if (v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) return v
    return ""
  }

  # Split a logical line into shell words, honouring single and double
  # quotes and dropping the outer pair. Fills out[1..n] and returns n.
  # Enough for a call site of a fixture-writing helper, which is a plain
  # command line: no substitutions to perform, no operators to respect.
  function split_words(line, out,   i, c, n, cur, q, started) {
    n = 0; cur = ""; q = ""; started = 0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q != "") {
        if (c == q) { q = "" } else { cur = cur c }
        continue
      }
      if (c == "\47" || c == "\"") { q = c; started = 1; continue }
      if (c == " " || c == "\t") {
        if (started) { out[++n] = cur; cur = ""; started = 0 }
        continue
      }
      cur = cur c; started = 1
    }
    if (started) out[++n] = cur
    return n
  }

  # Record one `name=value` assignment into a toml / other pair of maps.
  # A name counts as holding a `*.toml` path only when EVERY assignment
  # to it in scope ends in `.toml`; one assignment of another shape
  # (`$(mktemp)`, "", a path of another kind) disqualifies the name. The
  # safe direction is to miss a fixture, not to read an unrelated
  # heredoc as one.
  function note_assign(raw, tm, ot,   aline, eq, aname, aval) {
    aline = raw
    gsub(/^[ \t]+/, "", aline)
    if (aline ~ /^local[ \t]+/) sub(/^local[ \t]+/, "", aline)
    else if (aline ~ /^declare[ \t]+/) {
      sub(/^declare[ \t]+/, "", aline); sub(/^-[A-Za-z]+[ \t]+/, "", aline)
    }
    if (aline !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return
    eq = index(aline, "=")
    aname = substr(aline, 1, eq - 1)
    aval = substr(aline, eq + 1)
    gsub(/[ \t]+$/, "", aval); gsub(/"/, "", aval); gsub(/\47/, "", aval)
    # A trailing run of `)` is stripped so `$(mktemp --suffix=.toml)`
    # counts as the `.toml` path it mints, while `$(mktemp)` does not.
    sub(/\)+$/, "", aval)
    if (aval ~ /\.toml$/) tm[aname] = 1
    else ot[aname] = 1
  }

  # Is <v> a name proven to hold a `*.toml` path here? A name assigned
  # inside the current @test block is judged by THAT block alone --
  # `toml_file` is a `.toml` literal in one test and `$(mktemp)` in
  # another, and the two must not borrow each other\47s verdict. A name
  # the block never assigns falls back to the file scope (setup(), the
  # top level).
  function var_is_toml(v) {
    if ((v in ltoml) || (v in lother)) return ((v in ltoml) && !(v in lother))
    return ((v in gtoml) && !(v in gother))
  }

  # Does this logical line write a `*.toml` path? A literal path, a
  # variable proven to hold one, or a bare call to a helper whose body
  # is a `cat > "...toml"`.
  function is_toml_target(head,   t, v) {
    t = redirect_target(head)
    if (t == "") {
      v = head
      gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
      return (v in helpers)
    }
    if (t ~ /\.toml$/) return 1
    v = target_var(t)
    if (v == "") return 0
    return var_is_toml(v)
  }

  # ── Pass 1: what the spec declares at file scope ────────────────────
  FNR == NR {
    # Helper functions whose body holds a bare `cat > "...toml"`: a
    # heredoc fed to one of them writes a fixture.
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
      fn = $0; sub(/\(\).*/, "", fn); next
    }
    if ($0 ~ /^\}/) { fn = ""; in_test = 0; next }
    if (fn != "" && $0 ~ /^[ \t]*cat[ \t]*>>?[ \t]*"?[^"[:space:]]*\.toml"?[ \t]*$/) {
      helpers[fn] = 1
    }
    # Helper functions that write a `.toml` path from their POSITIONAL
    # ARGUMENTS (`printf "%s\n" "$@" > "${_dir}/setup.toml"`). The body
    # then lives at the CALL SITES, one argument per line, and the
    # leading arguments the helper consumes are counted from its own
    # `shift`s so the right ones are dropped.
    if (fn != "") {
      # `shift` is counted wherever it stands as a statement, including
      # after a `;` on the declaration line, which is where every such
      # helper in this tree puts it.
      if (match($0, /(^|;)[ \t]*shift([ \t]+[0-9]+)?[ \t]*(;|$)/)) {
        sline = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", sline)
        argskip[fn] += (sline == "" ? 1 : sline + 0)
      }
      if ($0 ~ /"\$@"/ && $0 ~ />>?[ \t]*"?[^"[:space:]]*\.toml"?[ \t]*$/) {
        argwriters[fn] = 1
      }
    }
    if ($0 ~ /^@test[ \t]/) { in_test = 1; next }
    if (!in_test) note_assign($0, gtoml, gother)
    next
  }

  # ── Pass 2: emit ────────────────────────────────────────────────────
  {
    line = $0; lineno = FNR
    # Inside a heredoc every line is TEXT. Only a body this gate asked
    # for is printed; the rest is consumed so its lines are never read
    # as code.
    if (in_doc) {
      probe = line
      if (strip_tabs) sub(/^\t+/, "", probe)
      if (probe == delim) {
        in_doc = 0
        if (emit) { print "@@END"; emit = 0 }
        next
      }
      if (emit) print probe
      next
    }
    # A new @test body is a new scope for path variables.
    if (line ~ /^@test[ \t]/) {
      split("", ltoml); split("", lother); marker = 0; next
    }
    # A comment can carry the opt-out marker; it is never a fixture
    # opener. A blank line keeps a pending marker, anything else that is
    # not an opener drops it, so a marker reaches the fixture directly
    # below it and no further.
    if (line ~ /^[ \t]*#/) {
      if (line ~ /toml-fixture-lint:[ \t]*allow/) {
        reason = line
        sub(/^.*toml-fixture-lint:[ \t]*allow/, "", reason)
        gsub(/^[ \t:]+/, "", reason); gsub(/[ \t]+$/, "", reason)
        if (reason == "") print "@@BADMARKER " lineno
        marker = 1; marker_at = lineno
      }
      next
    }
    if (line ~ /^[ \t]*$/) next
    # Join backslash continuations into one logical line, keeping the
    # number of its first physical line.
    if (joined == "") { start = lineno }
    if (line ~ /\\$/) { sub(/\\$/, "", line); joined = joined line; next }
    line = joined line; joined = ""
    note_assign(line, ltoml, lother)

    # A heredoc opener: `<<` / `<<-`, an optionally quoted word
    # delimiter, end of line. An arithmetic `1 << 2` cannot match -- the
    # delimiter has to start with a letter or underscore.
    if (match(line, /<<-?[ \t]*[\47"]?[A-Za-z_][A-Za-z0-9_]*[\47"]?[ \t]*$/)) {
      head = substr(line, 1, RSTART - 1)
      op = substr(line, RSTART)
      strip_tabs = (op ~ /^<<-/)
      quoted = (op ~ /^<<-?[ \t]*[\47"]/)
      delim = op
      sub(/^<<-?[ \t]*/, "", delim); gsub(/[\47"[:space:]]/, "", delim)
      in_doc = 1; emit = 0
      if (is_toml_target(head)) {
        emit = 1
        print "@@FIXTURE " start " " (quoted ? "literal" : "expand") \
              " " (marker ? "allow" : "check")
      }
      marker = 0
      next
    }

    # A call to a helper that writes a `.toml` path from its positional
    # arguments. Each remaining argument is one body line. Read as the
    # expanding form: a double-quoted argument IS expanded at test time,
    # and treating a single-quoted one the same way can only let a body
    # through, never report one that is fine.
    callee = line
    gsub(/^[ \t]+/, "", callee); sub(/[ \t].*/, "", callee)
    if (callee in argwriters) {
      wn = split_words(line, words)
      print "@@FIXTURE " start " expand " (marker ? "allow" : "check")
      for (wi = 2 + argskip[callee]; wi <= wn; wi++) print words[wi]
      print "@@END"
      marker = 0
      next
    }

    # A printf / echo redirected into a `.toml` target. Evaluated rather
    # than parsed, so a command that could run anything is refused
    # instead: this gate reads spec text, it does not take instructions
    # from it.
    if (line ~ /^[ \t]*(printf|echo)[ \t]/ && is_toml_target(line)) {
      cmd = line
      sub(/>>?[ \t]*[^>]*$/, "", cmd)
      if (cmd ~ /\$\(/ || index(cmd, "`") > 0) {
        print "@@FIXTURE " start " unsafe " (marker ? "allow" : "check")
      } else {
        print "@@FIXTURE " start " eval " (marker ? "allow" : "check")
      }
      print cmd
      print "@@END"
      marker = 0
      next
    }
    marker = 0
  }
'

# _toml_fixture_extract <spec> -- print every fixture body of <spec> as a
# record stream:
#
#   @@FIXTURE <line> <literal|expand|eval|unsafe> <check|allow>
#   <body or command text, one or more lines>
#   @@END
#   @@BADMARKER <line>
#
# `literal` is a quoted-delimiter heredoc, `expand` an unquoted one (the
# caller substitutes variable references), `eval` a printf / echo command
# whose stdout is the body, `unsafe` one this gate will not run.
_toml_fixture_extract() {
  local _spec="${1:?"${FUNCNAME[0]}: missing spec file"}"
  awk "${_TOML_FIXTURE_AWK}" "${_spec}" "${_spec}"
}

# _toml_fixture_body <form> <text_file> -- print the body a record stands
# for: literal text, text with variable references replaced, or the
# stdout of the command evaluated in an empty environment.
_toml_fixture_body() {
  local _form="${1:?}" _text="${2:?}"
  case "${_form}" in
    literal) cat "${_text}" ;;
    expand)
      sed -E 's/\$\{[^}]*\}/x/g; s/\$[A-Za-z_][A-Za-z0-9_]*/x/g' "${_text}"
      ;;
    eval)
      env -i bash --norc --noprofile -c "$(cat "${_text}")" 2>/dev/null || true
      ;;
  esac
}

# _toml_fixture_verdict <form> <text_file> -- print nothing and return 0
# when the fixture is fine, print the diagnostic and return 1 otherwise.
_toml_fixture_verdict() {
  local _form="${1:?}" _text="${2:?}" _msg
  if [[ "${_form}" == unsafe ]]; then
    printf 'a printf / echo fixture whose command substitutes a command cannot be read statically; write it as a heredoc instead\n'
    return 1
  fi
  _msg="$(_toml_fixture_body "${_form}" "${_text}" | _toml_fixture_parse 2>&1)" \
    && return 0
  printf '%s\n' "${_msg:-does not parse}"
  return 1
}

# _toml_fixture_check <spec> <failures_file> <tally_file> -- append one
# `file:line: message` per failure to <failures_file>, and one line per
# fixture seen (`check` or `allow`) to <tally_file>.
_toml_fixture_check() {
  local _spec="${1:?}" _fail="${2:?}" _tally="${3:?}"
  local _tmp _rec _line="" _form="" _mode="" _msg
  _tmp="$(mktemp)"
  while IFS= read -r _rec; do
    if [[ "${_rec}" == "@@BADMARKER "* ]]; then
      printf '%s:%s: a toml-fixture-lint allow marker carries no reason; say why the body is deliberately not TOML\n' \
        "${_spec}" "${_rec#@@BADMARKER }" >> "${_fail}"
      continue
    fi
    if [[ "${_rec}" == "@@FIXTURE "* ]]; then
      read -r _line _form _mode <<< "${_rec#@@FIXTURE }"
      : > "${_tmp}"
      continue
    fi
    if [[ "${_rec}" != "@@END" ]]; then
      printf '%s\n' "${_rec}" >> "${_tmp}"
      continue
    fi
    printf '%s\n' "${_mode}" >> "${_tally}"
    [[ "${_mode}" == allow ]] && continue
    if ! _msg="$(_toml_fixture_verdict "${_form}" "${_tmp}")"; then
      printf '%s:%s: %s\n' "${_spec}" "${_line}" "${_msg}" >> "${_fail}"
    fi
  done < <(_toml_fixture_extract "${_spec}")
  rm -f "${_tmp}"
}

# _toml_fixture_lint [root] -- the entry point. Scans every *.bats under
# <root>/test/bats. 0 when every fixture parses; 1 otherwise, or when no
# fixture was found at all.
_toml_fixture_lint() {
  local _root="${1:-$(cd -- "${_TOML_FIXTURE_LINT_DIR}/../.." && pwd -P)}"
  _root="$(cd -- "${_root}" 2>/dev/null && pwd -P)" || {
    _toml_fixture_err "scan root '${1:-}' is not a directory"
    return 1
  }
  if [[ ! -d "${_root}/test/bats" ]]; then
    _toml_fixture_err "no test/bats/ under '${_root}'; nothing to gate"
    return 1
  fi
  if ! : | _toml_fixture_parse; then
    return 1
  fi

  local _work _fail _tally _spec _seen _allowed _bad
  _work="$(mktemp -d)"
  _fail="${_work}/failures"; _tally="${_work}/tally"
  : > "${_fail}"; : > "${_tally}"
  while IFS= read -r _spec; do
    _toml_fixture_check "${_spec}" "${_fail}" "${_tally}"
  done < <(find "${_root}/test/bats" -type f -name '*.bats' | sort)

  # `grep -c` exits 1 on a count of zero, which under this file's own
  # `set -e` would end the run with no diagnostic at all -- and zero is
  # exactly the count the clean case produces. Every tally is taken with
  # the status discarded for that reason.
  _seen="$(grep -c '' < "${_tally}" || true)"
  _allowed="$(grep -c '^allow$' < "${_tally}" || true)"
  _bad="$(grep -c '' < "${_fail}" || true)"
  if (( _bad > 0 )); then
    { sort "${_fail}"; } >&2
  fi
  rm -rf "${_work}"

  if (( _seen == 0 )); then
    _toml_fixture_err "no fixture written to a .toml path found under '${_root}/test/bats'; refusing to pass a gate over nothing"
    return 1
  fi
  if (( _bad > 0 )); then
    _toml_fixture_err "${_bad} of ${_seen} fixture bodies written to a .toml path do not parse as TOML"
    return 1
  fi
  printf 'toml_fixture_lint: %s fixture bodies written to a .toml path all parse as TOML (%s deliberately exempt)\n' \
    "${_seen}" "${_allowed}"
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _toml_fixture_lint "$@"
fi
