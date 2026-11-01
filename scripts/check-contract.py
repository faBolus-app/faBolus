#!/usr/bin/env python3
"""Check the phone↔remote contract files.

Every version 2 golden fixture must validate against contract/schema.json, every version 1 fixture must
not, and a few broken messages must be refused, so a validator that passes everything can't go unnoticed.
Swift's own test (GoldenFixtureTests) checks that the fixtures are what the Swift types encode to; this
checks the schema says the same, for remotes built from the schema alone.

The validator covers exactly the JSON Schema keywords the schema uses.
"""
import copy
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT = os.path.join(ROOT, "Packages", "RemoteProtocol", "contract")
SCHEMA = json.load(open(os.path.join(CONTRACT, "schema.json"), encoding="utf-8"))


def kind_of(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return "null"


def errors(value, schema, path="$"):
    if "$ref" in schema:
        name = schema["$ref"].split("/")[-1]
        return errors(value, SCHEMA["$defs"][name], path)
    out = []
    if "type" in schema and kind_of(value) != schema["type"]:
        return [f"{path}: expected {schema['type']}, got {kind_of(value)}"]
    if "const" in schema and value != schema["const"]:
        out.append(f"{path}: expected {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        out.append(f"{path}: {value!r} not in {schema['enum']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            out.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            out.append(f"{path}: above {schema['maximum']}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            out.append(f"{path}: too short")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            out.append(f"{path}: too long")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            out.append(f"{path}: doesn't match {schema['pattern']}")
    if isinstance(value, list):
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            out.append(f"{path}: too many items")
        if len(value) < schema.get("minItems", 0):
            out.append(f"{path}: too few items")
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            out.append(f"{path}: duplicate items")
        for i, v in enumerate(value):
            out += errors(v, schema.get("items", {}), f"{path}[{i}]")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                out.append(f"{path}: missing {key}")
        for key, v in value.items():
            if key in props:
                out += errors(v, props[key], f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                out.append(f"{path}: unexpected {key}")
    if "oneOf" in schema:
        matches = [s for s in schema["oneOf"] if not errors(value, s, path)]
        if len(matches) != 1:
            out.append(f"{path}: matches {len(matches)} of oneOf, not exactly 1")
    return out


def main():
    failed = False
    fixtures = os.path.join(CONTRACT, "fixtures")
    v2 = {}
    for name in sorted(os.listdir(fixtures)):
        message = json.load(open(os.path.join(fixtures, name), encoding="utf-8"))
        problems = errors(message, SCHEMA)
        if message.get("version") == 2:
            v2[name] = message
            if problems:
                failed = True
                print(f"FAIL {name}:", *problems, sep="\n  ")
        elif not problems:
            failed = True
            print(f"FAIL {name}: a version 1 message passed the version 2 schema")

    # Broken messages the schema must refuse.
    broken = []
    m = copy.deepcopy(v2["bolus-units.json"])
    m["payload"]["mU"] = 2.5
    broken.append(("float insulin", m))
    m = copy.deepcopy(v2["bolus-carbs.json"])
    del m["payload"]["estimateMU"]
    broken.append(("carbs without an estimate", m))
    m = copy.deepcopy(v2["status.json"])
    m["payload"]["pumpLink"] = "teleporting"
    broken.append(("unknown token", m))
    m = copy.deepcopy(v2["status.json"])
    m["payload"]["extra"] = 1
    broken.append(("unexpected field", m))
    m = copy.deepcopy(v2["config.json"])
    m["payload"]["screens"]["order"] = ["glance", "glance"]
    broken.append(("duplicate screens", m))
    m = copy.deepcopy(v2["poll.json"])
    m["kind"] = "statusRead"
    broken.append(("version 1 kind", m))
    for label, message in broken:
        if not errors(message, SCHEMA):
            failed = True
            print(f"FAIL self-test: {label} passed the schema")

    if failed:
        sys.exit(1)
    print(f"✅ contract: {len(v2)} version 2 fixtures match schema.json; {len(broken)} broken messages refused")


main()
