#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="${1:-$(mktemp -d /private/tmp/ulecture-cloud-provider-configuration-XXXXXX)}"
mkdir -p "$CHECK_DIR"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -D DOCUMENT_TRANSLATION_TESTING "$APP_ROOT"/Sources/Cloud/*.swift "$APP_ROOT/Tests/CloudFeatureChecks.swift" "$APP_ROOT/Tests/CloudProviderConfigurationChecks.swift" -o "$CHECK_DIR/CloudProviderConfigurationChecks"
"$CHECK_DIR/CloudProviderConfigurationChecks" > "$CHECK_DIR/cloud-provider-configuration.json"
printf 'Cloud provider configuration checks passed: %s\n' "$CHECK_DIR"
