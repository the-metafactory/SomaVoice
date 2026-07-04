#!/usr/bin/env bash
# check-tcc.sh — observe whether the signing identity is stable and whether
# Screen Recording (TCC) is granted. Run after ./make-app.sh.
#
# WHY: macOS ties TCC permission grants to an app's code-signing "designated
# requirement". Ad-hoc signing changes that requirement on every build, so grants
# silently vanish and the feature looks "randomly broken". A stable signing
# identity (MetaFactoryDev) keeps the requirement — and thus the grants — constant.
#
# NOTE ON SCOPE: Phase 1 sight uses SCContentSharingPicker, which needs NO Screen
# Recording grant at all. This script exists to make permission state OBSERVABLE
# and to prove the signing identity is stable across rebuilds — not because the
# grant is required.
set -euo pipefail
cd "$(dirname "$0")"

APP="SomaVoice.app"

echo "== signing identity (must be identical across rebuilds) =="
if [[ -d "$APP" ]]; then
  codesign -dvvv "$APP" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier" || true
else
  echo "  (no $APP yet — run ./make-app.sh first)"
fi

echo
echo "== designated requirement (the string TCC keys grants on) =="
if [[ -d "$APP" ]]; then
  codesign -d -r- "$APP" 2>&1 | grep -E "designated" || true
fi

echo
echo "== Screen Recording preflight (toolchain process — indicative only) =="
# CGPreflightScreenCaptureAccess reports the CALLING process's access. Run here it
# reflects the swift toolchain, not SomaVoice.app. The authoritative check lives
# inside the app on first capture. This is a smoke reference, not the source of truth.
swift - <<'SWIFT' 2>/dev/null || echo "  (swift preflight unavailable)"
import CoreGraphics
let granted = CGPreflightScreenCaptureAccess()
print("  CGPreflightScreenCaptureAccess (toolchain): \(granted ? "GRANTED" : "not granted")")
SWIFT

echo
echo "Done. If Authority differs between two rebuilds, the identity is NOT stable —"
echo "grants will keep resetting. Fix the cert before building Phase 1 sight."
