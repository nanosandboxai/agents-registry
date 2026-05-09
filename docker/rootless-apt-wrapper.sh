#!/bin/sh
# Rootless apt-get/apt wrapper for nanosandbox code agents.
#
# Forwards package manager commands to agent-gateway's /api/v1/pkg/install
# endpoint, which runs them as root. No sudo needed.
#
# This wrapper is placed at /usr/local/bin/apt-get and /usr/local/bin/apt,
# taking PATH precedence over /usr/bin/apt-get and /usr/bin/apt.

CMD="$(basename "$0")"

# Build JSON args array
ARGS_JSON="["
FIRST=true
for arg in "$@"; do
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        ARGS_JSON="$ARGS_JSON,"
    fi
    # Escape quotes in arg
    escaped=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    ARGS_JSON="$ARGS_JSON\"$escaped\""
done
ARGS_JSON="$ARGS_JSON]"

RESPONSE=$(curl -s -X POST http://localhost:8080/api/v1/pkg/install \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"$CMD\",\"args\":$ARGS_JSON}" 2>&1)

if [ $? -ne 0 ]; then
    echo "Error: agent-gateway not reachable" >&2
    exit 1
fi

# Extract output and exit code from JSON response
OUTPUT=$(printf '%s' "$RESPONSE" | sed -n 's/.*"output":"\(.*\)","exit_code".*/\1/p; s/.*"output":"\(.*\)".*/\1/p' | head -1)
EXIT_CODE=$(printf '%s' "$RESPONSE" | sed -n 's/.*"exit_code":\([0-9]*\).*/\1/p')

# Print output (unescape JSON string)
printf '%s' "$RESPONSE" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('output',''), end='')" 2>/dev/null \
    || printf '%s\n' "$OUTPUT"

exit "${EXIT_CODE:-1}"
