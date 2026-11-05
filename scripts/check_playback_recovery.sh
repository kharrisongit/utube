#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RECOVERY_CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$RECOVERY_CHECK_DIR"' EXIT
swiftc Opaline/Core/Playback/PlaybackFailure.swift \
  Opaline/Core/Playback/PlaybackStallPolicy.swift \
  Opaline/Core/Playback/Verification/VerificationURLPolicy.swift \
  Opaline/Core/API/VisitorIdentityStore.swift \
  Opaline/Core/Services/PoToken/RemotePoTokenService.swift \
  Opaline/Core/Transport/HTTPTransport.swift \
  Opaline/Core/Common/CancellationToken.swift \
  scripts/playback_recovery_checks.swift -o "$RECOVERY_CHECK_DIR/checks"
"$RECOVERY_CHECK_DIR/checks"
