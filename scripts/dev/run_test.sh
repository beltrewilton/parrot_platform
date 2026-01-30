#!/bin/bash
#
# run_test.sh - Start a dev test script in background with logging
#
# Usage: ./run_test.sh <script_name> [port]
#
# Examples:
#   ./run_test.sh test_reject_dsl
#   ./run_test.sh test_reject_dsl 5090
#
# This script:
#   1. Creates timestamped log file in logs/
#   2. Starts the Elixir script in background with SIP_TRACE=true LOG_LEVEL=debug
#   3. Waits for startup (3 seconds)
#   4. Outputs the log file path and PID for later use
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"

# Show usage
usage() {
    echo "Usage: $0 <script_name> [port]"
    echo ""
    echo "Start a dev test script in background with logging."
    echo ""
    echo "Arguments:"
    echo "  script_name  Name of the test script (without .exs extension)"
    echo "               e.g., test_reject_dsl, test_dtmf_dsl, test_answer_play"
    echo "  port         Optional: Override default port (default: 5080)"
    echo ""
    echo "Examples:"
    echo "  $0 test_reject_dsl"
    echo "  $0 test_dtmf_dsl 5090"
    echo ""
    echo "Available test scripts:"
    ls -1 "$SCRIPT_DIR"/*.exs 2>/dev/null | xargs -I {} basename {} .exs | sed 's/^/  /'
    echo ""
    echo "Output:"
    echo "  - Creates timestamped log in logs/"
    echo "  - Prints PID and log file path"
    echo "  - Use stop_test.sh <pid> to stop"
    exit 1
}

# Check arguments
if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

SCRIPT_NAME="$1"
SCRIPT_FILE="$SCRIPT_DIR/${SCRIPT_NAME}.exs"

# Validate script exists
if [ ! -f "$SCRIPT_FILE" ]; then
    echo "Error: Script not found: $SCRIPT_FILE"
    echo ""
    echo "Available test scripts:"
    ls -1 "$SCRIPT_DIR"/*.exs 2>/dev/null | xargs -I {} basename {} .exs | sed 's/^/  /'
    exit 1
fi

# Create logs directory if it doesn't exist
mkdir -p "$LOGS_DIR"

# Generate timestamped log file name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS_DIR/${SCRIPT_NAME}_${TIMESTAMP}.log"

# Change to project root for mix to work
cd "$PROJECT_ROOT"

echo "========================================"
echo "Starting test script: $SCRIPT_NAME"
echo "========================================"
echo ""
echo "Script:   $SCRIPT_FILE"
echo "Log file: $LOG_FILE"
echo ""

# Start the script in background with logging
# Use setsid to create new session, ensuring process is not terminated when
# parent shell exits (fixes timing issues when called via subshell)
SIP_TRACE=true LOG_LEVEL=debug setsid mix run "$SCRIPT_FILE" > "$LOG_FILE" 2>&1 &
PID=$!
disown $PID 2>/dev/null || true

echo "PID:      $PID"
echo ""
echo "Waiting for startup (3 seconds)..."
sleep 3

# Check if process is still running
if kill -0 $PID 2>/dev/null; then
    echo ""
    echo "========================================"
    echo "Test script started successfully!"
    echo "========================================"
    echo ""
    echo "PID:      $PID"
    echo "Log file: $LOG_FILE"
    echo ""
    echo "Commands:"
    echo "  View live logs:    tail -f $LOG_FILE"
    echo "  Stop script:       $SCRIPT_DIR/stop_test.sh $PID"
    echo "  Check results:     $SCRIPT_DIR/check_test.sh $LOG_FILE"
    echo ""
    echo "========================================"

    # Output machine-readable info for scripting
    echo ""
    echo "# Machine-readable output (for subagents):"
    echo "TEST_PID=$PID"
    echo "TEST_LOG=$LOG_FILE"
else
    echo ""
    echo "ERROR: Process exited immediately!"
    echo ""
    echo "Last 20 lines of log:"
    echo "----------------------------------------"
    tail -20 "$LOG_FILE" 2>/dev/null || echo "(no output)"
    echo "----------------------------------------"
    exit 1
fi
