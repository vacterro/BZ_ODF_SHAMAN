# T-20 refined native blocker (2026-11-22)

Staged launch with `steam.exe -applaunch 624970 ... /config shaman_native.cfg shaman_shot.bzn`
was reproduced again. The game process starts, but BZCC 2.0.185 shows a modal
fatal dialog: "Unable to load console font 'ds16.brf' -- check MOD installation
and/or .cfg" (screenshot t20_bzcc_fatal_dialog.png). `ds16.brf` does not exist
anywhere under BZ2R, workshop content, or local archives. Steam injects
`/logconsole` through global launch options even when omitted from our command,
so a staged config alone cannot avoid the missing-font path. Replacing the font
with `isdf16.brf` inside the isolated stage did not satisfy the loader. The game
installation is read-only by project policy; no fix is available inside the Godot
project. Native scenario execution and Lua observation remain impossible.
