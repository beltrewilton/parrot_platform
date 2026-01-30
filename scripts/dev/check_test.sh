#!/bin/bash
#
# check_test.sh - Analyze test log file for errors and key events
#
# Usage: ./check_test.sh <log_file> [--verbose]
#
# Examples:
#   ./check_test.sh logs/test_reject_dsl_20260116_143022.log
#   ./check_test.sh logs/test_reject_dsl_20260116_143022.log --verbose
#
# This script:
#   1. Counts errors and warnings
#   2. Identifies key SIP events (INVITE, BYE, responses)
#   3. Returns exit code 0 for clean, 1 for errors found
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Show usage
usage() {
    echo "Usage: $0 <log_file> [--verbose]"
    echo ""
    echo "Analyze test log file for errors and key events."
    echo ""
    echo "Arguments:"
    echo "  log_file   Path to the log file to analyze"
    echo "  --verbose  Show detailed output including sample errors/warnings"
    echo ""
    echo "Examples:"
    echo "  $0 logs/test_reject_dsl_20260116_143022.log"
    echo "  $0 logs/test_reject_dsl_20260116_143022.log --verbose"
    echo ""
    echo "Exit codes:"
    echo "  0  - Clean (no errors found)"
    echo "  1  - Errors found"
    echo "  2  - Log file not found or invalid arguments"
    echo ""
    echo "Available log files:"
    ls -1t "$PROJECT_ROOT/logs"/*.log 2>/dev/null | head -10 | sed 's/^/  /'
    exit 2
}

# Check arguments
if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

LOG_FILE="$1"
VERBOSE=false

if [ "$2" = "--verbose" ]; then
    VERBOSE=true
fi

# Handle relative paths
if [[ ! "$LOG_FILE" = /* ]]; then
    LOG_FILE="$PROJECT_ROOT/$LOG_FILE"
fi

# Validate log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    echo ""
    echo "Available log files:"
    ls -1t "$PROJECT_ROOT/logs"/*.log 2>/dev/null | head -10 | sed 's/^/  /'
    exit 2
fi

echo "========================================"
echo "Test Log Analysis"
echo "========================================"
echo ""
echo "Log file: $LOG_FILE"
echo "Size:     $(du -h "$LOG_FILE" | cut -f1)"
echo "Lines:    $(wc -l < "$LOG_FILE" | tr -d ' ')"
echo ""

# Count errors and warnings (case-insensitive)
ERROR_COUNT=$(grep -ci '\[error\]' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
WARNING_COUNT=$(grep -ci '\[warning\]' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
CRASH_COUNT=$(grep -ci 'crash\|exception\|** (.*Error)' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")

# Count SIP events
INVITE_COUNT=$(grep -ci 'INVITE' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
BYE_COUNT=$(grep -ci 'BYE' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
ACK_COUNT=$(grep -ci 'ACK' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
RESPONSE_200=$(grep -c '200 OK\|SIP/2.0 200' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
RESPONSE_4XX=$(grep -cE 'SIP/2\.0 4[0-9]{2}|[[:space:]]4[0-9]{2}[[:space:]]' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
RESPONSE_5XX=$(grep -cE 'SIP/2\.0 5[0-9]{2}|[[:space:]]5[0-9]{2}[[:space:]]' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")

# Check for media events
MEDIA_START=$(grep -ci 'media.*start\|start.*media\|pipeline.*start' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
MEDIA_STOP=$(grep -ci 'media.*stop\|stop.*media\|pipeline.*stop' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
DTMF_COUNT=$(grep -ci 'dtmf\|digit' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")

# Check for specific success/failure patterns
SERVER_STARTED=$(grep -ci 'listening\|started\|server.*port' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")
CALL_COMPLETED=$(grep -ci 'call.*completed\|dialog.*terminated\|call.*ended' "$LOG_FILE" 2>/dev/null | head -1 || echo "0")

echo "========================================"
echo "Error/Warning Summary"
echo "========================================"
echo ""
echo "  Errors:    $ERROR_COUNT"
echo "  Warnings:  $WARNING_COUNT"
echo "  Crashes:   $CRASH_COUNT"
echo ""

echo "========================================"
echo "SIP Event Summary"
echo "========================================"
echo ""
echo "  INVITEs:       $INVITE_COUNT"
echo "  ACKs:          $ACK_COUNT"
echo "  BYEs:          $BYE_COUNT"
echo "  200 OK:        $RESPONSE_200"
echo "  4xx responses: $RESPONSE_4XX"
echo "  5xx responses: $RESPONSE_5XX"
echo ""

echo "========================================"
echo "Media Event Summary"
echo "========================================"
echo ""
echo "  Media starts:  $MEDIA_START"
echo "  Media stops:   $MEDIA_STOP"
echo "  DTMF events:   $DTMF_COUNT"
echo ""

echo "========================================"
echo "Status Indicators"
echo "========================================"
echo ""
echo "  Server started:   $([ "$SERVER_STARTED" -gt 0 ] && echo "YES" || echo "NO")"
echo "  Calls completed:  $([ "$CALL_COMPLETED" -gt 0 ] && echo "YES ($CALL_COMPLETED)" || echo "NO")"
echo ""

# Verbose output - show sample errors/warnings
if [ "$VERBOSE" = true ]; then
    echo "========================================"
    echo "Sample Errors (first 5)"
    echo "========================================"
    echo ""
    grep -i '\[error\]' "$LOG_FILE" 2>/dev/null | head -5 || echo "(no errors)"
    echo ""

    echo "========================================"
    echo "Sample Warnings (first 5)"
    echo "========================================"
    echo ""
    grep -i '\[warning\]' "$LOG_FILE" 2>/dev/null | head -5 || echo "(no warnings)"
    echo ""

    if [ "$CRASH_COUNT" -gt 0 ]; then
        echo "========================================"
        echo "Crash/Exception Details"
        echo "========================================"
        echo ""
        grep -iA3 'crash\|exception\|** (.*Error)' "$LOG_FILE" 2>/dev/null | head -20
        echo ""
    fi
fi

# Final status
echo "========================================"
echo "Overall Status"
echo "========================================"
echo ""

HAS_ERRORS=false

if [ "$ERROR_COUNT" -gt 0 ]; then
    HAS_ERRORS=true
    echo "ERRORS FOUND: $ERROR_COUNT error(s) detected"
fi

if [ "$CRASH_COUNT" -gt 0 ]; then
    HAS_ERRORS=true
    echo "CRASHES FOUND: $CRASH_COUNT crash(es) detected"
fi

if [ "$RESPONSE_5XX" -gt 0 ]; then
    HAS_ERRORS=true
    echo "SERVER ERRORS: $RESPONSE_5XX 5xx response(s) detected"
fi

if [ "$HAS_ERRORS" = true ]; then
    echo ""
    echo "STATUS: FAILED - Review errors above"
    echo ""
    echo "Run with --verbose for more details:"
    echo "  $0 $LOG_FILE --verbose"
    exit 1
else
    echo "STATUS: CLEAN - No errors detected"

    # Provide helpful summary
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo ""
        echo "Note: $WARNING_COUNT warning(s) found (not failures)"
    fi
    exit 0
fi
