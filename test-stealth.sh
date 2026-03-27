#!/bin/bash
# Lightpanda stealth detection baseline test
# Usage: ./test-stealth.sh [/path/to/lightpanda]
# Compares JS fingerprint properties against known bot-detection checks.

set -euo pipefail

LP="${1:-/Users/evan/memory/bin/lightpanda}"
STEALTH_FLAG="${2:---stealth}"  # pass "none" to skip stealth flag
RESULTS_DIR="$(dirname "$0")/stealth-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [ "$STEALTH_FLAG" = "none" ]; then
  EXTRA_ARGS=""
  RESULT_FILE="$RESULTS_DIR/baseline-$TIMESTAMP.txt"
  MODE="baseline (no stealth)"
else
  EXTRA_ARGS="$STEALTH_FLAG"
  RESULT_FILE="$RESULTS_DIR/stealth-$TIMESTAMP.txt"
  MODE="stealth ($STEALTH_FLAG)"
fi

mkdir -p "$RESULTS_DIR"

echo "=== Lightpanda Stealth Detection Test ==="
echo "Binary: $LP"
echo "Mode:   $MODE"
echo "Time:   $(date)"
echo "========================================="
echo ""

# Make sure binary is code-signed (macOS requirement)
codesign -s - "$LP" 2>/dev/null || true

PASS=0
FAIL=0
WARN=0

check() {
  local name="$1" status="$2" value="$3" note="${4:-}"
  if [ "$status" = "PASS" ]; then
    printf "  ✅ %-35s %s\n" "$name" "$value"
    PASS=$((PASS + 1))
  elif [ "$status" = "FAIL" ]; then
    printf "  ❌ %-35s %s %s\n" "$name" "$value" "${note:+($note)}"
    FAIL=$((FAIL + 1))
  else
    printf "  ⚠️  %-35s %s %s\n" "$name" "$value" "${note:+($note)}"
    WARN=$((WARN + 1))
  fi
}

# Helper: extract value from HTML by element id
# Usage: extract_val "$HTML" "js-userAgent"
extract_val() {
  local html="$1" id="$2"
  echo "$html" | sed -n "s/.*id=\"${id}\"[^>]*>\([^<]*\).*/\1/p" | head -1
}

# Helper: extract the full tag containing an id (to check class)
extract_tag() {
  local html="$1" id="$2"
  echo "$html" | sed -n "s/.*\(<[^>]*id=\"${id}\"[^>]*>\).*/\1/p" | head -1
}

# --- Test 1: browserleaks.com/javascript ---
echo "## Test 1: browserleaks.com/javascript"
echo "   Fetching..."
BL_HTML=$("$LP" fetch $EXTRA_ARGS --dump html "https://browserleaks.com/javascript" 2>/dev/null || echo "FETCH_ERROR")

if [ "$BL_HTML" = "FETCH_ERROR" ]; then
  echo "   FETCH FAILED"
else
  ua=$(extract_val "$BL_HTML" "js-userAgent")
  vendor=$(extract_val "$BL_HTML" "js-vendor")
  platform=$(extract_val "$BL_HTML" "js-platform")
  plugins=$(extract_val "$BL_HTML" "js-plugins")
  webdriver=$(extract_val "$BL_HTML" "js-webdriver")
  languages=$(extract_val "$BL_HTML" "js-languages")
  appVersion=$(extract_val "$BL_HTML" "js-appVersion")
  gpc=$(extract_val "$BL_HTML" "js-globalPrivacyControl")
  outerW=$(extract_val "$BL_HTML" "js-outerWidth")
  outerH=$(extract_val "$BL_HTML" "js-outerHeight")
  pdfViewer=$(extract_val "$BL_HTML" "js-pdfViewerEnabled")

  # User-Agent should look like Chrome, not "Lightpanda/1.0"
  if echo "$ua" | grep -qi "chrome"; then
    check "userAgent" "PASS" "$ua"
  else
    check "userAgent" "FAIL" "$ua" "should contain Chrome"
  fi

  # vendor should be "Google Inc."
  if [ "$vendor" = "Google Inc." ]; then
    check "vendor" "PASS" "$vendor"
  else
    check "vendor" "FAIL" "${vendor:-<empty>}" "should be 'Google Inc.'"
  fi

  # platform — stealth targets Win32
  if [ "$platform" = "Win32" ]; then
    check "platform" "PASS" "$platform"
  else
    check "platform" "WARN" "${platform:-<empty>}" "stealth targets Win32"
  fi

  # plugins count should be > 0
  if [ "${plugins:-0}" -gt 0 ] 2>/dev/null; then
    check "plugins.length" "PASS" "$plugins"
  else
    check "plugins.length" "FAIL" "${plugins:-0}" "should be > 0"
  fi

  # webdriver should be false
  if [ "$webdriver" = "false" ]; then
    check "webdriver" "PASS" "$webdriver"
  else
    check "webdriver" "FAIL" "${webdriver:-<empty>}" "should be false"
  fi

  # languages should have multiple entries
  if echo "$languages" | grep -q ','; then
    check "languages" "PASS" "$languages"
  else
    check "languages" "WARN" "${languages:-<empty>}" "only one language"
  fi

  # appVersion should look like Chrome
  if echo "$appVersion" | grep -qi "chrome"; then
    check "appVersion" "PASS" "$appVersion"
  else
    check "appVersion" "FAIL" "${appVersion:-<empty>}" "should contain Chrome"
  fi

  # globalPrivacyControl — Chrome returns null/undefined, not true
  if [ "$gpc" = "true" ]; then
    check "globalPrivacyControl" "FAIL" "$gpc" "should be false/null"
  else
    check "globalPrivacyControl" "PASS" "${gpc:-null}"
  fi

  # outerWidth/outerHeight should be defined
  if [ "$outerW" = "undefined" ] || [ -z "$outerW" ]; then
    check "outerWidth" "FAIL" "${outerW:-<empty>}" "should be a number"
  else
    check "outerWidth" "PASS" "$outerW"
  fi

  if [ "$outerH" = "undefined" ] || [ -z "$outerH" ]; then
    check "outerHeight" "FAIL" "${outerH:-<empty>}" "should be a number"
  else
    check "outerHeight" "PASS" "$outerH"
  fi

  # pdfViewerEnabled should be true
  if [ "$pdfViewer" = "true" ]; then
    check "pdfViewerEnabled" "PASS" "$pdfViewer"
  else
    check "pdfViewerEnabled" "FAIL" "${pdfViewer:-<undefined>}" "should be true"
  fi
fi

echo ""

# --- Test 2: intoli headless detection ---
echo "## Test 2: intoli.com headless detection"
echo "   Fetching..."
INTOLI_HTML=$("$LP" fetch $EXTRA_ARGS --dump html "https://intoli.com/blog/not-possible-to-block-chrome-headless/chrome-headless-test.html" 2>/dev/null || echo "FETCH_ERROR")

if [ "$INTOLI_HTML" = "FETCH_ERROR" ]; then
  echo "   FETCH FAILED"
else
  for test_id in user-agent webdriver chrome permissions plugins-length languages; do
    class=$(extract_tag "$INTOLI_HTML" "${test_id}-result")
    value=$(extract_val "$INTOLI_HTML" "${test_id}-result")
    if echo "$class" | grep -q "failed"; then
      check "intoli:$test_id" "FAIL" "${value:-<empty>}"
    else
      check "intoli:$test_id" "PASS" "${value:-<empty>}"
    fi
  done
fi

echo ""

# --- Test 3: Canvas API (local test) ---
echo "## Test 3: Canvas API (local)"
CANVAS_HTML="$(dirname "$0")/stealth-tests/canvas-test.html"
if [ -f "$CANVAS_HTML" ]; then
  echo "   Starting local server..."
  # Start a local HTTP server in background
  python3 -m http.server 18931 --directory "$(dirname "$CANVAS_HTML")" >/dev/null 2>&1 &
  HTTP_PID=$!
  sleep 0.5

  CANVAS_OUT=$("$LP" fetch $EXTRA_ARGS --dump html "http://127.0.0.1:18931/canvas-test.html" --wait-ms 3000 2>/dev/null || echo "FETCH_ERROR")
  kill $HTTP_PID 2>/dev/null || true

  if [ "$CANVAS_OUT" = "FETCH_ERROR" ]; then
    echo "   FETCH FAILED"
    check "canvas-local" "FAIL" "Fetch failed"
  else
    for test_id in getContext fillRect fillText toDataURL fingerprint saveRestore globalAlpha measureText toBlob; do
      tag_content=$(echo "$CANVAS_OUT" | sed -n "s/.*id=\"canvas-${test_id}\"[^>]*>\([^<]*\).*/\1/p" | head -1)
      if echo "$tag_content" | grep -q "^PASS"; then
        value=$(echo "$tag_content" | sed 's/^PASS://')
        check "canvas:$test_id" "PASS" "$value"
      elif echo "$tag_content" | grep -q "^FAIL"; then
        value=$(echo "$tag_content" | sed 's/^FAIL://')
        check "canvas:$test_id" "FAIL" "$value"
      else
        check "canvas:$test_id" "WARN" "${tag_content:-<not found>}" "could not parse"
      fi
    done
    summary=$(echo "$CANVAS_OUT" | sed -n "s/.*id=\"canvas-summary\"[^>]*>\([^<]*\).*/\1/p" | head -1)
    echo "   Canvas summary: ${summary:-unknown}"
  fi
else
  echo "   Canvas test HTML not found at $CANVAS_HTML"
  check "canvas-local" "WARN" "test file missing"
fi

echo ""

# --- Test 4: bot.sannysoft.com ---
echo "## Test 4: bot.sannysoft.com"
echo "   Fetching..."
SANNY_OUT=$("$LP" fetch $EXTRA_ARGS --dump html "https://bot.sannysoft.com" 2>&1 || true)

if echo "$SANNY_OUT" | grep -q "fatal\|error\|Error"; then
  check "sannysoft" "WARN" "JS error or fetch issue"
else
  echo "   Got response ($(echo "$SANNY_OUT" | wc -c | tr -d ' ') bytes)"
  # Try to extract canvas-related test results from sannysoft output
  for test_id in "canvas-test-fp" "canvas-test-display"; do
    tag=$(echo "$SANNY_OUT" | sed -n "s/.*id=\"${test_id}\"[^>]*>\([^<]*\).*/\1/p" | head -1)
    if [ -n "$tag" ]; then
      if echo "$tag" | grep -qi "pass\|ok\|yes"; then
        check "sannysoft:$test_id" "PASS" "$tag"
      else
        check "sannysoft:$test_id" "FAIL" "$tag"
      fi
    fi
  done
fi

echo ""

# --- Summary ---
echo "========================================="
echo "RESULTS: $PASS passed, $FAIL failed, $WARN warnings"
echo "========================================="

# Save results
{
  echo "=== Lightpanda Stealth Test Results ==="
  echo "Binary: $LP"
  echo "Time:   $(date)"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo ""
  echo "--- browserleaks.com key values ---"
  echo "userAgent:            ${ua:-N/A}"
  echo "appVersion:           ${appVersion:-N/A}"
  echo "vendor:               ${vendor:-N/A}"
  echo "platform:             ${platform:-N/A}"
  echo "plugins:              ${plugins:-N/A}"
  echo "webdriver:            ${webdriver:-N/A}"
  echo "languages:            ${languages:-N/A}"
  echo "globalPrivacyControl: ${gpc:-N/A}"
  echo "outerWidth:           ${outerW:-N/A}"
  echo "outerHeight:          ${outerH:-N/A}"
  echo "pdfViewerEnabled:     ${pdfViewer:-N/A}"
  echo ""
  echo "--- intoli headless test ---"
  for test_id in user-agent webdriver chrome permissions plugins-length languages; do
    class=$(extract_tag "$INTOLI_HTML" "${test_id}-result")
    value=$(extract_val "$INTOLI_HTML" "${test_id}-result")
    if echo "$class" | grep -q "failed"; then
      echo "$test_id → FAIL: $value"
    else
      echo "$test_id → PASS: $value"
    fi
  done
  echo ""
  echo "--- canvas API (local test) ---"
  if [ -n "${CANVAS_OUT:-}" ] && [ "$CANVAS_OUT" != "FETCH_ERROR" ]; then
    for test_id in getContext fillRect fillText toDataURL fingerprint saveRestore globalAlpha measureText toBlob; do
      tag_content=$(echo "$CANVAS_OUT" | sed -n "s/.*id=\"canvas-${test_id}\"[^>]*>\([^<]*\).*/\1/p" | head -1)
      echo "canvas:$test_id → ${tag_content:-N/A}"
    done
    summary=$(echo "$CANVAS_OUT" | sed -n "s/.*id=\"canvas-summary\"[^>]*>\([^<]*\).*/\1/p" | head -1)
    echo "Summary: ${summary:-unknown}"
  else
    echo "Canvas test: not run or failed"
  fi
  echo ""
  echo "--- bot.sannysoft.com ---"
  if echo "${SANNY_OUT:-}" | grep -q "fatal\|error\|Error"; then
    echo "JS error or fetch issue"
  else
    echo "Response: $(echo "${SANNY_OUT:-}" | wc -c | tr -d ' ') bytes"
  fi
} > "$RESULT_FILE"

echo ""
echo "Results saved to: $RESULT_FILE"
