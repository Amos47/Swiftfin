#!/bin/sh
# Personal fork: checks for the player work (and home rows). Run before merging into `custom`.
#   - PlayerCore and HomeRowsCore unit tests (swift test, on the Mac)
#   - builds of both app schemes for the simulator
#   - SwiftLint on the fork's new player and home rows code
set -eu
cd "$(dirname "$0")/.."  # the repo root

log=$(mktemp)
trap 'rm -f "$log"' EXIT

for package in PlayerCore HomeRowsCore; do
    echo "==> $package tests"
    if ! (cd "$package" && swift test >"$log" 2>&1); then
        tail -30 "$log"
        echo "error: $package tests failed"
        exit 1
    fi
    grep -E "Executed [0-9]+ tests" "$log" | tail -1
done

for scheme in "Swiftfin|iOS" "Swiftfin tvOS|tvOS"; do
    name=${scheme%|*}
    platform=${scheme#*|}
    echo "==> Building $name"
    xcodebuild -scheme "$name" -destination "generic/platform=$platform Simulator" \
        -skipMacroValidation -skipPackagePluginValidation build -quiet
done

echo "==> SwiftLint"
swiftlint lint --quiet --strict \
    PlayerCore HomeRowsCore \
    Shared/Objects/HomeRows Shared/Views/SettingsView/HomeRowsEditor \
    Shared/Objects/PlaybackEngine.swift \
    Shared/Objects/MediaPlayerManager/MediaPlayerItem/MediaPlayerItem+AppleEngine.swift \
    Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy+AVPlayer.swift \
    Shared/Views/VideoPlayer/VideoPlayer+AppleEngine.swift \
    Swiftfin/Views/VideoPlayer/Components

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: the build changed tracked files (SwiftFormat or SwiftGen):"
    git status --short
fi
echo "==> All checks passed"
