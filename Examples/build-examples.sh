#!/bin/zsh
# Generates and builds every example. Needs xcodegen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"
config="${1:-Debug}"
for dir in Calculator WorldClock; do
  echo "== $dir"
  (cd "$dir" && xcodegen generate --quiet)
  xcodebuild -project "$dir/$dir.xcodeproj" -scheme "$dir" -configuration "$config" \
    -derivedDataPath "$dir/build" -quiet build
  echo "   $dir/build/Build/Products/$config/$dir.app"
done
