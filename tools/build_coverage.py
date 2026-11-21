#!/usr/bin/env python3
"""Build the machine-readable coverage registry from the extracted schema.

Status vocabulary follows the handoff spec:
  COMPLETE / PARTIAL / RAW_ONLY / UNKNOWN / UNSUPPORTED
Editor coverage and simulation fidelity are separate fields.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

# Fields the current Godot preview actually consumes (data-driven).
WEAPON_PREVIEW = {
    "shotSpeed", "lifeSpan", "shotRadius", "IsArcing", "damageValue",
    "damageRadius", "shotDelay", "salvoCount", "salvoDelay", "shotVariance",
    "kickVeloc", "omegaTurn", "finishDist", "ammoCost", "fireSound",
    "shotSound", "explSound", "xplGround", "xplVehicle", "xplExpire",
    "renderName", "flashName", "shotGeometry", "altName",
}
TARGET_PREVIEW = {"maxHealth", "armorClass", "collisionRadius", "unitName", "geometryName", "geometryScale"}
PARTICLE_PREVIEW = {
    "renderBase", "simulateBase", "lifeTime", "animateTime", "maxCount",
    "emitVelocity", "emitVariance", "emitPosVariance", "startColor",
    "finishColor", "startRadius", "finishRadius", "rotationRate",
    "textureName", "textureBlend", "textureRate", "textureSpeed",
    "emitDelay", "emitName", "segmentLength", "segmentVariance",
    "BottomInteractsWithTerrain",
}
EDITOR_STRUCTURED = {"bool", "int", "float", "vector3", "color", "string", "reference"}


def classify(prop: dict, cls: str) -> dict:
    name = prop["name"]
    base = name.split("(")[0]
    hint = prop.get("typeHint") or "raw"
    preview = "NOT_IMPLEMENTED"
    if base in WEAPON_PREVIEW and cls in {
        "WeaponClass", "CannonClass", "OrdnanceClass", "MissileClass",
        "ExplosionClass", "ArcCannonClass", "MortarClass", "RocketClass",
        "MineClass", "LaserClass", "PopperClass", "RadarPopperClass",
    }:
        preview = "APPROXIMATED"
    elif base in TARGET_PREVIEW and cls in {"GameObjectClass", "CraftClass", "EntityClass", "BuildingClass"}:
        preview = "APPROXIMATED"
    elif base in PARTICLE_PREVIEW:
        preview = "APPROXIMATED"
    editing = "COMPLETE" if hint in EDITOR_STRUCTURED else "RAW_ONLY"
    return {
        "name": name,
        "class": cls,
        "type": hint,
        "defaultRaw": prop.get("defaultRaw"),
        "docLine": prop.get("docLine"),
        "doc": prop.get("doc"),
        "description": prop.get("description", ""),
        "parsing": "COMPLETE",
        "editing": editing,
        "preview": preview,
        "nativeVerification": "NOT_TESTED",
    }


def main() -> int:
    schema = json.loads((DATA / "odf_schema.json").read_text(encoding="utf-8"))
    particles = json.loads((DATA / "particle_schema.json").read_text(encoding="utf-8"))
    entries = []
    for cls, info in schema["classes"].items():
        for prop in info.get("properties", {}).values():
            entries.append(classify(prop, cls))
    render_entries = []
    for base, section in particles.get("renderSections", {}).items():
        for prop in section.get("properties", {}).values():
            render_entries.append(classify(prop, base))
    for base, section in particles.get("simulateSections", {}).items():
        for prop in section.get("properties", {}).values():
            render_entries.append(classify(prop, base))

    def counts(rows):
        out = {}
        for r in rows:
            for k in ("parsing", "editing", "preview", "nativeVerification"):
                out.setdefault(k, {}).setdefault(r[k], 0)
                out[k][r[k]] += 1
        return out

    payload = {
        "schemaVersion": 1,
        "generatedFrom": {
            "odf": schema.get("generatedFrom"),
            "particle": particles.get("generatedFrom"),
        },
        "note": "Coverage describes the editor, not game fidelity. Preview=APPROXIMATED means a Godot model consumes the value; it is not native verification.",
        "classes": len(schema["classes"]),
        "properties": len(entries),
        "counts": counts(entries),
        "renderBases": particles.get("renderBases", []),
        "simulateBases": particles.get("simulateBases", []),
        "renderProperties": len(render_entries),
        "renderCounts": counts(render_entries),
        "entries": entries + render_entries,
    }
    out = DATA / "coverage_registry.json"
    out.write_text(json.dumps(payload, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"classes={payload['classes']} properties={payload['properties']} renderProperties={payload['renderProperties']}")
    print(json.dumps(payload["counts"], indent=1))
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
