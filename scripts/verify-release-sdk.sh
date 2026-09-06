#!/bin/bash
# Verify both slices of the actual packaged executable, not just the build host.
set -euo pipefail

binary=${1:?Usage: verify-release-sdk.sh path/to/lightty}
xcrun lipo "$binary" -verify_arch arm64 x86_64
for arch in arm64 x86_64; do
    build=$(xcrun vtool -arch "$arch" -show-build "$binary")
    sdk=$(awk '$1 == "sdk" {print $2}' <<< "$build")
    minos=$(awk '$1 == "minos" {print $2}' <<< "$build")
    echo "$arch: sdk=$sdk minos=$minos"
    if [[ "$sdk" != "26.5" || "$minos" != "13.0" ]]; then
        echo "Release must link macOS SDK 26.5 and retain deployment target 13.0" >&2
        exit 1
    fi
done
