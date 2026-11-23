# T-79 Native stage collision diagnosis (read-only)

Addon root: C:/Users/vac34/Documents/My Games/Battlezone Combat Commander/Addon

- SHAMAN_shaman_addon_53341673_4126004539: manifest-owned, hash MATCH, session shaman_sess_53344849_1, status STAGED, 0 modified, 0 unknown. cleanup_allowed=false.
- SHAMAN_shaman_addon_59988070_3838779331: manifest-owned, hash MATCH, session shaman_sess_59989155_1, status STAGED, 0 modified, 0 unknown. cleanup_allowed=false.
- SHAMAN_shaman_stock_5703547_3698924300: no stage_manifest.json, session shaman_sess_5706512_1, status STAGED. Ownership UNRESOLVED, cleanup_allowed=false.

Conclusion: OLD_SHAMAN_STAGE_COLLISION is caused by real SHAMAN stages. All are STAGED (non-terminal); SafeStageManager refuses cleanup. No file was deleted, renamed or modified. Per handoff rule, report STAGE_OWNERSHIP_UNRESOLVED for new-experiment preflight; an authorized operator decision is required before any cleanup. Game/workshop files untouched.
