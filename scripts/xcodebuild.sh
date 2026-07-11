#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$root_dir/Shadowing/Shadowing.xcodeproj"
derived_data_path="$root_dir/build/DerivedData"
source_packages_path="$root_dir/build/SourcePackages"
action="${1:-build}"

if [[ ! -d "$project_path" ]]; then
  echo "Generated project is missing. Run: make generate" >&2
  exit 1
fi

case "$action" in
  build | test) ;;
  *)
    echo "Usage: $0 <build|test>" >&2
    exit 2
    ;;
esac

xcodebuild "$action" \
  -project "$project_path" \
  -scheme Shadowing \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$source_packages_path" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
