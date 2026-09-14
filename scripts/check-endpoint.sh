#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
bash scripts/check-toolchain.sh

# Compile the actual endpoint with setup API doubles; no audio device is opened.
# This setup/teardown test is sequential, so ASan+UBSan are the relevant checks.
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-endpoint-check.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
xcrun --sdk macosx clang -std=c11 -arch arm64 -mmacosx-version-min=26.0 \
    -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I Sources/AudioRealtime/include \
    Sources/AudioRealtime/Queue.c Tests/AudioEndpointChecks/BindingChecks.c \
    -framework AudioToolbox -framework CoreAudio \
    -o "$check_directory/BindingChecks"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$check_directory/BindingChecks"
