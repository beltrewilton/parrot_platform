#!/bin/bash
#
# test_and_report.sh - Run test, analyze, create bug report if errors found
#
# Usage: ./test_and_report.sh <script_name> [sip_uri] [delay_seconds] [pjsua_extra_cmds]
#
# Examples:
#   ./test_and_report.sh test_answer_play
#   ./test_and_report.sh test_answer_play test 3
#   ./test_and_report.sh test_dtmf_dsl test 2 "echo 1; echo 2; echo 3; echo #"
#   ./test_and_report.sh test_reject_dsl 486 2
#   ./test_and_report.sh test_ivr_menu ivr 3 "echo 1; sleep 1; echo 1; sleep 1; echo 9"
#
# Output (single line for orchestrator consumption):
#   TEST: <name> | STATUS: PASS|FAIL|LOCKED | BUG: <id>|none | SUMMARY: <one-line>
#
# Exit codes:
#   0 - Test passed
#   1 - Test failed (bug created)
#   2 - Infrastructure error (couldn't start server, pjsua not found, etc.)
#   3 - Test locked by another orchestrator
#
# Environment:
#   ORCHESTRATOR_ID - Unique ID for this orchestrator (default: user-pid)
#   SKIP_LOCK       - Set to "1" to skip locking (for single-orchestrator use)
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
SCRIPT_NAME="${1:-}"
SIP_URI="${2:-test}"
DELAY="${3:-3}"
PJSUA_EXTRA="${4:-}"
ORCHESTRATOR_ID="${ORCHESTRATOR_ID:-$(whoami)-$$}"
SKIP_LOCK="${SKIP_LOCK:-0}"

# Colors for terminal (disabled in non-tty)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

usage() {
    echo "Usage: $0 <script_name> [sip_uri] [delay_seconds] [pjsua_extra_cmds]"
    echo ""
    echo "Run a test script, analyze results, create bug report if errors found."
    echo ""
    echo "Arguments:"
    echo "  script_name      Name of test script (without .exs)"
    echo "  sip_uri          SIP URI user part (default: test)"
    echo "  delay_seconds    Wait time before hangup (default: 3)"
    echo "  pjsua_extra_cmds Extra pjsua commands (e.g., DTMF: 'echo 1; echo 2')"
    echo ""
    echo "Examples:"
    echo "  $0 test_answer_play"
    echo "  $0 test_dtmf_dsl test 2 'echo 1; echo 2; echo 3; echo #'"
    echo "  $0 test_reject_dsl 486 2"
    echo ""
    echo "Available test scripts:"
    ls -1 "$SCRIPT_DIR"/*.exs 2>/dev/null | xargs -I {} basename {} .exs | sed 's/^/  /'
    exit 2
}

output_result() {
    local status="$1"
    local bug_id="$2"
    local summary="$3"
    echo "TEST: $SCRIPT_NAME | STATUS: $status | BUG: $bug_id | SUMMARY: $summary"
}

# Check arguments
if [ -z "$SCRIPT_NAME" ] || [ "$SCRIPT_NAME" = "-h" ] || [ "$SCRIPT_NAME" = "--help" ]; then
    usage
fi

# Verify script exists
if [ ! -f "$SCRIPT_DIR/${SCRIPT_NAME}.exs" ]; then
    output_result "ERROR" "none" "Script not found: ${SCRIPT_NAME}.exs"
    exit 2
fi

# Check pjsua is available
if ! command -v pjsua &> /dev/null; then
    output_result "ERROR" "none" "pjsua not found - install with: brew install pjsip"
    exit 2
fi

# Change to project root for mix commands
cd "$PROJECT_ROOT"

# Acquire lock (unless skipped)
LOCK_ID=""
if [ "$SKIP_LOCK" != "1" ]; then
    echo -e "${YELLOW}Acquiring lock for $SCRIPT_NAME...${NC}" >&2
    LOCK_RESULT=$("$SCRIPT_DIR/orchestrator_lock.sh" acquire "$SCRIPT_NAME" "$ORCHESTRATOR_ID" 2>&1)
    LOCK_EXIT=$?

    if [ $LOCK_EXIT -ne 0 ]; then
        output_result "LOCKED" "none" "$LOCK_RESULT"
        exit 3
    fi

    LOCK_ID=$(echo "$LOCK_RESULT" | grep -oE 'parrot_platform-[a-z0-9]+' || echo "")
    echo -e "${GREEN}  Lock acquired: $LOCK_ID${NC}" >&2
fi

# Cleanup function to release lock
cleanup() {
    if [ -n "$LOCK_ID" ] && [ "$SKIP_LOCK" != "1" ]; then
        echo -e "${YELLOW}Releasing lock...${NC}" >&2
        "$SCRIPT_DIR/orchestrator_lock.sh" release "$SCRIPT_NAME" "$ORCHESTRATOR_ID" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

echo -e "${YELLOW}Starting test: $SCRIPT_NAME${NC}" >&2

# Step 1: Start test server
echo -e "${YELLOW}[1/5] Starting test server...${NC}" >&2
START_OUTPUT=$("$SCRIPT_DIR/run_test.sh" "$SCRIPT_NAME" 2>&1)
START_EXIT=$?

if [ $START_EXIT -ne 0 ]; then
    output_result "ERROR" "none" "Failed to start test server"
    echo "$START_OUTPUT" >&2
    exit 2
fi

# Parse PID and LOG from output
TEST_PID=$(echo "$START_OUTPUT" | grep "TEST_PID=" | cut -d= -f2)
TEST_LOG=$(echo "$START_OUTPUT" | grep "TEST_LOG=" | cut -d= -f2)

if [ -z "$TEST_PID" ] || [ -z "$TEST_LOG" ]; then
    output_result "ERROR" "none" "Could not parse PID/LOG from run_test.sh output"
    echo "$START_OUTPUT" >&2
    exit 2
fi

echo -e "${GREEN}  Server started: PID=$TEST_PID${NC}" >&2

# Step 2: Run pjsua client
echo -e "${YELLOW}[2/5] Running pjsua client (URI: $SIP_URI, delay: ${DELAY}s)...${NC}" >&2

# Build pjsua command sequence
if [ -n "$PJSUA_EXTRA" ]; then
    PJSUA_CMDS="sleep $DELAY; $PJSUA_EXTRA; sleep 1; echo h; sleep 1; echo q"
else
    PJSUA_CMDS="sleep $DELAY; echo h; sleep 1; echo q"
fi

# Run pjsua and capture output
PJSUA_OUTPUT=$(eval "($PJSUA_CMDS)" | pjsua --null-audio --no-tcp --local-port=5100 \
    "sip:${SIP_URI}@127.0.0.1:5080" 2>&1) || true

# Check if call connected
if echo "$PJSUA_OUTPUT" | grep -qi "CONFIRMED\|state changed to CONFIRMED"; then
    echo -e "${GREEN}  Call connected successfully${NC}" >&2
else
    echo -e "${YELLOW}  Call may not have connected (check logs)${NC}" >&2
fi

# Step 3: Stop test server
echo -e "${YELLOW}[3/5] Stopping test server...${NC}" >&2
"$SCRIPT_DIR/stop_test.sh" "$TEST_PID" "$TEST_LOG" >/dev/null 2>&1 || true

# Step 4: Analyze logs
echo -e "${YELLOW}[4/5] Analyzing logs...${NC}" >&2
CHECK_OUTPUT=$("$SCRIPT_DIR/check_test.sh" "$TEST_LOG" 2>&1)
CHECK_EXIT=$?

# Extract key metrics from check output
ERROR_COUNT=$(echo "$CHECK_OUTPUT" | grep -i "errors:" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
WARNING_COUNT=$(echo "$CHECK_OUTPUT" | grep -i "warnings:" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
CRASH_COUNT=$(echo "$CHECK_OUTPUT" | grep -i "crashes:" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")

# Step 5: Create bug report if errors found
if [ $CHECK_EXIT -ne 0 ]; then
    echo -e "${RED}[5/5] Errors detected - creating bug report...${NC}" >&2

    # Extract error summary (first 30 lines of errors)
    ERROR_SUMMARY=$(grep -B2 -A5 -E "\[error\]|\[ERROR\]|exception|crash" "$TEST_LOG" 2>/dev/null | head -30)

    # Determine layer from error patterns
    LAYER="dsl"
    if echo "$ERROR_SUMMARY" | grep -qiE "TransactionStatem|DialogStatem|RFC 3261"; then
        LAYER="sip"
    elif echo "$ERROR_SUMMARY" | grep -qiE "MediaSession|Pipeline|Membrane|codec"; then
        LAYER="media"
    elif echo "$ERROR_SUMMARY" | grep -qiE "UdpListener|TcpListener|socket|Framing"; then
        LAYER="transport"
    fi

    # Create short summary
    SHORT_SUMMARY="Errors: $ERROR_COUNT, Warnings: $WARNING_COUNT, Crashes: $CRASH_COUNT"

    # Create bug report
    BUG_ID=$(bd q "[$SCRIPT_NAME] Test failure - $SHORT_SUMMARY" \
        --type bug \
        --priority 2 \
        --labels "008-dsl-sdp-negotiation,testing,$LAYER" 2>/dev/null) || BUG_ID="creation-failed"

    if [ "$BUG_ID" != "creation-failed" ] && [ -n "$BUG_ID" ]; then
        # Add detailed comment
        bd comments add "$BUG_ID" "## Test Execution Details

**Script:** \`scripts/dev/${SCRIPT_NAME}.exs\`
**Log file:** \`$TEST_LOG\`
**SIP URI:** \`sip:${SIP_URI}@127.0.0.1:5080\`

## Metrics
- Errors: $ERROR_COUNT
- Warnings: $WARNING_COUNT
- Crashes: $CRASH_COUNT

## Error Summary
\`\`\`
$ERROR_SUMMARY
\`\`\`

## To Reproduce
\`\`\`bash
./scripts/dev/run_test.sh $SCRIPT_NAME
($PJSUA_CMDS) | pjsua --null-audio --no-tcp --local-port=5100 \"sip:${SIP_URI}@127.0.0.1:5080\"
./scripts/dev/stop_test.sh <PID>
./scripts/dev/check_test.sh $TEST_LOG --verbose
\`\`\`" 2>/dev/null || true

        echo -e "${RED}  Bug created: $BUG_ID${NC}" >&2
    else
        echo -e "${RED}  Failed to create bug report${NC}" >&2
        BUG_ID="creation-failed"
    fi

    output_result "FAIL" "$BUG_ID" "$SHORT_SUMMARY (layer: $LAYER)"
    exit 1
else
    echo -e "${GREEN}[5/5] Test passed - no errors detected${NC}" >&2
    output_result "PASS" "none" "Clean run - $ERROR_COUNT errors, $WARNING_COUNT warnings"
    exit 0
fi
