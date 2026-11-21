#!/usr/bin/env python3
"""Extract ODF property metadata from the local BZCC documentation.

Inputs (read-only):
  BATTLEZONE/DOCS/ODF.md
  BATTLEZONE/DOCS/PARTICLE.md

Output:
  data/odf_schema.json      classes -> properties, defaults, descriptions
  data/particle_schema.json renderBase/simulateBase inventory + properties

The extraction is evidence-based: every property records the source document
and line number it came from. Nothing is invented; unknown defaults stay null.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DOCS = Path(r"V:/___VAC/__K/__CODE/_MISC/_BZDECOMP/vrv/BATTLEZONE/DOCS")
OUT = Path(__file__).resolve().parent.parent / "data"

CLASS_LINE = re.compile(r"^([A-Za-z][A-Za-z0-9_]*Class)\s*$")
TREE_LINE = re.compile(r"\*\*Class ?Tree:\s*(.+?)\*\*")
PROP_LINE = re.compile(
    r"^\s{4}([A-Za-z_][A-Za-z0-9_\.]*(?:\([^)]*\))?)\s*=\s*(.*?)\s*$"
)
BULLET_CLASS = re.compile(r"^\s*-\s*\*\*\[([A-Za-z0-9_]+)\]\*\*")
RENDER_BASE = re.compile(r'renderBase\s*[;:]\s*"([a-z_]+)"')
SIM_LINE = re.compile(r"^\s*-\s*(sim_[a-z_]+)\s*$")


def clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def split_default(raw: str):
    """Return (default_raw, type_hint) from a documented default expression."""
    raw = raw.strip()
    if raw == "":
        return None, "string"
    if re.fullmatch(r'"[^"]*"', raw):
        return raw, "string"
    if raw.lower() in ("true", "false"):
        return raw, "bool"
    if raw.lower().startswith("0x") or re.fullmatch(r"0x[0-9A-Fa-f]+", raw):
        return raw, "hex"
    if re.fullmatch(r"-?\d+", raw):
        return raw, "int"
    if re.fullmatch(r"-?\d*\.\d+(?:[eE][-+]?\d+)?f?", raw) or re.fullmatch(
        r"-?\d+[eE][-+]?\d+f?", raw
    ):
        return raw, "float"
    if re.fullmatch(r"-?[\d\.]+(?:f?)\s+-?[\d\.]+(?:f?)\s+-?[\d\.]+(?:f?)", raw):
        return raw, "vector3"
    return raw, "raw"


def parse_odf_doc(path: Path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    classes: dict[str, dict] = {}
    current = None
    in_props = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "**ODF Properties:**":
            in_props = True
            i += 1
            continue
        m = CLASS_LINE.match(line)
        if m:
            current = m.group(1)
            classes.setdefault(
                current,
                {"name": current, "classTree": None, "description": "", "properties": {}, "source": "ODF.md"},
            )
            in_props = False
            i += 1
            continue
        if current:
            t = TREE_LINE.search(line)
            if t and not classes[current]["classTree"]:
                classes[current]["classTree"] = clean(t.group(1))
        b = BULLET_CLASS.match(line)
        if b and current:
            pass
        if current and (in_props or True):
            pm = PROP_LINE.match(line)
            if pm:
                name, default_expr = pm.group(1), pm.group(2)
                # Descriptions live in following indented lines, but stop at the
                # next property signature / class / bullet so we never eat it.
                desc_lines = []
                j = i + 1
                while j < len(lines):
                    nxt = lines[j]
                    if PROP_LINE.match(nxt) or CLASS_LINE.match(nxt) or BULLET_CLASS.match(nxt):
                        break
                    if nxt.strip() == "":
                        j += 1
                        continue
                    if nxt.startswith("    ") and not nxt.startswith("    -"):
                        desc_lines.append(nxt.strip())
                        j += 1
                        continue
                    if nxt.strip().startswith("_Note:_"):
                        desc_lines.append(nxt.strip())
                        j += 1
                        continue
                    break
                desc = clean(" ".join(desc_lines))
                default_raw, type_hint = split_default(default_expr)
                props = classes[current]["properties"]
                if name not in props:
                    props[name] = {
                        "name": name,
                        "defaultRaw": default_raw,
                        "typeHint": type_hint,
                        "description": desc,
                        "docLine": i + 1,
                        "doc": path.name,
                    }
                i += 1
                continue
        i += 1
    return classes


def parse_particle_doc(path: Path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    bases = []
    sims = []
    for i, line in enumerate(lines):
        m = RENDER_BASE.search(line)
        if m and m.group(1) not in bases:
            bases.append(m.group(1))
        sm = SIM_LINE.match(line)
        if sm and sm.group(1) not in sims:
            sims.append(sm.group(1))
    # Properties per render section: reuse the class parser keyed by renderBase.
    sections = {}
    current = None
    for i, line in enumerate(lines):
        m = RENDER_BASE.search(line)
        if m:
            current = m.group(1)
            sections.setdefault(current, {"name": current, "properties": {}})
            continue
        pm = PROP_LINE.match(line)
        if current and pm:
            name, default_expr = pm.group(1), pm.group(2)
            desc = ""
            for k in range(i + 1, min(i + 4, len(lines))):
                if lines[k].strip() and not PROP_LINE.match(lines[k]):
                    desc = clean(lines[k])
                    break
            default_raw, type_hint = split_default(default_expr)
            sections[current]["properties"].setdefault(
                name,
                {
                    "name": name,
                    "defaultRaw": default_raw,
                    "typeHint": type_hint,
                    "description": desc,
                    "docLine": i + 1,
                    "doc": path.name,
                },
            )
    sim_sections = {}
    current_sim = None
    for i, line in enumerate(lines):
        sm = SIM_LINE.match(line)
        if sm:
            current_sim = sm.group(1)
            sim_sections.setdefault(current_sim, {"name": current_sim, "properties": {}})
            continue
        pm = PROP_LINE.match(line)
        if current_sim and pm:
            name, default_expr = pm.group(1), pm.group(2)
            desc = ""
            for k in range(i + 1, min(i + 4, len(lines))):
                if lines[k].strip() and not PROP_LINE.match(lines[k]):
                    desc = clean(lines[k])
                    break
            default_raw, type_hint = split_default(default_expr)
            sim_sections[current_sim]["properties"].setdefault(
                name,
                {
                    "name": name,
                    "defaultRaw": default_raw,
                    "typeHint": type_hint,
                    "description": desc,
                    "docLine": i + 1,
                    "doc": path.name,
                },
            )
    return {
        "renderBases": bases,
        "simulateBases": sims,
        "renderSections": sections,
        "simulateSections": sim_sections,
    }


def main() -> int:
    odf_md = DOCS / "ODF.md"
    particle_md = DOCS / "PARTICLE.md"
    if not odf_md.exists():
        print(f"missing {odf_md}", file=sys.stderr)
        return 2
    classes = parse_odf_doc(odf_md)
    particles = parse_particle_doc(particle_md) if particle_md.exists() else {}
    OUT.mkdir(parents=True, exist_ok=True)
    schema = {
        "generatedFrom": str(odf_md),
        "schemaVersion": 1,
        "classes": classes,
    }
    (OUT / "odf_schema.json").write_text(
        json.dumps(schema, indent=1, ensure_ascii=False), encoding="utf-8"
    )
    (OUT / "particle_schema.json").write_text(
        json.dumps(
            {"generatedFrom": str(particle_md), "schemaVersion": 1, **particles},
            indent=1,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    prop_total = sum(len(c["properties"]) for c in classes.values())
    print(f"classes={len(classes)} properties={prop_total} renderBases={len(particles.get('renderBases', []))} simulateBases={len(particles.get('simulateBases', []))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
