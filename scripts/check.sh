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
bash scripts/check-endpoint.sh
bash scripts/check-tap.sh
bash scripts/check-microphone-access.sh
bash scripts/check-application-catalog.sh
bash scripts/check-pipeline.sh
bash scripts/check-session-presentation.sh
bash scripts/check-library-navigation.sh
bash scripts/check-library-layout.sh
bash scripts/check-build-version.sh
bash scripts/check-transcript-search.sh
bash scripts/check-transcript-search-layout.sh
bash scripts/check-transcript-controls.sh
bash scripts/check-transcript-pcm.sh
bash scripts/check-driver.sh
bash scripts/check-swift-concurrency.sh
bash scripts/check-queue.sh thread
bash scripts/check-driver.sh thread
printf 'Local checks passed. Live audio hardware and call behavior were not tested.\n'
