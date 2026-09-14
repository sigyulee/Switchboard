#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

sanitizer="${1:-address}"
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [address|thread]\n' "$0" >&2
    exit 2
fi
case "$sanitizer" in
    address) sanitizer_flags=(-fsanitize=address,undefined) ;;
    thread) sanitizer_flags=(-fsanitize=thread) ;;
    *) printf 'Usage: %s [address|thread]\n' "$0" >&2; exit 2 ;;
esac
bash scripts/check-toolchain.sh

# Compile the production queue directly without opening audio devices.
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-queue-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun --sdk macosx clang -std=c11 -arch arm64 -mmacosx-version-min=26.0 \
    -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
    "${sanitizer_flags[@]}" -fno-sanitize-recover=all -pthread \
    -I Sources/AudioRealtime/include \
    Sources/AudioRealtime/Queue.c Tests/AudioRealtimeChecks/QueueStress.c \
    -o "$check_directory/QueueStress"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    TSAN_OPTIONS=halt_on_error=1:exitcode=66 "$check_directory/QueueStress"
