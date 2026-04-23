#!/usr/bin/env bash
# i18n.sh - Shared i18n helpers for Docker scripts
#
# Sourced by: build.sh, run.sh, exec.sh, stop.sh, setup.sh
#
# Provides:
#   _detect_lang     — detect language from $LANG env var
#                      output: "zh-TW" | "zh-CN" | "ja" | "en"
#   _sanitize_lang   — warn + fall back to "en" when an unsupported
#                      --lang value is given. Non-fatal; lets the user
#                      see the typo but keeps going in English.
#
# After sourcing, _LANG is set (caller can override via SETUP_LANG env var).

_detect_lang() {
  local _sys_lang="${LANG:-}"
  case "${_sys_lang}" in
    zh_TW*) echo "zh-TW" ;;
    zh_CN*|zh_SG*) echo "zh-CN" ;;
    ja*) echo "ja" ;;
    *) echo "en" ;;
  esac
}

# _sanitize_lang <outvar_name> [<script_name>]
#
# Reads the current value of the nameref, and if it's not in
# {en, zh-TW, zh-CN, ja} prints a WARNING to stderr and rewrites
# the nameref to "en". Callers invoke this right after parsing
# --lang so typos don't silently fall through to English at message
# lookup time (visible warning, safe default, non-fatal).
_sanitize_lang() {
  local -n _sl_ref="${1:?"${FUNCNAME[0]}: missing outvar name"}"
  local _who="${2:-tui}"
  case "${_sl_ref}" in
    en|zh-TW|zh-CN|ja) return 0 ;;
  esac
  printf "[%s] WARNING: unsupported --lang value %q, falling back to 'en'\n" \
    "${_who}" "${_sl_ref}" >&2
  printf "[%s]          allowed: en | zh-TW | zh-CN | ja\n" "${_who}" >&2
  _sl_ref="en"
}

_LANG="${SETUP_LANG:-$(_detect_lang)}"
