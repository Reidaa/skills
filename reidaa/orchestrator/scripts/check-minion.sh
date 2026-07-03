#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-minion.sh [--cd DIR] [--out-dir DIR] --name NAME

Checks a Codex minion launched by start-minion.sh.
USAGE
}

die() {
  printf 'check-minion.sh: %s\n' "$*" >&2
  exit 1
}

workdir="$PWD"
out_dir=""
name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd)
      [[ $# -ge 2 ]] || die "--cd requires a directory"
      workdir="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a directory"
      out_dir="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      name="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$name" ]] || die "--name is required"

if [[ -z "$out_dir" ]]; then
  out_dir="$workdir/.orchestrator/minions"
fi

pid_path="$out_dir/$name.pid"
status_path="$out_dir/$name.status"
result_path="$out_dir/$name.result.md"
log_path="$out_dir/$name.log"

[[ -f "$pid_path" ]] || die "missing pid file: $pid_path"
pid="$(cat "$pid_path")"

printf 'name: %s\n' "$name"
printf 'pid: %s\n' "$pid"
printf 'result: %s\n' "$result_path"
printf 'log: %s\n' "$log_path"

if [[ -f "$status_path" ]]; then
  rc="$(cat "$status_path")"
  printf 'state: complete\n'
  printf 'exit_code: %s\n' "$rc"
  if [[ -s "$result_path" ]]; then
    printf '\n--- result ---\n'
    cat "$result_path"
  elif [[ -s "$log_path" ]]; then
    printf '\n--- log tail ---\n'
    tail -n 80 "$log_path"
  fi
  exit "$rc"
fi

if kill -0 "$pid" 2>/dev/null; then
  printf 'state: running\n'
  exit 0
fi

printf 'state: unknown\n'
printf 'detail: process is not running and no status file exists\n'
if [[ -s "$log_path" ]]; then
  printf '\n--- log tail ---\n'
  tail -n 80 "$log_path"
fi
exit 1
