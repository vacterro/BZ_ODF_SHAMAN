# Wintage themes

## Source and licence

Source inspected: `V:\___VAC\__K\__CODE\_TAMPERMONKEY\_WIN95THEME\Wintage`.
License: MIT (shipped as `themes/WINTAGE_LICENSE.txt`). All 16 theme JSON token files are
copied into `themes/`; the Tampermonkey user script is **not** executed or shipped.

## Pipeline

`WintageTheme.load_themes()` reads each `themes/*.json`, merges its 21 tokens over the built-in
Golden Dark default set, and `build_theme()` produces a native Godot `Theme`:

- `background`, `backgroundSoft`, `surface`, `surfaceRaised`, `surfaceAlt` → panel/button fills
- `borderDark`, `borderHighlight`, `bevelLight`, `borderMuted` → 1–2 px bevels and focus rings
- `textPrimary/Secondary/Muted` → label/button/disabled colours
- `accentTeal` → selection/focus/graph selection
- `success`, `warning`, `danger`, `dangerText` → status and diagnostics
- `compareBack` → editor/tree/text-edit backgrounds

Font: `SystemFont` with `Verdana → Tahoma → Segoe UI → DejaVu Sans`, antialiasing disabled for
the period look. No Microsoft font file is redistributed.

Styled controls: Panel/PanelContainer/PopupPanel, Button (normal/hover/pressed/disabled/focus),
LineEdit, TextEdit, Tree, ItemList, TabBar, CheckBox, OptionButton, MenuBar, PopupMenu, HSlider,
ProgressBar, separators, tooltips, GraphEdit/GraphNode, RichTextLabel, containers.

## Defaults and persistence

- First launch selects **Golden Default** (`goldendefault.json`).
- The top-bar selector lists every discovered theme and switches live.
- Selection persists in `user://settings.json`.
- If the theme directory is missing, the built-in Golden token set is the graceful fallback.

## Differences from the browser theme

- CSS box-shadows are approximated with StyleBoxFlat borders/bevels, not pixel-identical 3D
  chrome.
- Browser-specific icon sets and scrollbar artwork are not shipped.
- No animation is added; the theme is static.
- High-DPI follows the OS scale via Godot's stretch settings; no bitmaps are scaled.

## Adding a theme

Drop a Wintage-format JSON (`slug`, `label`, `tokens`) into `themes/` and restart. Unknown
tokens are preserved in the dictionary but only the documented names are consumed.
