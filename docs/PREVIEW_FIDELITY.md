# Preview fidelity

The UI shows one of the required labels: **NATIVE VERIFIED**, **DATA-DRIVEN**,
**APPROXIMATED**, **NOT IMPLEMENTED**. Current state:

| Subsystem | Label | Meaning |
|---|---|---|
| ODF reading/edit | DATA-DRIVEN | values come from the loaded files |
| Weapon chain resolution | DATA-DRIVEN | shooter → weapon → ordnance → explosion, with inheritance |
| Projectile flight | APPROXIMATED | metre-scale straight/arcing motion; BZCC units/tick model not reproduced |
| Collision | APPROXIMATED | sphere vs sphere + swept ray-vs-AABB 3D obstacles + multi-target earliest-hit ordering; no model mesh or terrain slope collision |
| Damage | APPROXIMATED | armor-class lookup + linear splash falloff + independent secondary targets; shields not modelled |
| Particle preview | APPROXIMATED | documented fields mapped to CPUParticles3D across 11 render bases + live cross-file `file.header` preview |
| Explosion effects | APPROXIMATED | real xpl particleClass/count/lifetime/colour/radius mapped to a one-shot burst + light + explosion WAV playback; exact engine curves absent |
| Audio | DATA-DRIVEN (playback) | real PCM WAV decoded/played via bounded 8-channel multichannel pool (fire + explosion SFX) with synchronized interactive Timeline; no spatial attenuation or pitch model |
| Models | DATA-DRIVEN (DOCB `.msh`) | baked `.msh` hierarchy, `.material`, DDS/TGA textures, `turret_y`/`turret_x` & `hp_*` hardpoints decoded; fallback `PLACEHOLDER MESH` if absent |
| Native BZCC comparison | BLOCKED | `NativeExperimentSession` + `NativeResourceClosureBuilder` + `SafeStageManager` + `NativeExperimentRunner` durable ledger & split GUI controls built; live launch blocked (`STEAM_USER_NOT_LOGGED_IN`, `ActiveUser = 0x0`) |

No scenario has been marked NATIVE VERIFIED.

## Weapon model

Values are re-read on each shot from the shared document cache, so inspector edits take effect
immediately.

| Value | Source | Model |
|---|---|---|
| `shotSpeed` | ordnance (inherited ok) | initial velocity magnitude, m/s |
| `lifeSpan` | ordnance | seconds before expiration |
| `shotRadius` | ordnance (not inherited; editor fallback 0.5) | projectile collision sphere |
| `IsArcing` | ordnance | if true, gravity 9.81 m/s² |
| `damageValue(N/L/H/S/D/A)` | ordnance | selects target `armorClass`, fallback N |
| `damageRadius` | vehicle explosion ODF | linear falloff on ground splash |
| `shotDelay` | weapon/cannon | continuous-fire interval |
| `salvoCount`, `salvoDelay` | cannon | burst count/interval |
| `xplGround/Vehicle/Expire` | ordnance | selects the ExplosionClass ODF whose particle classes + explosion WAV are spawned at impact (APPROXIMATED) |
| `renderName` | ordnance | reported; projectile render graph not spawned per shot yet |
| `fireSound`, `shotSound` | weapon/ordnance | resolved and played via bounded 8-channel audio pool (`SFX_FIRE`, `SFX_XPL`) |
| `altName` | weapon (inherited ok) | resolves a second WeaponClass → ordnance chain for FIRE ALT; the morph/switch itself is not simulated |

Alternate fire uses the same projectile model and target state; only the weapon/ordnance chain
changes. The alternate profile resolves its own `altName` only one level deep (`c ↔ a` stock
pairs would otherwise recurse).

Target: `maxHealth` and `armorClass` from the target with inheritance
(`ivscav_vsr → ivscav`: 3000, H); `collisionRadius` when declared.

## Parameter sweep

`ParameterSweep` runs one baseline shot plus N deterministic shots over a linear range of one
property (`shotSpeed`, `lifeSpan`, `shotRadius`, or the target armor's `damageValue`). The
varied value is a transient `WeaponProfile` override, so the shared document and the file on
disk are untouched; overrides are cleared when the sweep ends. Rows report value, applied
damage, delta from baseline, flight time, hit kind and range; the same table exports to CSV
under `user://workspace/sweeps/` (values fixed to 6 decimals, no timestamp inside the file). This is still the same
APPROXIMATED projectile model — a sweep is a comparison tool, not native calibration.

### Formulas

```
range        = shotSpeed > 0 ? shotSpeed * lifeSpan : ∞
damage       = damageValue(targetArmor) ?? damageValue(N)
flight time  = distance / shotSpeed            (non-arcing)
splash       = damageValue * (1 - distance / damageRadius)   [editor approximation]
DPS estimate = damage * salvoCount / shotDelay
```

Timestamps are the simulation's own fixed-step time, not wall-clock. Telemetry is monotonic.

## What the model deliberately ignores

- Shields, deflection and absorption, damage-over-time, status effects.
- Ammo/energy consumption and reload state.
- Animated turret traverse and target lead prediction (static Pitch/Yaw turret aim, `hp_*` barrel origins, shooter/target transforms, and target speed are modelled).
- Terrain height/slope (flat y=0), water, and mesh-accurate building colliders (3D box obstacles and secondary targets use swept ray-vs-AABB and sphere colliders).
- Guidance, homing, mines, deployables, charge/beam weapons.
- Recoil, spread/variance, multi-projectile salvos per shot.
- Native tick rate, engine units and collision layers.

These are stated as limitations rather than hidden behind a “working” checkbox.

## Fidelity evidence

- Automated: `tests/ui_smoke.tscn` fires the reference shot, edits `damageValue(H)` to 200,
  fires again and asserts telemetry reports 200.00 while the disk file is unchanged.
- Automated: `tests/test_runner.gd` asserts flight time ≈ distance / shotSpeed, identical
  results on replay with the same seed, non-inherited property handling, and sweep rows,
  deltas and rollback.
- Automated: `tests/ui_smoke.tscn` runs a 5-point damageValue sweep from the live UI and
  asserts the baseline uses the edited 200 damage, the top point applies 250, and the edit is
  restored afterwards.
- Native comparison: none yet. `docs/NATIVE_TESTING.md` plans the measurement, including which
  changes require a mission/game restart.
