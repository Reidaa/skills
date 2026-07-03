#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start-minion.sh [--cd DIR] [--out-dir DIR] [--name NAME] [--prompt-file FILE] [--dry-run] [--] TASK...

Starts a Codex minion in the background with model gpt-5.5 and reasoning effort high.

Options:
  --cd DIR            Working directory for the Codex minion. Defaults to $PWD.
  --out-dir DIR       Directory for prompt/log/result/pid/status files.
                      Defaults to DIR/.orchestrator/minions.
  --name NAME         Stable minion name used for output filenames.
  --prompt-file FILE  Read the delegated task from FILE instead of TASK arguments.
  --dry-run           Write the generated prompt and print the Codex command, but do not start it.
  -h, --help          Show this help.
USAGE
}

die() {
  printf 'start-minion.sh: %s\n' "$*" >&2
  exit 1
}

model="gpt-5.5"
effort="high"
workdir="$PWD"
out_dir=""
name=""
prompt_file=""
dry_run=0

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
    --prompt-file)
      [[ $# -ge 2 ]] || die "--prompt-file requires a file"
      prompt_file="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ -d "$workdir" ]] || die "working directory does not exist: $workdir"

if [[ -n "$prompt_file" ]]; then
  [[ -f "$prompt_file" ]] || die "prompt file does not exist: $prompt_file"
  task="$(cat "$prompt_file")"
else
  task="$*"
fi

[[ -n "${task//[[:space:]]/}" ]] || die "delegated task is empty"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
minion_prompt="$skill_dir/references/minion-prompt.md"
[[ -f "$minion_prompt" ]] || die "missing minion prompt: $minion_prompt"

if [[ -z "$out_dir" ]]; then
  out_dir="$workdir/.orchestrator/minions"
fi

mkdir -p "$out_dir"

if [[ -z "$name" ]]; then
  name="minion-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

case "$name" in
  *[!A-Za-z0-9._-]*)
    die "name may contain only letters, digits, dot, underscore, and hyphen"
    ;;
esac

prompt_path="$out_dir/$name.prompt.md"
log_path="$out_dir/$name.log"
result_path="$out_dir/$name.result.md"
pid_path="$out_dir/$name.pid"
status_path="$out_dir/$name.status"

{
  cat "$minion_prompt"
  printf '\n\n## Delegated Task\n\n%s\n' "$task"
} > "$prompt_path"

codex_cmd=(
  codex exec
  --cd "$workdir"
  --model "$model"
  -c "model_reasoning_effort=\"$effort\""
  -o "$result_path"
  -
)

if [[ "$dry_run" -eq 1 ]]; then
  printf 'dry_run: true\n'
  printf 'model: %s\n' "$model"
  printf 'reasoning_effort: %s\n' "$effort"
  printf 'workdir: %s\n' "$workdir"
  printf 'prompt: %s\n' "$prompt_path"
  printf 'result: %s\n' "$result_path"
  printf 'log: %s\n' "$log_path"
  printf 'command:'
  printf ' %q' "${codex_cmd[@]}"
  printf ' < %q\n' "$prompt_path"
  exit 0
fi

(
  set +e
  "${codex_cmd[@]}" < "$prompt_path"
  rc=$?
  printf '%s\n' "$rc" > "$status_path"
  exit "$rc"
) > "$log_path" 2>&1 &

pid=$!
printf '%s\n' "$pid" > "$pid_path"

printf 'started: %s\n' "$name"
printf 'pid: %s\n' "$pid"
printf 'model: %s\n' "$model"
printf 'reasoning_effort: %s\n' "$effort"
printf 'prompt: %s\n' "$prompt_path"
printf 'result: %s\n' "$result_path"
printf 'log: %s\n' "$log_path"
printf 'status: %s\n' "$status_path"
