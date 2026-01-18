#!/bin/bash
#
# stop_test.sh - Gracefully stop a running test script
#
# Usage: ./stop_test.sh <pid> [log_file]
#
# Examples:
#   ./stop_test.sh 12345
#   ./stop_test.sh 12345 logs/test_reject_dsl_20260116_143022.log
#
# This script:
#   1. Sends SIGTERM to gracefully stop the process
#   2. Waits up to 5 seconds for graceful shutdown
#   3. Sends SIGKILL if process doesn't stop
#   4. Shows last 20 lines of log file (if provided)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Show usage
usage() {
    echo "Usage: $0 <pid> [log_file]"
    echo ""
    echo "Gracefully stop a running test script."
    echo ""
    echo "Arguments:"
    echo "  pid       Process ID of the running test script"
    echo "  log_file  Optional: Path to log file to show final output"
    echo ""
    echo "Examples:"
    echo "  $0 12345"
    echo "  $0 12345 logs/test_reject_dsl_20260116_143022.log"
    echo ""
    echo "The script sends SIGTERM first, waits up to 5 seconds,"
    echo "then sends SIGKILL if the process doesn't stop."
    exit 1
}

# Check arguments
if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

PID="$1"
LOG_FILE="${2:-}"

# Validate PID is numeric
if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid PID: $PID"
    echo "PID must be a numeric value."
    exit 1
fi

echo "========================================"
echo "Stopping test script (PID: $PID)"
echo "========================================"
echo ""

# Check if process exists
if ! kill -0 "$PID" 2>/dev/null; then
    echo "Process $PID is not running (may have already exited)"

    # Show log file anyway if provided
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Last 20 lines of log:"
        echo "----------------------------------------"
        tail -20 "$LOG_FILE"
        echo "----------------------------------------"
    fi
    exit 0
fi

# Send SIGTERM for graceful shutdown
echo "Sending SIGTERM to process $PID..."
kill -TERM "$PID" 2>/dev/null || true

# Wait for process to exit (up to 5 seconds)
WAIT_TIME=0
MAX_WAIT=5
while kill -0 "$PID" 2>/dev/null && [ $WAIT_TIME -lt $MAX_WAIT ]; do
    echo "Waiting for graceful shutdown... ($WAIT_TIME/$MAX_WAIT seconds)"
    sleep 1
    WAIT_TIME=$((WAIT_TIME + 1))
done

# Check if process is still running
if kill -0 "$PID" 2>/dev/null; then
    echo ""
    echo "Process did not stop gracefully. Sending SIGKILL..."
    kill -KILL "$PID" 2>/dev/null || true
    sleep 1

    if kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: Failed to stop process $PID"
        exit 1
    fi
fi

echo ""
echo "========================================"
echo "Process $PID stopped successfully"
echo "========================================"

# Show log file if provided
if [ -n "$LOG_FILE" ]; then
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Last 20 lines of log ($LOG_FILE):"
        echo "----------------------------------------"
        tail -20 "$LOG_FILE"
        echo "----------------------------------------"
    else
        echo ""
        echo "Warning: Log file not found: $LOG_FILE"
    fi
else
    # Try to find the most recent log file
    LATEST_LOG=$(ls -t "$PROJECT_ROOT/logs"/*.log 2>/dev/null | head -1)
    if [ -n "$LATEST_LOG" ]; then
        echo ""
        echo "Last 20 lines of most recent log ($LATEST_LOG):"
        echo "----------------------------------------"
        tail -20 "$LATEST_LOG"
        echo "----------------------------------------"
    fi
fi
