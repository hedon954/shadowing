#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

fail() {
  echo "Architecture validation failed: $*" >&2
  exit 1
}

assert_link() {
  local path="$1"
  local expected="$2"

  [[ -L "$path" ]] || fail "$path must be a symbolic link"
  [[ "$(readlink "$path")" == "$expected" ]] ||
    fail "$path must point to $expected"
}

[[ -f CLAUDE.md ]] || fail "CLAUDE.md is missing"
[[ -f docs/prd/prd-v0.0.1-2026-07-11.md ]] || fail "MVP PRD is missing"
[[ -f Shadowing/project.yml ]] || fail "XcodeGen project.yml is missing"

assert_link AGENTS.md CLAUDE.md
assert_link .cursor/skills ../.claude/skills
assert_link .codex/skills ../.claude/skills

adr_files=(docs/adr/[0-9][0-9][0-9][0-9]-*.md)
[[ ${#adr_files[@]} -gt 0 ]] || fail "no ADR files found"

for adr in "${adr_files[@]}"; do
  for heading in Context Decision Consequences Verification; do
    grep -q "^## $heading$" "$adr" ||
      fail "$adr is missing the '$heading' section"
  done
done

skill_files=(.claude/skills/*/SKILL.md)
[[ ${#skill_files[@]} -gt 0 ]] || fail "no project skills found"

for skill in "${skill_files[@]}"; do
  grep -q "^name:" "$skill" || fail "$skill is missing a name"
  grep -q "^description:" "$skill" || fail "$skill is missing a description"
done

for directory in Shadowing/App Shadowing/Features; do
  [[ -d "$directory" ]] || continue
  if grep -R -E -q "^import (AVFoundation|GRDB)$" "$directory"; then
    fail "$directory must not import AVFoundation or GRDB"
  fi
done

if grep -R -E -q "^import (SwiftUI|AVFoundation|GRDB)$" Shadowing/Domain; then
  fail "Domain must not import SwiftUI, AVFoundation, or GRDB"
fi

echo "Architecture validation passed."
