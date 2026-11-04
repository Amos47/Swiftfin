#!/bin/sh
# Personal fork: checks for the Custom Home Rows work. Run before merging into `custom`.
#   - HomeRowsCore unit tests (swift test, on the Mac)
#   - builds of both app schemes for the simulator
#   - SwiftLint on the fork's new code
set -eu
cd "$(dirname "$0")/.."  # the repo root

echo "==> HomeRowsCore tests"
(cd HomeRowsCore && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1)

for scheme in "Swiftfin|iOS" "Swiftfin tvOS|tvOS"; do
    name=${scheme%|*}
    platform=${scheme#*|}
    echo "==> Building $name"
    xcodebuild -scheme "$name" -destination "generic/platform=$platform Simulator" \
        -skipMacroValidation -skipPackagePluginValidation build -quiet
done

echo "==> SwiftLint"
swiftlint lint --quiet --strict HomeRowsCore Shared/Objects/HomeRows Shared/Views/SettingsView/HomeRowsEditor

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: the build changed tracked files (SwiftFormat or SwiftGen):"
    git status --short
fi
echo "==> All checks passed"
