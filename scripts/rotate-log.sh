#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Rotate a daemon log file. If the log is non-empty, move it aside to a
# UTC-timestamped archive and prune to the most recent N archives. Called from
# the Makefile (dev/reinstall) while the launchd agent is stopped, so no
# process holds the file open and the move is safe. Interim hygiene until P27
# moves logging from NSLog to os_log and removes the plaintext file entirely.
# See docs/technical-debt.md P27.
#
# Usage: scripts/rotate-log.sh <logfile> [keep]
#   keep defaults to 5.

set -euo pipefail

die() {
  printf 'rotate-log: %s\n' "${1}" >&2
  exit 1
}

is_decimal() {
  case "${1}" in
  "" | *[!0-9]*) return 1 ;;
  *) return 0 ;;
  esac
}

# Delete all but the newest _keep archives. Archive names end in a UTC
# timestamp that sorts lexically in chronological order, so a reverse sort
# lists newest first. find (not ls) tolerates arbitrary path characters.
prune_archives() {
  local _log=${1}
  local _keep=${2}
  local _dir _base _path _n=0
  _dir=$(dirname -- "${_log}")
  _base=$(basename -- "${_log}")
  while IFS= read -r _path; do
    _n=$((_n + 1))
    if [[ ${_n} -gt ${_keep} ]]; then
      rm -f -- "${_path}"
    fi
  done < <(find "${_dir}" -maxdepth 1 -type f -name "${_base}.*" | sort --reverse)
}

rotate() {
  local _log=${1}
  local _keep=${2}
  [[ -s ${_log} ]] || return 0
  local _archive
  _archive=${_log}.$(date -u +%Y%m%dT%H%M%SZ)
  if [[ -e ${_archive} ]]; then
    die "archive already exists: ${_archive}"
  fi
  mv -- "${_log}" "${_archive}"
  prune_archives "${_log}" "${_keep}"
  printf 'rotate-log: archived %s -> %s\n' "${_log}" "${_archive}"
}

main() {
  [[ $# -ge 1 ]] || die "usage: $(basename "${0}") <logfile> [keep]"
  local _logfile=${1}
  local _keep=${2:-5}
  if ! is_decimal "${_keep}"; then
    die "keep must be a non-negative integer: ${_keep}"
  fi
  rotate "${_logfile}" "${_keep}"
}

main "$@"
