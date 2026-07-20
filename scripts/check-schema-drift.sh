#!/usr/bin/env bash
# Fails if the Swift RemoteCommand mirror drifts from the source-of-truth schema
# (schema/command.schema.json). Every property in the schema must appear as a field in
# RemoteCommand.swift. The Monkey C mirror (RemoteCommand.mc) lives in the faBolusGarmin repo and
# is checked by that repo's CI.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMA="schema/command.schema.json"
SWIFT="Packages/faBolusCore/Sources/faBolusCore/RemoteCommand.swift"

missing=0
for key in $(python3 -c "import json,sys; print('\n'.join(json.load(open('$SCHEMA'))['properties'].keys()))"); do
  if ! grep -q "var ${key}\b" "$SWIFT"; then
    echo "DRIFT: schema property '${key}' has no matching field in RemoteCommand.swift"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "❌ RemoteCommand.swift is out of sync with $SCHEMA. Update both (and the Monkey C mirror in faBolusGarmin)."
  exit 1
fi
echo "✅ RemoteCommand.swift matches $SCHEMA ($(python3 -c "import json;print(len(json.load(open('$SCHEMA'))['properties']))") properties)."
