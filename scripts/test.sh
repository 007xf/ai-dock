#!/bin/bash
# Run isolated regression checks using only Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native
bin_path=$(swift build --show-bin-path --build-system native)
objects=()
for object in "$bin_path/AIDock.build/"*.o; do
    # The application's entry point starts NSApplication; never link it into tests.
    [[ "$object" == */main.swift.o ]] || objects+=("$object")
done
swiftc -parse-as-library -I "$bin_path/Modules" Tests/RegressionTests.swift \
    "${objects[@]}" -lsqlite3 -o "$bin_path/regression-tests"
"$bin_path/regression-tests"
