#!/bin/bash
#
# test_registrar_with_pjsua.sh - Orchestrates registrar test with full logging
#
# Usage: ./test_registrar_with_pjsua.sh [port]
#
# Examples:
#   ./test_registrar_with_pjsua.sh
#   ./test_registrar_with_pjsua.sh 5085
#
# This script:
#   1. Creates timestamped log directory in logs/registrar_TIMESTAMP/
#   2. Starts the registrar server with SIP_TRACE=true LOG_LEVEL=debug
#   3. Outputs exact pjsua commands with log file paths
#   4. Provides full observability for troubleshooting
#
# Test users (defined in test_registrar_presence.exs):
#   - alice / secret123
#   - bob   / secret456
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOGS_BASE_DIR="$PROJECT_ROOT/logs"

# Default port (can be overridden)
PORT="${1:-5080}"

# Show usage
usage() {
    echo "Usage: $0 [port]"
    echo ""
    echo "Orchestrate registrar test with full logging."
    echo ""
    echo "Arguments:"
    echo "  port    Server port (default: 5080)"
    echo ""
    echo "Examples:"
    echo "  $0           # Start on port 5080"
    echo "  $0 5085      # Start on port 5085"
    echo ""
    echo "Test users:"
    echo "  - alice / secret123"
    echo "  - bob   / secret456"
    exit 1
}

# Check for help flag
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

# Create timestamped log directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$LOGS_BASE_DIR/registrar_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

# Log file paths
SERVER_LOG="$LOG_DIR/server.log"
ALICE_LOG="$LOG_DIR/pjsua_alice.log"
BOB_LOG="$LOG_DIR/pjsua_bob.log"

# Change to project root for mix to work
cd "$PROJECT_ROOT"

echo "========================================"
echo "Parrot Registrar + Presence Test"
echo "========================================"
echo ""
echo "Starting registrar server with full logging..."
echo ""
echo "Configuration:"
echo "  Server port: $PORT"
echo "  Log directory: $LOG_DIR"
echo ""

# Start the server in background with full logging
SIP_TRACE=true LOG_LEVEL=debug nohup mix run "$SCRIPT_DIR/test_registrar_presence.exs" \
    > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for startup
echo "Waiting for server startup (3 seconds)..."
sleep 3

# Check if server started successfully
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo ""
    echo "ERROR: Server failed to start!"
    echo ""
    echo "Last 30 lines of server log:"
    echo "----------------------------------------"
    tail -30 "$SERVER_LOG" 2>/dev/null || echo "(no output)"
    echo "----------------------------------------"
    exit 1
fi

echo ""
echo "========================================"
echo "Server Started Successfully"
echo "========================================"
echo ""
echo "Server PID: $SERVER_PID"
echo ""
echo "Log Files:"
echo "  Server: $SERVER_LOG"
echo "  Alice:  $ALICE_LOG"
echo "  Bob:    $BOB_LOG"
echo ""
echo "========================================"
echo "View Live Server Logs"
echo "========================================"
echo ""
echo "tail -f $SERVER_LOG"
echo ""
echo "========================================"
echo "pjsua Commands (copy to separate terminals)"
echo "========================================"
echo ""
echo "# Terminal 2 (Alice) - registers with digest auth:"
echo "pjsua --null-audio --no-tcp --local-port=5090 \\"
echo "  --log-file=$ALICE_LOG --log-level=5 \\"
echo "  --id='sip:alice@127.0.0.1' --registrar='sip:127.0.0.1:$PORT' \\"
echo "  --realm='*' --username='alice' --password='secret123'"
echo ""
echo "# Terminal 3 (Bob) - registers and can subscribe to Alice:"
echo "pjsua --null-audio --no-tcp --local-port=5091 \\"
echo "  --log-file=$BOB_LOG --log-level=5 \\"
echo "  --id='sip:bob@127.0.0.1' --registrar='sip:127.0.0.1:$PORT' \\"
echo "  --realm='*' --username='bob' --password='secret456'"
echo ""
echo "========================================"
echo "Presence Testing Steps (in pjsua console)"
echo "========================================"
echo ""
echo "1. In Bob's console, add Alice as buddy:"
echo "   >>> +b sip:alice@127.0.0.1"
echo ""
echo "2. Subscribe to Alice's presence:"
echo "   >>> s"
echo ""
echo "3. In Alice's console, unregister:"
echo "   >>> ru"
echo "   (Bob should get NOTIFY: Alice offline)"
echo ""
echo "4. In Alice's console, re-register:"
echo "   >>> rr"
echo "   (Bob should get NOTIFY: Alice available)"
echo ""
echo "========================================"
echo "Stopping the Server"
echo "========================================"
echo ""
echo "# Graceful stop:"
echo "$SCRIPT_DIR/stop_test.sh $SERVER_PID $SERVER_LOG"
echo ""
echo "# Or simply:"
echo "kill $SERVER_PID"
echo ""
echo "========================================"
echo "Machine-Readable Output (for scripts)"
echo "========================================"
echo ""
echo "SERVER_PID=$SERVER_PID"
echo "SERVER_LOG=$SERVER_LOG"
echo "ALICE_LOG=$ALICE_LOG"
echo "BOB_LOG=$BOB_LOG"
echo "LOG_DIR=$LOG_DIR"
echo ""
echo "========================================"
echo ""
echo "Server is running. Press Ctrl+C to stop or use the kill command above."
echo ""

# Wait for the server process
# This allows Ctrl+C to stop both this script and the server
trap "echo ''; echo 'Stopping server...'; kill $SERVER_PID 2>/dev/null; echo 'Server stopped.'; exit 0" INT TERM

wait $SERVER_PID 2>/dev/null || true

echo ""
echo "Server exited. Check logs at: $LOG_DIR"
