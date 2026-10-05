#!/usr/bin/env bash
# Re-sign, restart and open the Debug build only (bundle id com.hedon.shadowing.debug).
# The installed Release app (com.hedon.shadowing, e.g. /Applications/Shadowing.app) is never
# touched, even though its process is also named "Shadowing".

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$root_dir/build/DerivedData/Build/Products/Debug/Shadowing.app"
bundle_id="com.hedon.shadowing.debug"

if [[ ! -d "$app_path" ]]; then
  echo "Built app is missing: $app_path" >&2
  exit 1
fi

built_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
if [[ "$built_id" != "$bundle_id" ]]; then
  echo "Expected a Debug build ($bundle_id), found $built_id: $app_path" >&2
  exit 1
fi

# PIDs of running apps with the Debug bundle id (never the Release app).
debug_pids() {
  local asn
  while IFS= read -r asn; do
    [[ -n "$asn" ]] || continue
    lsappinfo info -only pid "$asn" | sed -n 's/.*"pid"=\([0-9][0-9]*\).*/\1/p'
  done < <(lsappinfo find "bundleid=$bundle_id" | tr ' ' '\n' | grep '^ASN:' || true)
}

stop_debug_app() {
  local signal="$1" pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done < <(debug_pids)
}

if [[ -n "$(debug_pids)" ]]; then
  echo "Stopping the running Debug build..."
  stop_debug_app TERM
  for _ in {1..50}; do
    [[ -z "$(debug_pids)" ]] && break
    sleep 0.1
  done
  if [[ -n "$(debug_pids)" ]]; then
    echo "Force stopping the Debug build..."
    stop_debug_app KILL
  fi
fi

# Unsigned builds are only linker-signed, so macOS would forget the microphone grant.
"$root_dir/scripts/adhoc-resign.sh" "$app_path"

echo "Opening $app_path"
open "$app_path"
