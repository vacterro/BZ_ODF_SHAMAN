# Particle graph and preview

## Loaded vocabulary

The registry is extracted from the local `PARTICLE.md`:

**Render bases (15):** `draw_null`, `draw_emit`, `draw_multi`, `draw_bolt`, `draw_geom`,
`draw_light`, `draw_planar`, `draw_sphere`, `draw_sprite`, `draw_static`, `draw_tracer`,
`draw_trail`, `draw_twirl`, `draw_twirl_trail`, `draw_wave`.

**Simulate bases (6):** `sim_null`, `sim_chunk`, `sim_dust`, `sim_ember`, `sim_spray`,
`sim_smoke`.

`draw_billboard` is **not** listed: it is not in the local documentation registry and was not
observed as a supported base in indexed stock data. It is not silently accepted; an unknown
base remains editable as raw text and is displayed verbatim.

## Graph construction

`ParticleLab.load_document()`:

1. Finds every unique render header declaring `renderBase` or `simulateBase`.
2. Creates one `GraphNode` per header showing base, simulate base and selected values. A name
   that occurs in more than one physical header is one merged node, titled `merged ×N`; the
   values shown are the effective (last) occurrence.
3. Draws edges for `emitName` and `renderName1..N` references that resolve to a header in the
   same ODF.
4. Resolves `file.header` references through the resource index, relative to the referring ODF
   (same package, then base game, then other mods), and draws them as separate external nodes.
   Missing files and missing headers are rejected instead of guessed.

Each `GraphNode` now has one direct child `Control` per slot: slot 0 is the input, and one output
port backs each physical reference key (`emitName`, `renderName1..N`) plus a distinct `+ ADD`
port for the next free key. Godot derives graph slots from direct children, so the visible port
count and the ODF reference count can no longer diverge. Edges attach to the exact source port,
and parallel references to the same target remain separately selectable.

The graph is editable. Dragging from an empty `+ ADD` port writes the next free reference key;
dragging from an occupied physical port never silently creates another property, it selects the
existing one and asks for an explicit reconnect. Disconnecting removes that property line; the
reference fields in each node are editable. If a visual edge cannot be tied to a physical ODF
entry, the ODF is preserved and the visual graph is rebuilt instead of falsely disconnecting.
Changes go through the shared `OdfDocument`, so the inspector, sources and exporter see the
same revision. GraphNode output-port indices are converted from physical slot indices through
`GraphNode.get_output_port_slot()`; the verifiers use the real port-to-slot-to-child metadata
chain instead of assuming slot numbers equal port numbers.

External `file.header` edges use the same physical port identity. Mouse selection, Disconnect,
Reconnect, Move/Swap/Replace and copy/paste carry a typed target (`local` header or canonical
external path plus external header), so an external reference is never collapsed into a local
header name. Free Move transfers the exact source reference value, Swap exchanges the two exact
values, and Replace writes the full external value at the occupied destination. Reconnect resolves
the target through the active resource index and writes the verbatim `file.header` value even when
the external target has no visual node yet or a local header has the same name. Occupied-port
selection uses the same typed identity, keeping external edges selected for Reconnect. External
files are never modified.

## Header operations

- `DUPLICATE NODE` copies one physical header occurrence into a new header at EOF and selects
  it. Only local property/comment lines from that occurrence are copied; inherited values are
  not flattened.
- `DELETE NODE` removes one unreferenced physical occurrence. Referenced headers and the last
  remaining render header are protected.
- `UNDO`/`REDO` use the document history, so a delete restores the exact previous text.
- Duplicate names are tracked by physical occurrence id: removing one `[A]` never removes a
  later `[A]` or a section between them.
- Connections to a node itself and connections that would close a cycle are refused.
- Node positions are cosmetic and persist per source path in
  `workspace/graph_layout.json`; ODF content is never stored there.
- Empty headers insert a new property inside the header's own physical range.

External nodes carry the resolved path, live external header preview fields (`DIRTY`/`OVERRIDE`
status tags), and an `OPEN` button; pressing it opens that ODF in the main editor. Editing a
referenced external ODF immediately refreshes the Particle Lab live 3D preview
(`refresh_if_depends_on()`), and the toolbar `SAVE DEPENDENCIES` button (with live dirty count
badge) calls `save_with_external_dependencies()` to coordinate workspace saves across the active
render ODF and dirty external `file.header` dependencies without touching original Workshop/game
files. `SAVE DEPENDENCIES` now uses a verified write-ahead journal: transaction intent is persisted
and read back before the first document write, each committed document is recorded before the next
one starts, and the final status is `COMPLETE`, `PARTIAL_SAVE_RECOVERABLE` or `RECOVERY_PENDING`.
`discover_incomplete_save_groups()` finds interrupted groups after a restart; recovery restores the
previous override byte-for-byte and writes a separate working-copy artifact preserving unsaved
edits, encoding, BOM, comments and whitespace. Direct file-edit edits are detected as
`RECOVERY_CONFLICT` instead of being overwritten.
Disconnect/paste report honest batch outcomes in `last_graph_batch`, and `document_edited` is emitted
only when ODF bytes actually changed. P1-07/T-27 graph operations include multi-selection, copy/paste, subgraph duplication with
automatic internal edge remapping, compound undo/redo (`OdfDocument.begin_compound`/`end_compound`),
live node search filtering, reusable documented emitter presets (`fireball`, `sparks`, `beam_bolt`,
`smoke_trail`, `flash_light`), and a quick render property inspector. Node creation writes only
documented values (`NEW NODE` → `draw_sprite` template), and `RENAME` renames every physical
occurrence and rewrites local references to the new name in one compound undoable step.

## ODF → preview mapping (APPROXIMATED)

| ODF field | Preview mapping |
|---|---|
| `renderBase` | chooses whether a CPUParticles3D emitter is created (`draw_null` skipped) |
| `simulateBase` | gravity: chunk/ember/spray → −9.8; null/dust/smoke → 0 |
| `lifeTime` / `lifeSpan` | particle lifetime (clamped 0.1–30 s) |
| `maxCount` | particle amount (clamped 8–256) |
| `emitVelocity` | initial velocity range (0.5×–1.5× magnitude) |
| `emitVariance` | spread angle (length × 18°, clamped 0–180°) |
| `startRadius`/`finishRadius` | particle scale |
| `startColor`/`finishColor` | gradient ramp (0–255 or 0–1 interpreted) |
| `textureName` | resolved via the asset index, loaded with `Image.load_from_file` if possible |

Not modelled: exact engine `draw_trail`/`draw_twirl_trail` ribbon geometry, LOD culling, `maxCount` global culling, `emitInherit`, and exact engine light attenuation curves. `EffectRuntime` now renders distinct `APPROXIMATED` previews across all documented render bases including world-space animated `BoltBeamNode` (`draw_bolt`/`draw_beam`/`draw_tracer`), `BottomInteractsWithTerrain` ground clamping above `y = 0`, and rigid-floor/obstacle bouncing `MultiMeshInstance3D` physics for `sim_ember`/`sim_chunk`/`sim_spray`. Particle Lab adds a visual **Texture Browser** (thumbnails, search, categories), `11` documented emitter presets, `ColorPickerButton` RGBA swatches, `renderBase`/`simulateBase`/`textureBlend` dropdowns, per-emitter **Mute (`M`) / Solo (`S`)**, live emission rate / active count / CPU+GPU cost metrics, RMB reset-to-default on every value control, and scoped resets (`RESET THIS ODF` / `RESET SELECTED NODE` / `RESET SELECTED EXTERNAL ODF` / confirmed `RESET DEPENDENCY GRAPH`). The preview is `APPROXIMATED`, not native BZCC output (`NATIVE_VERIFIED: 0`).

## Round-trip

The Particle Lab edits the same `OdfDocument` as the inspector, so:
`ODF → parse → graph → inspector edit → splice → ODF` preserves unrelated content.
A real render ODF (`effects/explosions/xcoreturrxpl.odf`, 4 render headers) is asserted
byte-exact on no-op save in `tests/test_runner.gd`, and the UI smoke test covers duplicate,
delete, undo/redo, cycle detection and layout persistence.

## Next work

1. Diff-before-large-mutation preview for bulk graph edits.
2. Inline editing of external render files directly inside parent external nodes (currently `OPEN` + live preview sync + `SAVE DEPENDENCIES`).
3. Draw external nodes as collapsed groups when one file supplies several headers.

## T-86: transactional saves behind the graph

`SAVE DEPENDENCIES` is now a journaled multi-document transaction: a write-ahead save-group
journal (schema 1) is persisted and read-back verified before any document is mutated, and every
per-document commit is recorded before the next write starts. Recovery semantics (T-86):

- `COMPLETE` / `RECOVERED` groups refuse recovery (`RECOVERY_NOT_APPLICABLE`, zero mutation).
- Rollback restores the exact pre-transaction structural state: an override that did not exist
  stays absent with its manifest entry removed; an existing override restores byte-exact previous
  bytes (empty stays empty, never absent).
- Unknown or newer current revisions and original-source revision drift block rollback as
  `RECOVERY_CONFLICT_PENDING`, which remains discoverable at startup until an explicit
  `keep_current` / `restore_working` resolution.
- Working-copy artifacts live under `save_groups/working_<group>/<basename>-<source-md5>/`,
  so two dependencies with the same basename can never overwrite each other; every artifact is
  hash-verified after write.
- The final `RECOVERED` verdict requires a verified durable journal write; otherwise the honest
  `RECOVERY_FINALIZATION_PENDING` state is reported and retry is idempotent.
- The Dependency Save Preview (read-only) lists every intended write with operation, override
  presence, revision and conflicts before the transaction starts.
- `tests/verify_t86_cross_process_save.gd` proves the restart guarantee with real OS processes:
  a worker is killed mid-save via `OS.kill()`, and fresh Godot processes discover, recover and
  validate the durable result.
