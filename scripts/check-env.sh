#!/usr/bin/env bash

set -euo pipefail

required_commands=(
  actionlint
  pre-commit
  swiftformat
  swiftlint
  xcodebuild
  xcodegen
)

missing=()
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing+=("$command_name")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing required tools: ${missing[*]}" >&2
  echo "Run: brew bundle" >&2
  exit 1
fi

developer_dir="$(xcode-select -p)"
if [[ ! -d "$developer_dir" ]]; then
  echo "xcode-select points to a missing directory: $developer_dir" >&2
  exit 1
fi

echo "Environment is ready."
