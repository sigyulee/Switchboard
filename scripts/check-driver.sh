#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -le 1 ]] || { printf 'Usage: %s [address|thread|none]\n' "$0" >&2; exit 2; }
sanitizer="${1:-address}"
case "$sanitizer" in
    address) instrumentation=(-fsanitize=address,undefined -fno-sanitize-recover=all) ;;
    thread) instrumentation=(-fsanitize=thread -fno-sanitize-recover=all) ;;
    none) instrumentation=(-fno-sanitize=all) ;;
    *) printf 'Unknown driver sanitizer: %s\n' "$sanitizer" >&2; exit 2 ;;
esac

bash scripts/check-toolchain.sh
python3 Tests/DriverChecks/PreparationChecks.py
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-driver-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
python3 scripts/prepare-driver.py "$check_directory/BlackHole.c"

for role in Caller Reply; do
    # The system include path suppresses warnings only in the upstream translation
    # unit. The harness retains strict warnings, and sanitizers instrument both.
    xcrun --sdk macosx clang -std=c11 -arch arm64 -mmacosx-version-min=27.0 \
        -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer -fblocks -pthread \
        "${instrumentation[@]}" -DkNumber_Of_Channels=2 -DkHas_Driver_Name_Format=false \
        "-DkDriver_Name=\"MIH${role}\"" -isystem "$check_directory" \
        Tests/DriverChecks/PropertyChecks.c \
        -framework CoreAudio -framework Accelerate -framework CoreFoundation \
        -o "$check_directory/PropertyChecks${role}"
    ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 TSAN_OPTIONS=halt_on_error=1 \
        "$check_directory/PropertyChecks${role}"
done
printf 'Driver callback checks passed (%s).\n' "$sanitizer"
