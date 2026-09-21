#!/bin/bash
set -euo pipefail

BUNDLE_ID="com.ali.dodoma"

# tccutil exits non-zero when it cannot reset a grant. Swallowing that with
# `|| true` and then printing success regardless hides the only outcome that
# needs acting on: a grant still standing after the script said it was gone.
STATUS=0
for service in Accessibility ListenEvent; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "$service: reset"
    else
        echo "$service: FAILED to reset for $BUNDLE_ID" >&2
        STATUS=1
    fi
done

if [ "$STATUS" -eq 0 ]; then
    echo "Accessibility and Input Monitoring grants reset for $BUNDLE_ID."
else
    echo "Reset the remaining grants by hand under System Settings > Privacy &" >&2
    echo "Security > Accessibility and > Input Monitoring." >&2
fi

exit "$STATUS"
