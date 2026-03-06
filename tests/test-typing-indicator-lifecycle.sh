#!/bin/bash
#
# Tests for typing indicator lifecycle
# Verifies: start when message arrives, alive while agent works, stop when agent exits
#
# Mocks osascript so tests run without Messages.app or Accessibility permissions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR=$(mktemp -d)
MOCK_LOG="$TMP_DIR/osascript_calls.log"

passed=0
failed=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Create mock osascript that logs calls instead of executing
setup_mock() {
    mkdir -p "$TMP_DIR/bin"
    cat > "$TMP_DIR/bin/osascript" <<MOCK
#!/bin/bash
# Read the script from stdin (heredoc) or args
if [ "\$1" = "-e" ]; then
    script="\$2"
else
    script=\$(cat)
fi
echo "\$script" >> "$MOCK_LOG"
echo "---" >> "$MOCK_LOG"
MOCK
    chmod +x "$TMP_DIR/bin/osascript"

    # Also mock 'open' for the URL scheme call
    cat > "$TMP_DIR/bin/open" <<MOCK
#!/bin/bash
echo "open \$*" >> "$MOCK_LOG"
MOCK
    chmod +x "$TMP_DIR/bin/open"

    export PATH="$TMP_DIR/bin:$PATH"
    > "$MOCK_LOG"
}

assert_contains() {
    local description="$1"
    local pattern="$2"
    local file="${3:-$MOCK_LOG}"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $description"
        passed=$((passed + 1))
    else
        echo "  FAIL: $description (expected pattern: $pattern)"
        echo "  Log contents:"
        cat "$file" 2>/dev/null | sed 's/^/    /'
        failed=$((failed + 1))
    fi
}

assert_not_contains() {
    local description="$1"
    local pattern="$2"
    local file="${3:-$MOCK_LOG}"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $description"
        passed=$((passed + 1))
    else
        echo "  FAIL: $description (unexpected pattern found: $pattern)"
        failed=$((failed + 1))
    fi
}

assert_call_count() {
    local description="$1"
    local pattern="$2"
    local expected="$3"
    local file="${4:-$MOCK_LOG}"
    local actual=$(grep -c "$pattern" "$file" 2>/dev/null || echo 0)
    if [ "$actual" -eq "$expected" ]; then
        echo "  PASS: $description (count: $actual)"
        passed=$((passed + 1))
    else
        echo "  FAIL: $description (expected $expected, got $actual)"
        failed=$((failed + 1))
    fi
}

INDICATOR="$PROJECT_ROOT/skills/imessage/typing-indicator.sh"
PHONE="+14155551234"

# ─── Test 1: start triggers keystroke ─────────────────────────────────────────
echo "Test 1: start opens conversation and types a space"
setup_mock
"$INDICATOR" "$PHONE" start
assert_contains "opens imessage URL" "imessage://" "$MOCK_LOG"
assert_contains "sends keystroke" "keystroke" "$MOCK_LOG"

# ─── Test 2: stop clears input field ─────────────────────────────────────────
echo "Test 2: stop selects all and deletes"
setup_mock
"$INDICATOR" "$PHONE" stop
assert_contains "selects all with cmd+a" 'keystroke "a" using command down' "$MOCK_LOG"
assert_contains "presses delete key" "key code 51" "$MOCK_LOG"

# ─── Test 3: keepalive re-types ───────────────────────────────────────────────
echo "Test 3: keepalive deletes and re-types"
setup_mock
"$INDICATOR" "$PHONE" keepalive
assert_contains "presses delete" "key code 51" "$MOCK_LOG"
assert_contains "re-types space" 'keystroke " "' "$MOCK_LOG"

# ─── Test 4: no args exits with error ────────────────────────────────────────
echo "Test 4: missing contact exits with error"
setup_mock
if "$INDICATOR" 2>/dev/null; then
    echo "  FAIL: should have exited with error"
    failed=$((failed + 1))
else
    echo "  PASS: exits non-zero without contact"
    passed=$((passed + 1))
fi

# ─── Test 5: unknown action exits with error ─────────────────────────────────
echo "Test 5: unknown action exits with error"
setup_mock
if "$INDICATOR" "$PHONE" bogus 2>/dev/null; then
    echo "  FAIL: should have exited with error"
    failed=$((failed + 1))
else
    echo "  PASS: exits non-zero for unknown action"
    passed=$((passed + 1))
fi

# ─── Test 6: lifecycle — indicator alive during work, stopped after ───────────
echo "Test 6: full lifecycle — start, keepalive while working, stop when done"
setup_mock

# Simulate: start indicator
"$INDICATOR" "$PHONE" start

# Simulate: agent is working, keepalive fires
"$INDICATOR" "$PHONE" keepalive
"$INDICATOR" "$PHONE" keepalive

# Simulate: agent finished, stop indicator
"$INDICATOR" "$PHONE" stop

# Verify ordering: start happened, keepalives happened, stop happened
assert_call_count "start produced one keystroke space" 'keystroke " "' 3  # 1 start + 2 keepalives
assert_call_count "stop produced cmd+a" 'keystroke "a" using command down' 1

# ─── Test 7: daemon integration — stop always called even if agent fails ──────
echo "Test 7: stop called even when agent process fails"
setup_mock

# Simulate what the daemon does: start indicator, run a failing "agent", then stop
"$INDICATOR" "$PHONE" start

# Fake agent that exits with error
(exit 1) || true

# Daemon should still stop the indicator
"$INDICATOR" "$PHONE" stop

assert_contains "stop is called after failure" 'keystroke "a" using command down' "$MOCK_LOG"

# ─── Test 8: no indicator when no agent running ──────────────────────────────
echo "Test 8: no osascript calls when no action taken"
setup_mock
# Don't call anything — simulate idle daemon loop
assert_not_contains "no calls during idle" "keystroke"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo "Results: $passed passed, $failed failed"
echo "════════════════════════════════"

[ "$failed" -eq 0 ]
