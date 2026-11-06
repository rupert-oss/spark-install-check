#!/bin/bash
# Install check for the Spark desktop app on one clean Mac (a GitHub-hosted runner).
#
# Does what a customer does, in order: download the disk image get-spark.io
# serves, let Gatekeeper judge it, copy Spark to Applications, open it, and
# check it starts, shows a window and keeps running. Results go to
# $RUNNER_TEMP/spark-check (results.tsv, machine.json, screenshots).
#
# Kept out of Spark's real install numbers: the download uses curl, which the
# site's download counter treats as a script, and get-spark.io is blocked on
# this machine before Spark is opened, so its launch never reaches the server.
set -uo pipefail

OUT="${RUNNER_TEMP:-/tmp}/spark-check"
DL="${RUNNER_TEMP:-/tmp}/spark-download"
mkdir -p "$OUT" "$DL"
RESULTS="$OUT/results.tsv"
: > "$RESULTS"
FAILED=0
URL="${SPARK_MAC_URL:-}"
[ -n "$URL" ] || URL="https://get-spark.io/api/download/mac"
DMG="$DL/Spark-Installer.dmg"

record() { # check, PASS|FAIL|INFO, detail
  local detail="${3//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$1" "$2" "$detail" >> "$RESULTS"
  [ "$2" = "FAIL" ] && FAILED=1
  echo "[$2] $1: $3"
}

OSV=$(sw_vers -productVersion); BUILD=$(sw_vers -buildVersion); ARCH=$(uname -m)
record "Machine" INFO "macOS $OSV ($BUILD), $ARCH, runner ${MACHINE:-unknown}"

# 1. Download, as a customer's browser would get it (get-spark.io redirects to the release file).
if curl -fsSL --retry 3 --retry-delay 5 -o "$DMG" "$URL"; then
  record "Download" PASS "$(du -h "$DMG" | cut -f1 | tr -d ' ') from $(echo "$URL" | sed -E 's#^(https?://[^/]+).*#\1#')"
else
  record "Download" FAIL "curl could not fetch $URL"
fi

SPARK_VERSION=""
if [ -s "$DMG" ]; then
  # A browser download carries the quarantine flag; Gatekeeper judges files that have it.
  QA="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
  xattr -w com.apple.quarantine "$QA" "$DMG"

  # 2. Gatekeeper and notarisation on the disk image itself.
  if o=$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1) && echo "$o" | grep -q "accepted"; then
    record "Gatekeeper: disk image" PASS "$(echo "$o" | grep -m1 '^source=' | sed 's/^source=//')"
  else
    record "Gatekeeper: disk image" FAIL "$o"
  fi
  if o=$(xcrun stapler validate "$DMG" 2>&1); then
    record "Notarisation ticket: disk image" PASS "stapled"
  else
    record "Notarisation ticket: disk image" FAIL "$o"
  fi

  # 3. Install like a customer: open the disk image and copy Spark to Applications.
  MNT=$(hdiutil attach -nobrowse -readonly -noautoopen "$DMG" 2>/dev/null | awk -F'\t' 'END{print $NF}')
  APP_SRC=$(find "$MNT" -maxdepth 1 -name "*.app" -type d 2>/dev/null | head -1)
  if [ -n "$APP_SRC" ] && ditto "$APP_SRC" /Applications/Spark.app; then
    record "Copy to Applications" PASS "$(basename "$APP_SRC")"
  else
    record "Copy to Applications" FAIL "no app found in the disk image (mounted at '$MNT')"
  fi
  [ -n "$MNT" ] && hdiutil detach -quiet "$MNT" 2>/dev/null
fi

APP=/Applications/Spark.app
if [ -d "$APP" ]; then
  # Finder carries the quarantine flag onto an app copied off a downloaded disk image.
  xattr -w com.apple.quarantine "$QA" "$APP"
  PLIST="$APP/Contents/Info.plist"
  SPARK_VERSION=$(defaults read "$PLIST" CFBundleShortVersionString 2>/dev/null)
  EXE=$(defaults read "$PLIST" CFBundleExecutable 2>/dev/null)
  MINOS=$(defaults read "$PLIST" LSMinimumSystemVersion 2>/dev/null)
  record "Spark version" INFO "$SPARK_VERSION (needs macOS $MINOS or later; binary: $(lipo -archs "$APP/Contents/MacOS/$EXE" 2>/dev/null))"

  # 4. Gatekeeper on the installed app: the check behind the first-open prompt.
  if o=$(spctl -a -t exec -vv "$APP" 2>&1) && echo "$o" | grep -q "accepted"; then
    record "Gatekeeper: app" PASS "$(echo "$o" | grep -m1 '^source=' | sed 's/^source=//')"
  else
    record "Gatekeeper: app" FAIL "$o"
  fi
  if o=$(codesign --verify --deep --strict "$APP" 2>&1); then
    record "Code signature" PASS "valid, every nested binary"
  else
    record "Code signature" FAIL "$o"
  fi
  if o=$(xcrun stapler validate "$APP" 2>&1); then
    record "Notarisation ticket: app" PASS "stapled"
  else
    record "Notarisation ticket: app" FAIL "$o"
  fi

  # 5. The bundled download tools run on this Mac (yt-dlp, ffmpeg, ffprobe, QuickJS).
  M="$APP/Contents/MacOS"
  if o=$("$M/yt-dlp" --version 2>&1); then record "Tool: yt-dlp" PASS "$o"; else record "Tool: yt-dlp" FAIL "$o"; fi
  if o=$("$M/ffmpeg" -hide_banner -version 2>&1 | head -1) && [ -n "$o" ] && echo "$o" | grep -qi "ffmpeg version"; then record "Tool: ffmpeg" PASS "$o"; else record "Tool: ffmpeg" FAIL "$o"; fi
  if o=$("$M/ffprobe" -hide_banner -version 2>&1 | head -1) && echo "$o" | grep -qi "ffprobe version"; then record "Tool: ffprobe" PASS "$o"; else record "Tool: ffprobe" FAIL "$o"; fi
  if o=$("$M/qjs" -e 'console.log(6*7)' 2>&1) && [ "$(echo "$o" | tail -1)" = "42" ]; then record "Tool: QuickJS" PASS "runs JavaScript"; else record "Tool: QuickJS" FAIL "$o"; fi

  # 6. Keep this test machine out of Spark's real install numbers.
  printf '\n127.0.0.1 get-spark.io\n127.0.0.1 www.get-spark.io\n::1 get-spark.io\n::1 www.get-spark.io\n' | sudo tee -a /etc/hosts >/dev/null
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null
  sleep 2
  if curl -s -m 5 -o /dev/null https://get-spark.io/; then
    record "Kept out of install stats" FAIL "get-spark.io still reachable, so Spark was not opened"
  else
    record "Kept out of install stats" INFO "get-spark.io blocked on this machine before opening Spark"

    # 7. Open Spark. Clearing the flag is the customer clicking Open on the first-open prompt.
    xattr -dr com.apple.quarantine "$APP"
    touch "$DL/opened.marker"
    open -a "$APP"
    sleep 40
    PID=$(pgrep -x "$EXE" | head -1)
    if [ -n "$PID" ]; then
      record "Opens" PASS "running after 40 s (pid $PID)"
    else
      record "Opens" FAIL "no $EXE process 40 s after opening"
    fi

    cat > "$DL/windows.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let want = CommandLine.arguments.dropFirst().map { $0.lowercased() }
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
  let owner = ((w[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
  let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
  guard want.contains(owner), layer == 0 else { continue }
  let b = (w[kCGWindowBounds as String] as? [String: Any]) ?? [:]
  let wd = Int((b["Width"] as? Double) ?? 0), ht = Int((b["Height"] as? Double) ?? 0)
  print("\(wd)x\(ht)")
}
SWIFT
    WINS=$(swift "$DL/windows.swift" "$EXE" "Spark" 2>/dev/null | sort -t x -k1 -nr | head -1)
    if [ -n "$WINS" ]; then
      W=${WINS%x*}; H=${WINS#*x}
      if [ "$W" -ge 400 ] && [ "$H" -ge 300 ]; then record "Window" PASS "on screen, ${WINS}"; else record "Window" FAIL "only a small window (${WINS})"; fi
    else
      record "Window" FAIL "no Spark window on screen"
    fi
    screencapture -x "$OUT/screen-after-40s.png" 2>/dev/null || record "Screenshot" INFO "screen capture not allowed on this machine"

    # 8. Still running a minute later, with no crash report.
    sleep 60
    if pgrep -x "$EXE" >/dev/null; then
      MEM=$(ps -o rss= -p "$(pgrep -x "$EXE" | head -1)" 2>/dev/null | awk '{printf "%d MB", $1/1024}')
      record "Keeps running" PASS "still running after 100 s, $MEM memory"
    else
      record "Keeps running" FAIL "quit or crashed within 100 s"
    fi
    screencapture -x "$OUT/screen-after-100s.png" 2>/dev/null
    CRASHES=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -newer "$DL/opened.marker" \( -iname "${EXE}*" -o -iname "spark*" -o -iname "yt-dlp*" -o -iname "ffmpeg*" \) 2>/dev/null | head -3)
    if [ -z "$CRASHES" ]; then
      record "No crash reports" PASS "none since opening"
    else
      record "No crash reports" FAIL "$(basename -a $CRASHES | tr '\n' ' ')"
      for c in $CRASHES; do cp "$c" "$OUT/" 2>/dev/null; done
    fi
  fi
fi

RESULT=PASS; [ "$FAILED" = 1 ] && RESULT=FAIL
cat > "$OUT/machine.json" <<JSON
{"runner": "${MACHINE:-}", "platform": "macOS", "os": "macOS $OSV", "build": "$BUILD", "arch": "$ARCH", "spark": "$SPARK_VERSION", "result": "$RESULT"}
JSON

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### macOS $OSV ($ARCH): $RESULT"
    echo ""
    echo "| Check | Result | Detail |"
    echo "|---|---|---|"
    while IFS=$'\t' read -r c s d; do echo "| $c | $s | ${d//|//} |"; done < "$RESULTS"
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$FAILED"
