#!/bin/bash
# The domain, data, service, playback and security layers must not depend on SwiftUI.
cd "$(dirname "$0")/.."
BAD=$(grep -rlE "^import (SwiftUI)" Sources/REDDY/Domain Sources/REDDY/Data Sources/REDDY/Services Sources/REDDY/Playback Sources/REDDY/Security 2>/dev/null)
if [ -n "$BAD" ]; then echo "✘ SwiftUI imported in lower layers:"; echo "$BAD"; exit 1; fi
echo "✔ layering OK (no SwiftUI in Domain/Data/Services/Playback/Security)"
