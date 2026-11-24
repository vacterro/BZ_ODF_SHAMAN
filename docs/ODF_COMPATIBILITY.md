# ODF compatibility

## Parser semantics (implemented)

- One property per line, `key = value`; optional `(suffix)` on the key (`damageValue(H)`).
- Header lines `[Header]`; multiple headers in one line are supported; last header wins.
- Comments `//`, `;`, and block `/* ... */` (multi-line) are removed from the parsed code
  while remaining byte-identical in the stored text.
- Quoted strings are never split on `;` or `//`.
- Values are stored raw (exact spacing/quotes preserved); `core_value()` strips quotes for
  reading.
- Duplicate `Header/key` declarations: earlier is marked shadowed, last is effective; both
  remain in the file.
- Unknown headers and keys are editable as raw text. No unknown field is ever dropped.
- UTF-8 and UTF-16LE/BE (with BOM) are decoded; the original encoding/BOM is restored.
- CRLF and LF are preserved by splicing, not normalised.
- Parser warnings are collected for malformed lines and properties outside a header.

## Serializer

- No-op `to_bytes()` returns the original byte array (verified on all 1,478 stock ODFs).
- A single-property edit changes only the value span. If the new text has a different length,
  later spans are shifted; all other bytes are unchanged.
- `append_entry()` writes a new `key = value` line inside the chosen header section.
- Raw-editor edits replace the whole document text after explicit “Apply parsed text”.

## Inheritance

`classLabel` is resolved through the resource index. Merge order is ancestor → child; the
child's last declaration wins. Provenance is retained per value.

Properties the docs mark as **not inherited** are excluded from ancestor merging:
`GameObjectClass.unitIcon`, `GameObjectClass.unitStatus`, `GameObjectClass.ignoreMissingInf`
and `OrdnanceClass.shotRadius`. The rule is scoped to the header that documents it, so
`MorphTankClass.unitStatus` (a deployed-state override with no such note) still inherits. A
value declared by the document itself is always effective.

## Coverage

Generated registry: `data/coverage_registry.json` (from the real local `ODF.md` and
`PARTICLE.md`).

| Metric | Count |
|---|---|
| Documented classes | 128 |
| Documented ODF properties | 1,490 |
| Documented render/simulate properties | 144 |
| Parsing: COMPLETE | 1,490 / 1,490 |
| Editing: structured COMPLETE | 1,424 |
| Editing: RAW_ONLY | 66 |
| Preview: APPROXIMATED | 47 |
| Preview: NOT_IMPLEMENTED | 1,443 |
| Native verification: NOT_TESTED | all |

**Editor coverage is not simulation fidelity.** Every property is safely editable; only a
small, explicitly listed subset influences the Godot preview.

RAW_ONLY properties are those whose documented default/type could not be mapped to a control
(type `raw`, e.g. multi-property signature lines in the docs). They remain fully editable via
the exact-raw control and do not lose information.

Regenerate:

```bash
python tools/extract_schema.py
python tools/build_coverage.py
```

## Key classes exercised

| Area | Classes |
|---|---|
| Game objects | GameObject, Craft, HoverCraft, TrackedVehicle, Building, Enemy |
| Weapons | Weapon, Cannon, Missile, Mortar, ArcCannon, Mine, Popper |
| Effects | Ordnance, Explosion, ParticleRender, EmitRender, MultiRender |
| Renders | all 15 documented `renderBase` values |
| Simulation | `sim_null`, `sim_chunk`, `sim_dust`, `sim_ember`, `sim_spray`, `sim_smoke` |

## Repeated weapon slots (T-214 / PHI-28..32)

Authentic stock ODFs declare one weapon on several consecutive slots, each with
its own `weaponHardN`:

```text
ivtank:     weaponHard2=HP_GUN_1  weaponName2=gminigun_c
            weaponHard3=HP_GUN_2  weaponName3=gminigun_c
ivscout:    weaponHard1=HP_GUN_1  weaponName1=gminigun_c
            weaponHard2=HP_GUN_2  weaponName2=gminigun_c
```

`WeaponProfile` therefore groups consecutive slots that name the SAME weapon
into one weapon with several physical hardpoints, keeping the slot order, so
TANDEM fires both barrels and a different weapon name in another slot is never
dragged in. Deduplication is by resolved hardpoint node, not by weapon name.

A scan of all 1,478 stock ODFs found no case where one class header repeats the
same `weaponHardN` value on two firing slots: the repeated hardpoint names
(`hp_hand_1`, `hp_special_1`) occur across different class headers
(`GameObjectClass` vs `CraftClass`). No occurrence-aware identity is needed, and
the name-based dedup in the profile builder, volley builder and Hardpoint
Inspector is retained deliberately.

## Deliberate non-goals here

- No claim that every property is honoured by BZCC.
- No automatic normalisation of unknown values.
- No hidden rewriting of duplicate or unknown lines.
