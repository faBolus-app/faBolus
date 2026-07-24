#!/usr/bin/env python3
"""GA-07: validate representative host-emitted payloads against command.schema.json.

The old drift check compared property NAMES only, so an enum could drift (e.g. the host emits a
screen id or a bolus status the schema forbids) while CI stayed green. This validates the FULL
payload the host actually emits — type, enum membership, required keys, array item enums, and
additionalProperties:false — against the schema. It uses `jsonschema` when installed, else a small
built-in validator covering exactly the constructs this schema uses (type/const/enum/required/
properties/items/minimum/minLength/additionalProperties).

The sample payloads mirror what `RemoteCommand.encoded()` (Swift host) and the Garmin/Watch remotes
put on the wire, including the FB-02 `unknown` status and the glucose/clock/bolusonly screens. A
deliberately malformed payload is included as a self-test so a broken validator can't pass silently.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(ROOT, "schema", "command.schema.json")

with open(SCHEMA_PATH) as f:
    SCHEMA = json.load(f)

# --- Representative VALID payloads (must pass) ------------------------------------------------
VALID = [
    # Full statusRead reply: every field, incl. the new screens + 'unknown' status.
    {
        "version": 1, "kind": "statusRead", "requestId": "r1",
        "status": "unknown", "message": "Outcome unknown — check pump history.",
        "trend": "flat", "bgMgdl": 120, "glucoseAgeSec": 60,
        "history": [100, 110, 120], "alerts": [{"id": 1, "kind": 1, "title": "Low insulin"}],
        "lastBolusUnits": 1.0, "reservoirUnits": 100, "batteryPercent": 80,
        "carbRatio": 10, "isf": 40, "targetBg": 110, "maxBolusUnits": 25,
        "bolusMode": "carbs", "bolusIncrement": 0.05, "carbIncrement": 5,
        "screenOrder": ["glance", "glucose", "clock", "bolusonly", "alerts", "history", "details"],
        "defaultScreen": "clock",
        "glucoseStaleMinutes": 6, "glucoseHideDelayMinutes": 0,
        "detailsOrder": ["iob", "reservoir", "cgm"], "watchChartRanges": [3, 6, 12, 24],
        "garminComplicationDisplay": "stringTrend", "remotesReadOnly": False,
    },
    {"version": 1, "kind": "bolusRequest", "requestId": "r2", "units": 2.5},
    {"version": 1, "kind": "bolusRequest", "requestId": "r3", "carbsGrams": 30, "bgMgdl": 120, "remoteEstimateUnits": 3.0},
    {"version": 1, "kind": "bolusStatus", "requestId": "r4", "status": "unknown", "message": "Outcome unknown"},
    {"version": 1, "kind": "bolusStatus", "requestId": "r5", "status": "cancelled", "deliveredUnits": 0.5},
    {"version": 1, "kind": "cancelBolus", "requestId": "r6"},
    {"version": 1, "kind": "dismissAlert", "requestId": "r7", "alertId": 3, "alertKind": 1},
    {"version": 1, "kind": "suspendPump", "requestId": "r8"},
]

# --- Deliberately INVALID payloads (must be rejected) ----------------------------------------
INVALID = [
    {"version": 1, "kind": "bolusRequest", "requestId": "b1", "screenOrder": ["banana"]},   # bad enum item
    {"version": 1, "kind": "bolusStatus", "requestId": "b2", "status": "teleported"},        # bad status enum
    {"version": 2, "kind": "statusRead", "requestId": "b3"},                                  # bad const version
    {"version": 1, "kind": "statusRead", "requestId": "b4", "bgMgdl": "high"},                # wrong type
    {"version": 1, "kind": "statusRead", "requestId": "b5", "surpriseKey": 1},                # additionalProperties
    {"version": 1, "kind": "statusRead"},                                                     # missing required requestId
]


def _validate(obj, schema, path="$"):
    """Minimal draft-2020-12 validator covering the constructs this schema uses. Returns [errors]."""
    errs = []
    t = schema.get("type")
    if t == "object":
        if not isinstance(obj, dict):
            return [f"{path}: expected object"]
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in obj:
                errs.append(f"{path}: missing required '{req}'")
        if schema.get("additionalProperties", True) is False:
            for k in obj:
                if k not in props:
                    errs.append(f"{path}: unexpected property '{k}'")
        for k, v in obj.items():
            if k in props:
                errs += _validate(v, props[k], f"{path}.{k}")
        return errs
    if t == "array":
        if not isinstance(obj, list):
            return [f"{path}: expected array"]
        item_schema = schema.get("items")
        if item_schema:
            for i, e in enumerate(obj):
                errs += _validate(e, item_schema, f"{path}[{i}]")
        return errs
    # scalars
    if "const" in schema and obj != schema["const"]:
        errs.append(f"{path}: expected const {schema['const']!r}, got {obj!r}")
    if "enum" in schema and obj not in schema["enum"]:
        errs.append(f"{path}: {obj!r} not in enum {schema['enum']}")
    if t == "integer" and not (isinstance(obj, int) and not isinstance(obj, bool)):
        errs.append(f"{path}: expected integer, got {type(obj).__name__}")
    if t == "number" and (isinstance(obj, bool) or not isinstance(obj, (int, float))):
        errs.append(f"{path}: expected number, got {type(obj).__name__}")
    if t == "string" and not isinstance(obj, str):
        errs.append(f"{path}: expected string, got {type(obj).__name__}")
    if t == "boolean" and not isinstance(obj, bool):
        errs.append(f"{path}: expected boolean, got {type(obj).__name__}")
    if "minimum" in schema and isinstance(obj, (int, float)) and not isinstance(obj, bool) and obj < schema["minimum"]:
        errs.append(f"{path}: {obj} < minimum {schema['minimum']}")
    if "minLength" in schema and isinstance(obj, str) and len(obj) < schema["minLength"]:
        errs.append(f"{path}: string shorter than minLength {schema['minLength']}")
    return errs


# Prefer the real jsonschema lib when present; fall back to the built-in validator otherwise.
try:
    import jsonschema  # type: ignore

    def validate(obj):
        try:
            jsonschema.validate(obj, SCHEMA)
            return []
        except jsonschema.ValidationError as e:  # pragma: no cover
            return [str(e.message)]

    ENGINE = "jsonschema"
except ImportError:
    def validate(obj):
        return _validate(obj, SCHEMA)

    ENGINE = "built-in"


def main():
    failed = 0
    for p in VALID:
        errs = validate(p)
        if errs:
            failed = 1
            print(f"❌ VALID payload ({p['kind']}) was rejected: {errs}")
    for p in INVALID:
        if not validate(p):
            failed = 1
            print(f"❌ INVALID payload was accepted (validator too weak): {p}")
    if failed:
        print("❌ Payload schema validation failed.")
        sys.exit(1)
    print(f"✅ Payload schema validation passed ({len(VALID)} valid + {len(INVALID)} rejected, engine: {ENGINE}).")


if __name__ == "__main__":
    main()
