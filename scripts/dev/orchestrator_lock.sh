#!/bin/bash
#
# orchestrator_lock.sh - Coordinate multiple orchestrators via bd
#
# Usage:
#   ./orchestrator_lock.sh acquire <test_name> <orchestrator_id>
#   ./orchestrator_lock.sh release <test_name> <orchestrator_id>
#   ./orchestrator_lock.sh check <test_name>
#   ./orchestrator_lock.sh list
#
# Examples:
#   ./orchestrator_lock.sh acquire test_answer_play agent-123
#   ./orchestrator_lock.sh release test_answer_play agent-123
#   ./orchestrator_lock.sh check test_answer_play
#   ./orchestrator_lock.sh list
#
# Exit codes:
#   0 - Success (acquired, released, or not locked)
#   1 - Lock held by another orchestrator
#   2 - Invalid arguments
#

set -o pipefail

ACTION="${1:-}"
TEST_NAME="${2:-}"
ORCHESTRATOR_ID="${3:-$(whoami)-$$}"

LOCK_LABEL="orchestrator-lock"

usage() {
    echo "Usage: $0 <action> <test_name> [orchestrator_id]"
    echo ""
    echo "Actions:"
    echo "  acquire  - Acquire lock for test (fails if already locked)"
    echo "  release  - Release lock for test"
    echo "  check    - Check if test is locked (returns lock holder)"
    echo "  list     - List all current locks"
    echo ""
    echo "Examples:"
    echo "  $0 acquire test_answer_play"
    echo "  $0 release test_answer_play"
    echo "  $0 check test_answer_play"
    echo "  $0 list"
    exit 2
}

# Find existing lock for a test
find_lock() {
    local test="$1"
    bd search "lock:$test" --label "$LOCK_LABEL" --status open --json 2>/dev/null | \
        jq -r '.[0].id // empty' 2>/dev/null
}

# Get lock holder (extracted from title: "lock:test_name (orchestrator_id)")
get_lock_holder() {
    local test="$1"
    bd search "lock:$test" --label "$LOCK_LABEL" --status open --json 2>/dev/null | \
        jq -r '.[0].title // empty' 2>/dev/null | \
        sed -n 's/.*(\(.*\))/\1/p'
}

case "$ACTION" in
    acquire)
        if [ -z "$TEST_NAME" ]; then
            usage
        fi

        # Check if already locked
        EXISTING=$(find_lock "$TEST_NAME")
        if [ -n "$EXISTING" ]; then
            HOLDER=$(get_lock_holder "$TEST_NAME")
            echo "LOCKED by $HOLDER (issue: $EXISTING)"
            exit 1
        fi

        # Create lock
        # Note: bd q doesn't support --assignee or --description
        # Include orchestrator ID in title instead
        LOCK_ID=$(bd q "lock:$TEST_NAME ($ORCHESTRATOR_ID)" \
            --type task \
            --priority 0 \
            --labels "$LOCK_LABEL,test-coordination" \
            2>/dev/null)

        if [ -n "$LOCK_ID" ]; then
            echo "ACQUIRED $LOCK_ID"
            exit 0
        else
            echo "FAILED to acquire lock"
            exit 1
        fi
        ;;

    release)
        if [ -z "$TEST_NAME" ]; then
            usage
        fi

        EXISTING=$(find_lock "$TEST_NAME")
        if [ -z "$EXISTING" ]; then
            echo "NO_LOCK (nothing to release)"
            exit 0
        fi

        # Close the lock
        bd close "$EXISTING" --reason "Released by $ORCHESTRATOR_ID" 2>/dev/null
        echo "RELEASED $EXISTING"
        exit 0
        ;;

    check)
        if [ -z "$TEST_NAME" ]; then
            usage
        fi

        EXISTING=$(find_lock "$TEST_NAME")
        if [ -n "$EXISTING" ]; then
            HOLDER=$(get_lock_holder "$TEST_NAME")
            echo "LOCKED by $HOLDER (issue: $EXISTING)"
            exit 1
        else
            echo "AVAILABLE"
            exit 0
        fi
        ;;

    list)
        echo "Current orchestrator locks:"
        bd list --label "$LOCK_LABEL" --status open --json 2>/dev/null | \
            jq -r '.[] | "  \(.title)"' 2>/dev/null || \
            echo "  (none)"
        exit 0
        ;;

    *)
        usage
        ;;
esac
