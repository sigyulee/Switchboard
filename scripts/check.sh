#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/check-toolchain.sh
python3 scripts/check-source.py
python3 scripts/compile-localizations.py --check
for script in scripts/*.sh; do
    bash -n "$script"
done

xcrun swift-format lint --strict --configuration .swift-format --recursive \
    Package.swift Sources Tests Installer
bash scripts/swift.sh run --configuration debug BridgeChecks
bash scripts/check-queue.sh
bash scripts/check-tap.sh
bash scripts/check-driver.sh
bash scripts/check-swift-concurrency.sh
bash scripts/check-queue.sh thread
bash scripts/check-driver.sh thread
printf 'Local checks passed. Live audio hardware and call behavior were not tested.\n'
