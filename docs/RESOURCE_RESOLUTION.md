# Resource resolution

## Roots

Configured in `user://resource_roots.json`, defaulting to:

| Root | Kind | Priority |
|---|---|---|
| `…\BZ2R\bz2r_res` | base game | 10 |
| `…\BZ2R\addon` | addon | 20 |
| `…\workshop\content\624970` | Workshop | 30 |

The Workshop root is enabled by default so the VSR reference scenario resolves. Indexing all
17,028 ODFs and 37,161 unique asset names takes ~1.2–3.1 s depending on disk cache
and runs on a worker thread.

## Search

`ResourceIndex.search(query, limit)` ranks ODF file names. Every whitespace-separated token
must match; exact name > prefix > substring > subsequence. A subsequence hit still finds
`ivtank_vsr.odf` for `ivtk`, and ties sort by path so result order is stable. The index does
not search inside ODF contents or by directory path.

## Precedence policy (preview, configurable)

`resolve_from(name, referring_document)` chooses:

1. the same Workshop package as the referring file;
2. base-game data;
3. another mod/Workshop candidate by descending priority.

This is an **editor policy**, not a verified model of BZCC's addon mount order. The real game's
winner depends on installed/active addons; multiple packages in this installation provide
different `atstab_c.odf` values (100 vs 140 heavy damage). BZ_ODF_SHAMAN therefore:

- keeps every candidate;
- shows the chosen source and the number of alternatives in the Dependencies tab;
- lists all alternative paths in the tooltip.

Never assume the first file found is the file the game loads.

## Indexed metadata

Each ODF candidate records absolute path, root label, kind, relative path, Workshop package
and priority. Each asset name (`assets_by_name`) also records `kind` and `package` so
`find_asset_near()` / `find_asset(..., context_path)` follow the same context precedence
(same package → base game → other mods) when resolving `.msh`, `.material`, and textures. Asset extensions indexed:
`wav, msh, msha, dds, tga, png, bmp, fbx, xsi, ogg, mp3, jpg, jpeg`.

## Dependency graph

`DependencyGraph.extract_refs()` recognises:

- `weaponNameN`, `ordName`, `altName`, `xpl*` → ODF
- `particleClassN`, `renderNameN`, `effectNameN`, `emitName`, `flashName` → render/ODF
- `shotGeometry` → model asset
- `*Sound`, `*SoundEffect` → audio asset
- `textureName` → texture asset
- `classLabel` → inheritance parent **only when a matching file exists**

The walker resolves transitively (max 8 deep, 400 nodes), records forward/reverse edges,
missing references, cycles and render-node counts. Clicking a resolved row opens the actual
resource through the shared document cache.

## Known resolution gaps

- Asset lookup uses the indexed names; identical asset names across packages follow the same
  policy, but texture/model *internal* references inside `.msh`/material files are not read.
- `.pak` archives (`bumps.pak`, `lgtex.pak`, `mdtex.pak`, `smtex.pak`) are not unpacked, so
  assets stored only there are reported missing.
- `classLabel` doubles as a game label; only file-resolvable values become inheritance edges.
- Alternate weapon pairing (`altName`) is displayed but only the primary `weaponName` chain is
  simulated.
