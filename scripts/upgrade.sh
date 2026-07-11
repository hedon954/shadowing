#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$root_dir/build/DerivedData/Build/Products/Debug/Shadowing.app"
process_name="Shadowing"

if [[ ! -d "$app_path" ]]; then
  echo "Built app is missing: $app_path" >&2
  exit 1
fi

if pids="$(pgrep -x "$process_name")"; then
  echo "Stopping running $process_name process..."
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done <<<"$pids"

  for _ in {1..50}; do
    if ! pgrep -x "$process_name" >/dev/null; then
      break
    fi
    sleep 0.1
  done

  if remaining_pids="$(pgrep -x "$process_name")"; then
    echo "Force stopping $process_name process..."
    while IFS= read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
    done <<<"$remaining_pids"
  fi
fi

echo "Opening $app_path"
open "$app_path"
