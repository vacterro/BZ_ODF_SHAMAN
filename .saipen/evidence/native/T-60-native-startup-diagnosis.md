# T-60 — Controlled Native BZCC Startup Diagnosis (P0-NATIVE-01)

**Date:** 2026-11-22  
**Game target:** Battlezone: Combat Commander 2.0.185 (`V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\battlezone2.exe`, BuildID `3807009`, MD5 `e2fa7458cf2604315f48915acd288689`)  
**Policy:** `BZ2R` and Steam settings remained strictly read-only; zero files modified in game or Workshop roots.

## 1. Correction of T-20 Misdiagnosis

Visual inspection of `.saipen/evidence/native/t20_bzcc_fatal_dialog.png` shows the exact modal text:

```text
Fatal error on startup
Unable to load console font 'ds_16.bmf' -- check MOD installation and/or .cfg
```

Earlier T-20 notes misread this string as `ds16.brf` and searched for `ds16.brf` (which does not exist).  
The real resource **`ds_16.bmf` EXISTS** in the stock game installation:

- `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\bz2r_res\interface\Fonts\DS\ds_16.bmf`
- `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\bz2r_res\interface\Fonts\DS\ds_16.bm2`

Additionally, read-only inspection of Steam's active-user config (`V:\__STORE_V\_SOFT\Steam\userdata\105534692\config\localconfig.vdf:69`) shows:

```text
"LaunchOptions"		"/disablemipmaps /nointro /tps 30"
```

Steam did **NOT** inject `/logconsole`. BZ_ODF_SHAMAN itself injected `/logconsole` in `scripts/native/native_test_adapter.gd:937` and `scripts/native/native_experiment_runner.gd:1217`.

## 2. Controlled Diagnostic Matrix

| Control | Launch configuration | `/logconsole` present? | Custom `/config` present? | Stock resources mounted? | Game process started? | Main menu / shell reached? | Lua mission loaded? | Error observed? | Evidence |
|---|---|---|---|---|---|---|---|---|---|
| Control A | Stock Steam launch (`/nointro /win`) | No | No | Yes (`3820486276.cfg` + `bz2r_res`) | Yes | Yes | N/A | None | `Battlezone 2026-11-22 11.26.43.3718.log` (49,164 bytes, non-crashed) |
| Control B | Read-only Steam LaunchOptions audit (`105534692`) | No (`/disablemipmaps /nointro /tps 30`) | No | N/A | N/A | N/A | N/A | Confirmed Steam does not inject `/logconsole` | `V:\__STORE_V\_SOFT\Steam\userdata\105534692\config\localconfig.vdf:69` |
| Control C | SHAMAN absolute `/config C:\...\shaman_native.cfg` without `/logconsole` | No | Yes (absolute path outside `@rootdir`) | **No (0 `filesys:` mounts)** | Yes | No | No | Fatal startup dialog: `Unable to load console font 'ds_16.bmf'` | `Battlezone-Crashed 2026-11-22 00.39.02.1796.log` (5,446 bytes); `t20_bzcc_fatal_dialog.png` |
| Control E2 | SHAMAN relative traversal `/config ..\..\..\..\...\shaman_native.cfg` with `/logconsole` | Yes | Yes (relative `..\` path outside `@rootdir`) | **No (0 `filesys:` mounts)** | Yes | No | No | Same: `Command line /config used` followed by zero `filesys:` mounts | `Battlezone-Crashed 2026-11-22 11.27.04.4609.log` (5,529 bytes) |
| Control E_REF | Bare `@rootdir` filename `/config VRV_T960_af713ddf34944358bb29d04bab5297e2.cfg` | No | Yes (bare filename in `@rootdir`) | **Yes (`filesys:946/957` mounts parsed)** | Yes | Yes | Yes (`vrv_new_blank.bzn`) | None | `Battlezone 2026-11-22 01.15.56.6515.log` (43,965 bytes, non-crashed) |
| Control F | Resource provenance scan (`bz2r_res`, `bzone.cfg`, `CORE-GAMELGC.md`) | N/A | N/A | Stock `bzone.cfg` mounts `@rootdir\bz2r_res`, `@rootdir\bz2r_loc`, `@rootdir\maps` | N/A | N/A | N/A | `ds_16.bmf` present in stock `bz2r_res\interface\Fonts\DS\ds_16.bmf` | `V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\bzone.cfg`; `CORE-GAMELGC.md` (`0xfbc34` `select_bzone_cfg`) |

## 3. Proven Root Cause

1. **Primary failure (`CONFIG_PATH_NOT_LOADED_NO_FILESYS`):** BZCC 2.0.185's `select_bzone_cfg` (`i76win.cpp`, RVA `0xfbc34`) only loads `/config <name.cfg>` when `<name.cfg>` resolves inside `@rootdir` (`V:\__STORE_V\_SOFT\Steam\steamapps\common\BZ2R\`). Passing an arbitrary absolute path (`C:\Users\...\shaman_native.cfg`) or parent-traversal path (`..\..\..\..\...\shaman_native.cfg`) causes BZCC to log:
   `DIAG| i76win:1209 | ... |Command line /config used, skipping global config mod setup :`
   and skip `ConfigureFileSystem()` completely (0 `AddDirRecurse` mounts). Because `@rootdir\bz2r_res` is never mounted, the engine immediately fails when loading `ds_16.bmf` and displays `Unable to load console font 'ds_16.bmf' -- check MOD installation and/or .cfg`.
2. **Secondary Steam UX constraint (`STEAM_CUSTOM_ARGS_MODAL_PENDING`):** Launching via `steam.exe -applaunch 624970 <custom_args>` triggers Steam's interactive `"Launch Game with custom arguments"` modal dialog requiring manual operator confirmation (`Continue`).
3. **Read-only boundary preserved:** Because `SafeStageManager` strictly forbids writing files into `BZ2R\`, SHAMAN cannot silently drop a `.cfg` inside `BZ2R\` automatically.

## 4. Verified SHAMAN Changes

1. Removed unconditional `/logconsole` from default SHAMAN launch arguments (`include_logconsole: bool = false`, opt-in only).
2. Added `AddDirRecurse("@rootdir\\maps");` to generated `shaman_native.cfg` for stock-stream parity with `bzone.cfg`.
3. Added `NativeTestAdapter.diagnose_config_path_compatibility(cfg_path, game_root)` and `NativeTestAdapter.classify_startup_failure(log_text, dialog_text)`:
   - When `cfg_path` resides inside `game_root`, passes the bare filename to `/config <filename>`.
   - When `cfg_path` is staged outside `game_root` (read-only safety policy), surfaces explicit `CONFIG_REQUIRES_ROOTDIR_PLACEMENT` diagnostics and exact operator instructions instead of misreporting an external missing font.
4. `NATIVE_VERIFIED` remains honestly `0` until an operator-authorized `@rootdir` config run produces genuine session-bound LuaMission observation evidence.
