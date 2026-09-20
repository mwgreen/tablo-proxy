#!/bin/bash
# Re-sign and reinstall the TabloTV tvOS app on the Apple TV with a free
# Apple ID ("Personal Team"). Free profiles expire after 7 days; this rebuilds
# and reinstalls when the last good install is older than MAX_AGE_DAYS or the
# app source has changed. Safe to run often: it exits quietly when there's
# nothing to do or the Apple TV isn't reachable. Driven by the launchd agent
# in scripts/com.mwgreen.tablo-tv-refresh.plist (every few hours while awake).
#
# One-time setup (by hand, in Xcode):
#   1. Xcode > Settings > Accounts: sign in with your Apple ID (Personal Team).
#   2. Pair the Apple TV: on the TV, Settings > Remotes and Devices >
#      Remote App and Devices; then it appears in Xcode > Window > Devices.
#   3. Open tvos/TabloTV.xcodeproj (xcodegen generate), pick your team under
#      Signing & Capabilities, and Run once on the Apple TV so the app ID and
#      device get registered and any trust prompt is answered.
#   4. Write ~/.config/tablo-tv/refresh.env:
#        TEAM_ID=ABCDE12345          # Xcode > Settings > Accounts > Personal Team ID
#        DEVICE_IDS="<UDID> <UDID>"  # xcrun devicectl list devices (one or more, space-separated)
#        MAX_AGE_DAYS=5              # optional (default 5)
#        FORCE=0                     # optional, 1 = always rebuild
set -u
set -o pipefail

CONFIG="${HOME}/.config/tablo-tv/refresh.env"
STATE_DIR="${HOME}/Library/Application Support/tablo-tv-refresh"
# Per-device stamps: ${STATE_DIR}/last-success.<UDID> holds the git commit installed there
LOG="${STATE_DIR}/refresh.log"
TVOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TVOS_DIR}/.." && pwd)"
SCHEME="TabloTV"
DERIVED="${TVOS_DIR}/DerivedData"

mkdir -p "${STATE_DIR}"
exec >> "${LOG}" 2>&1
echo "=== $(date '+%F %T') refresh start"

notify() {   # macOS banner so a silent failure doesn't go unnoticed for a week
  osascript -e "display notification \"$2\" with title \"Tablo TV refresh\" subtitle \"$1\"" 2>/dev/null || true
}
fail() { echo "FAIL: $*"; notify "Failed" "$*"; exit 1; }

if [ ! -f "${CONFIG}" ]; then
  # Not set up yet — stay quiet so the agent can be installed ahead of time.
  echo "no ${CONFIG} yet; one-time setup not done (see header). Nothing to do."
  exit 0
fi
# shellcheck disable=SC1090
source "${CONFIG}"
: "${TEAM_ID:?TEAM_ID not set in ${CONFIG}}"
: "${DEVICE_IDS:=${DEVICE_ID:-}}"
[ -n "${DEVICE_IDS}" ] || fail "DEVICE_IDS not set in ${CONFIG}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-5}"
FORCE="${FORCE:-0}"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"

# --- Pick up app source changes -------------------------------------------
cd "${REPO_DIR}" || fail "repo missing"
git fetch -q origin main 2>/dev/null || echo "note: git fetch failed (offline?), building what we have"
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null && [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  if git diff --quiet && git diff --cached --quiet; then
    git pull -q --ff-only origin main && echo "pulled $(git rev-parse --short HEAD)"
  else
    echo "note: working tree dirty, not pulling"
  fi
fi
SRC_HASH="$(git log -1 --format=%H -- tvos 2>/dev/null || echo unknown)"

# --- Which devices need a refresh? -------------------------------------------
# A device is due when its stamp is older than MAX_AGE_DAYS or was built from a
# different tvos/ commit. Devices that aren't reachable right now are skipped
# (not failed) and picked up on a later run.
DUE=()
for DEV in ${DEVICE_IDS}; do
  STAMP="${STATE_DIR}/last-success.${DEV}"
  if [ "${FORCE}" != "1" ] && [ -f "${STAMP}" ]; then
    LAST_HASH="$(cat "${STAMP}")"
    AGE_DAYS=$(( ( $(date +%s) - $(stat -f %m "${STAMP}") ) / 86400 ))
    if [ "${LAST_HASH}" = "${SRC_HASH}" ] && [ "${AGE_DAYS}" -lt "${MAX_AGE_DAYS}" ]; then
      echo "${DEV}: up to date (installed ${AGE_DAYS}d ago, source unchanged)"
      continue
    fi
    echo "${DEV}: refresh due (age=${AGE_DAYS}d source_changed=$([ "${LAST_HASH}" != "${SRC_HASH}" ] && echo yes || echo no))"
  else
    echo "${DEV}: never installed (or FORCE=1)"
  fi
  if ! xcrun devicectl list devices --hide-headers 2>/dev/null | grep -q "${DEV}"; then
    echo "${DEV}: not visible to devicectl; will retry next run"; continue
  fi
  if ! xcrun devicectl device info details --device "${DEV}" 2>/dev/null | grep -qi "connected"; then
    echo "${DEV}: known but not connected (off? other network?); will retry next run"; continue
  fi
  DUE+=("${DEV}")
done
if [ ${#DUE[@]} -eq 0 ]; then
  echo "nothing to do"
  exit 0
fi
BUILD_DEV="${DUE[0]}"

# --- Build with a freshly minted 7-day profile ---------------------------------
cd "${TVOS_DIR}" || fail "tvos dir missing"
xcodegen generate -q || fail "xcodegen generate failed"
rm -rf "${DERIVED}/Build/Products"
if ! xcodebuild -project "${SCHEME}.xcodeproj" -scheme "${SCHEME}" \
     -destination "platform=tvOS,id=${BUILD_DEV}" \
     -derivedDataPath "${DERIVED}" \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Automatic \
     build -quiet; then
  fail "xcodebuild failed — open Xcode; you may need to sign in to your Apple ID again"
fi
APP="$(find "${DERIVED}/Build/Products" -maxdepth 2 -name "${SCHEME}.app" | head -1)"
[ -n "${APP}" ] || fail "built .app not found"

# --- Install to every due device (replaces the app in place; its data survives)
# The profile baked into this build covers all devices registered to the team,
# so one build serves every Apple TV.
FAILED=()
for DEV in "${DUE[@]}"; do
  if xcrun devicectl device install app --device "${DEV}" "${APP}"; then
    echo "${SRC_HASH}" > "${STATE_DIR}/last-success.${DEV}"
    echo "${DEV}: OK installed $(git -C "${REPO_DIR}" rev-parse --short HEAD)"
  else
    echo "${DEV}: install failed"
    FAILED+=("${DEV}")
  fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
  fail "install failed on ${#FAILED[@]} device(s): ${FAILED[*]}"
fi
notify "Reinstalled" "Fresh 7-day profile on ${#DUE[@]} Apple TV(s)"
