class_name WintageTheme
extends RefCounted
## Wintage Golden Default theme engine for Godot 4.7.
## - Embeds pixel-perfect `res://themes/fonts/Verdana_m1.ttf` (with 1bpp EBLC/EBDT
##   bitmap strikes at 10/11/12/14/16px) and `Verdana_m1-Bold.ttf` by default.
## - Uses the exact 21 canonical Golden Default tokens from UI.md / themes/goldendefault.json.
## - Renders authentic 2px Win95 raised (bevelLight top/left, borderDark bottom/right)
##   and sunken (borderDark top/left, bevelLight bottom/right) 9-slice bevel boxes,
##   rectangular 2px beveled slider thumbs (zero rounded corners), and visible 8px
##   draggable splitters.

const THEME_DIR := "res://themes"
const FONT_REGULAR_PATH := "res://themes/fonts/Verdana_m1.ttf"
const FONT_BOLD_PATH := "res://themes/fonts/Verdana_m1-Bold.ttf"

var themes: Dictionary = {}          # slug -> {label, tokens}
var slugs: Array[String] = []
var current_slug: String = "goldendefault"
var current_tokens: Dictionary = {}
var font_aa_mode: String = "none"    # "none" (default pixel-perfect Verdana_m1), "gray", "lcd"
var font_size_px: int = 12           # 12px default; scales to integer 1bpp strikes (9..24px) with UI scale
var _font: Font
var _bold_font: Font


class Win95BevelStyleBox extends StyleBox:
	var fill_color: Color = Color("#332E22")
	var top_left_color: Color = Color("#75663D")
	var bottom_right_color: Color = Color("#100E08")
	var border_px: int = 2

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		var x0 := floorf(rect.position.x)
		var y0 := floorf(rect.position.y)
		var w := maxf(4.0, roundf(rect.size.x))
		var h := maxf(4.0, roundf(rect.size.y))
		var b := float(border_px)
		RenderingServer.canvas_item_add_rect(to_canvas_item, Rect2(x0, y0, w, h), bottom_right_color)
		RenderingServer.canvas_item_add_rect(to_canvas_item, Rect2(x0, y0, maxf(1.0, w - b * 0.5), b), top_left_color)
		RenderingServer.canvas_item_add_rect(to_canvas_item, Rect2(x0, y0, b, maxf(1.0, h - b * 0.5)), top_left_color)
		RenderingServer.canvas_item_add_rect(to_canvas_item, Rect2(x0 + b, y0 + b, maxf(0.0, w - b * 2.0), maxf(0.0, h - b * 2.0)), fill_color)


static func default_tokens() -> Dictionary:
	return {
		"background": "#1A1810",
		"backgroundSoft": "#232018",
		"surface": "#332E22",
		"surfaceRaised": "#3D372A",
		"surfaceAlt": "#453D30",
		"borderDark": "#100E08",
		"borderHighlight": "#F0D060",
		"bevelLight": "#75663D",
		"borderMuted": "#5A5040",
		"textPrimary": "#D4C89A",
		"textSecondary": "#9C9371",
		"textMuted": "#6E674E",
		"accentTeal": "#008080",
		"accentTealDeep": "#004C4C",
		"success": "#4A7A20",
		"warning": "#7A7A20",
		"danger": "#7A2020",
		"dangerText": "#D66464",
		"selection": "#3D372A",
		"compareBack": "#14120C",
		"link": "#F0D060",
	}


func load_themes() -> void:
	themes.clear()
	slugs.clear()
	var dir := DirAccess.open(THEME_DIR)
	if dir == null:
		themes["goldendefault"] = {"label": "Golden Default", "tokens": default_tokens()}
		slugs = ["goldendefault"]
		current_tokens = default_tokens()
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(THEME_DIR + "/" + fname))
			var parsed = jres.get("data", null) if bool(jres.get("ok", false)) else null
			if parsed is Dictionary and parsed.has("tokens"):
				var slug := str(parsed.get("slug", fname.get_basename()))
				var merged := default_tokens()
				for k in parsed["tokens"]:
					merged[k] = parsed["tokens"][k]
				themes[slug] = {"label": str(parsed.get("label", slug)), "tokens": merged}
				slugs.append(slug)
		fname = dir.get_next()
	dir.list_dir_end()
	if not themes.has("goldendefault"):
		themes["goldendefault"] = {"label": "Golden Default", "tokens": default_tokens()}
		slugs.append("goldendefault")
	slugs.sort()
	current_slug = "goldendefault"
	current_tokens = themes[current_slug]["tokens"]


func select(slug: String) -> void:
	if themes.has(slug):
		current_slug = slug
		current_tokens = themes[slug]["tokens"]


func color(name: String, fallback: String = "#D4C89A") -> Color:
	return Color.from_string(str(current_tokens.get(name, fallback)), Color(fallback))


func token(name: String) -> String:
	return str(current_tokens.get(name, "#D4C89A"))


func set_font_aa(mode: String) -> void:
	var clean := mode.strip_edges().to_lower()
	if clean != "none" and clean != "gray" and clean != "lcd":
		clean = "none"
	font_aa_mode = clean
	_font = null
	_bold_font = null
	get_font()
	get_bold_font()


func _load_embedded_verdana(res_path: String, win_fallback: String) -> Font:
	var aa := TextServer.FONT_ANTIALIASING_NONE
	var subpx := TextServer.SUBPIXEL_POSITIONING_DISABLED
	var hint := TextServer.HINTING_NORMAL
	var oversamp := 1.0
	if font_aa_mode == "gray":
		aa = TextServer.FONT_ANTIALIASING_GRAY
		hint = TextServer.HINTING_LIGHT
		subpx = TextServer.SUBPIXEL_POSITIONING_AUTO
		oversamp = 0.0
	elif font_aa_mode == "lcd":
		aa = TextServer.FONT_ANTIALIASING_LCD
		hint = TextServer.HINTING_NORMAL
		subpx = TextServer.SUBPIXEL_POSITIONING_AUTO
		oversamp = 0.0

	var ff: FontFile = null
	if FileAccess.file_exists(res_path):
		var bytes := FileAccess.get_file_as_bytes(res_path)
		if not bytes.is_empty():
			ff = FontFile.new()
			ff.disable_embedded_bitmaps = (font_aa_mode != "none")
			ff.antialiasing = aa
			ff.subpixel_positioning = subpx
			ff.hinting = hint
			ff.force_autohinter = false
			ff.generate_mipmaps = false
			ff.multichannel_signed_distance_field = false
			ff.keep_rounding_remainders = true
			ff.oversampling = oversamp
			ff.allow_system_fallback = true
			ff.data = bytes
	if ff == null and ResourceLoader.exists(res_path):
		var loaded := ResourceLoader.load(res_path)
		if loaded is FontFile:
			ff = (loaded as FontFile).duplicate()
	if ff != null:
		ff.disable_embedded_bitmaps = (font_aa_mode != "none")
		ff.antialiasing = aa
		ff.subpixel_positioning = subpx
		ff.hinting = hint
		ff.force_autohinter = false
		ff.generate_mipmaps = false
		ff.multichannel_signed_distance_field = false
		ff.keep_rounding_remainders = true
		ff.oversampling = oversamp
		ff.allow_system_fallback = true
		return ff

	var ff_win := FontFile.new()
	var sys_path := OS.get_environment("WINDIR").path_join("Fonts").path_join(win_fallback)
	if OS.get_name() == "Windows" and FileAccess.file_exists(sys_path) and ff_win.load_dynamic_font(sys_path) == OK:
		ff_win.antialiasing = aa
		ff_win.subpixel_positioning = subpx
		ff_win.hinting = hint
		ff_win.oversampling = oversamp
		return ff_win

	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Verdana_m1", "Verdana", "Tahoma"])
	sf.antialiasing = aa
	sf.subpixel_positioning = subpx
	sf.hinting = hint
	sf.oversampling = oversamp
	return sf


func get_font() -> Font:
	if _font == null:
		_font = _load_embedded_verdana(FONT_REGULAR_PATH, "verdana.ttf")
	return _font


func get_bold_font() -> Font:
	if _bold_font == null:
		_bold_font = _load_embedded_verdana(FONT_BOLD_PATH, "verdanab.ttf")
	return _bold_font


## True 2px Win95 procedural bevel box (top+left = `top_left`, bottom+right = `bottom_right`).
## Draws exact integer-aligned rectangles via RenderingServer so zero tiling stripes or
## bilinear blur occur at any UI scale.
static func bevel_box(fill: Color, top_left: Color, bottom_right: Color,
		pad_x: int = 6, pad_y: int = 3) -> StyleBox:
	var style := Win95BevelStyleBox.new()
	style.fill_color = fill
	style.top_left_color = top_left
	style.bottom_right_color = bottom_right
	style.border_px = 2
	style.content_margin_left = pad_x
	style.content_margin_right = pad_x
	style.content_margin_top = pad_y
	style.content_margin_bottom = pad_y
	return style


func set_ui_scale(scale_val: float) -> int:
	font_size_px = clampi(roundi(12.0 * clampf(scale_val, 0.75, 2.0)), 9, 24)
	return font_size_px


static func slider_thumb(fill: Color, top_left: Color, bottom_right: Color) -> ImageTexture:
	var bitmap := Image.create_empty(10, 16, false, Image.FORMAT_RGBA8)
	bitmap.fill(bottom_right)
	bitmap.fill_rect(Rect2i(0, 0, 10, 2), top_left)
	bitmap.fill_rect(Rect2i(0, 0, 2, 16), top_left)
	bitmap.fill_rect(Rect2i(2, 2, 6, 12), fill)
	return ImageTexture.create_from_image(bitmap)


func _flat(bg: Color, border: Color, width: int = 1, pad_x: int = 4, pad_y: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


func _make_grabber_texture(vertical: bool, bg: Color, bevel: Color, highlight: Color, dark: Color) -> ImageTexture:
	var w := 8 if vertical else 36
	var h := 36 if vertical else 8
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	for x in w:
		img.set_pixel(x, 0, bevel if not vertical else dark)
		img.set_pixel(x, h - 1, dark)
	for y in h:
		img.set_pixel(0, y, bevel if vertical else dark)
		img.set_pixel(w - 1, y, dark)
	var cx := w / 2
	var cy := h / 2
	for offset in [-6, 0, 6]:
		var off_i: int = int(offset)
		var gx: int = cx if vertical else cx + off_i
		var gy: int = cy + off_i if vertical else cy
		if gx >= 1 and gx < w - 1 and gy >= 1 and gy < h - 1:
			img.set_pixel(gx, gy, highlight)
			if gx + 1 < w - 1:
				img.set_pixel(gx + 1, gy, dark)
			if gy + 1 < h - 1:
				img.set_pixel(gx, gy + 1, dark)
	return ImageTexture.create_from_image(img)


static func _make_arrow_texture(col: Color) -> ImageTexture:
	var img := Image.create_empty(9, 6, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for row in range(4):
		for x in range(1 + row, 8 - row):
			img.set_pixel(x, 1 + row, col)
	return ImageTexture.create_from_image(img)


func build_theme() -> Theme:
	var bg := color("background")
	var soft := color("backgroundSoft")
	var surface := color("surface")
	var raised := color("surfaceRaised")
	var alt := color("surfaceAlt")
	var dark := color("borderDark")
	var light := color("borderHighlight")
	var bevel := color("bevelLight")
	var muted := color("borderMuted")
	var text := color("textPrimary")
	var text2 := color("textSecondary")
	var text3 := color("textMuted")
	var accent := color("accentTeal")
	var accent_deep := color("accentTealDeep")
	var compare_back := color("compareBack")
	var sel := color("selection")
	var success := color("success")

	var font := get_font()
	var bold := get_bold_font()
	var fs := clampi(font_size_px, 9, 24)

	var t := Theme.new()
	# UI.md Iron Law 1: 12px is default body size; Verdana_m1 1bpp bitmap strike (9..24px).
	t.default_font = font
	t.default_font_size = fs
	ThemeDB.fallback_font = font
	ThemeDB.fallback_font_size = fs

	t.set_font("title_font", "Window", bold)
	t.set_font_size("title_font_size", "Window", fs)
	t.set_color("title_color", "Window", text)
	t.set_font("title_font", "GraphNode", bold)
	t.set_font_size("title_font_size", "GraphNode", fs)

	# Labels: zero drop shadow in no-AA mode (UI.md Iron Law 2).
	t.set_color("font_color", "Label", text)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	t.set_constant("shadow_offset_x", "Label", 0)
	t.set_constant("shadow_offset_y", "Label", 0)
	t.set_constant("line_spacing", "Label", 1)

	# Panels / windows: authentic 2px raised and sunken bevels.
	t.set_stylebox("panel", "Panel", _flat(bg, dark, 0, 0, 0))
	t.set_stylebox("panel", "PanelContainer", bevel_box(surface, bevel, dark, 5, 4))
	t.set_stylebox("panel", "PopupPanel", bevel_box(surface, bevel, dark, 6, 4))
	t.set_stylebox("panel", "AcceptDialog", bevel_box(surface, bevel, dark, 8, 6))
	t.set_stylebox("panel", "ConfirmationDialog", bevel_box(surface, bevel, dark, 8, 6))
	t.set_stylebox("panel", "FileDialog", bevel_box(surface, bevel, dark, 8, 6))
	t.set_stylebox("embedded_border", "Window", bevel_box(surface, bevel, dark, 6, 4))
	t.set_stylebox("panel", "TabContainer", bevel_box(soft, bevel, dark, 4, 4))
	t.set_stylebox("panel", "ScrollContainer", bevel_box(compare_back, dark, bevel, 2, 2))

	# Buttons: 2px raised bevel, sunken on press, quieter textMuted on disabled.
	var btn_normal := bevel_box(raised, bevel, dark, 6, 2)
	var btn_hover := bevel_box(alt, light, dark, 6, 2)
	var btn_pressed := bevel_box(surface, dark, bevel, 6, 2)
	var btn_disabled := bevel_box(raised, muted, dark, 6, 2)
	var focus_box := _flat(Color(0, 0, 0, 0), light, 1, 4, 2)
	focus_box.draw_center = false

	for btype in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", btype, btn_normal)
		t.set_stylebox("hover", btype, btn_hover)
		t.set_stylebox("pressed", btype, btn_pressed)
		t.set_stylebox("disabled", btype, btn_disabled)
		t.set_stylebox("focus", btype, focus_box)
		t.set_color("font_color", btype, text)
		t.set_color("font_hover_color", btype, light)
		t.set_color("font_pressed_color", btype, light)
		t.set_color("font_focus_color", btype, text)
		t.set_color("font_disabled_color", btype, text3)
		t.set_font("font", btype, font)
		t.set_font_size("font_size", btype, fs)
	t.set_constant("h_separation", "Button", 4)
	t.set_icon("arrow", "OptionButton", _make_arrow_texture(text))
	t.set_constant("arrow_margin", "OptionButton", 6)

	# CheckBox / CheckButton
	for ctype in ["CheckBox", "CheckButton"]:
		t.set_stylebox("normal", ctype, _flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 2))
		t.set_stylebox("hover", ctype, bevel_box(alt, bevel, dark, 4, 2))
		t.set_stylebox("pressed", ctype, bevel_box(surface, dark, bevel, 4, 2))
		t.set_stylebox("focus", ctype, focus_box)
		t.set_color("font_color", ctype, text)
		t.set_color("font_hover_color", ctype, light)
		t.set_color("font_pressed_color", ctype, light)
		t.set_color("font_disabled_color", ctype, text3)

	# Inputs: always 2px sunken on compareBack (#14120C).
	var input_sunken := bevel_box(compare_back, dark, bevel, 5, 2)
	var input_focus := bevel_box(compare_back, accent, light, 5, 2)
	var input_ro := bevel_box(soft, dark, muted, 5, 2)
	t.set_stylebox("normal", "LineEdit", input_sunken)
	t.set_stylebox("focus", "LineEdit", input_focus)
	t.set_stylebox("read_only", "LineEdit", input_ro)
	t.set_color("font_color", "LineEdit", text)
	t.set_color("font_uneditable_color", "LineEdit", text2)
	t.set_color("font_placeholder_color", "LineEdit", text3)
	t.set_color("caret_color", "LineEdit", light)
	t.set_color("selection_color", "LineEdit", sel)
	t.set_font("font", "LineEdit", font)
	t.set_font_size("font_size", "LineEdit", fs)

	t.set_stylebox("normal", "TextEdit", input_sunken)
	t.set_stylebox("focus", "TextEdit", input_focus)
	t.set_stylebox("read_only", "TextEdit", input_sunken)
	t.set_color("font_color", "TextEdit", text)
	t.set_color("font_readonly_color", "TextEdit", text)
	t.set_color("font_placeholder_color", "TextEdit", text3)
	t.set_color("selection_color", "TextEdit", sel)
	t.set_color("line_number_color", "TextEdit", text3)
	t.set_color("caret_color", "TextEdit", light)
	t.set_font("font", "TextEdit", font)
	t.set_font_size("font_size", "TextEdit", fs)

	# Trees & lists: sunken panel, sunken bevel on selected row (UI.md Tables rule).
	var row_sel := bevel_box(sel, dark, light, 2, 1)
	var row_sel_focus := bevel_box(accent_deep, dark, light, 2, 1)
	t.set_stylebox("panel", "Tree", bevel_box(compare_back, dark, bevel, 3, 3))
	t.set_stylebox("focus", "Tree", focus_box)
	t.set_stylebox("selected", "Tree", row_sel)
	t.set_stylebox("selected_focus", "Tree", row_sel_focus)
	t.set_stylebox("title_button_normal", "Tree", bevel_box(raised, bevel, dark, 4, 2))
	t.set_stylebox("title_button_hover", "Tree", bevel_box(alt, light, dark, 4, 2))
	t.set_stylebox("title_button_pressed", "Tree", bevel_box(surface, dark, bevel, 4, 2))
	t.set_color("font_color", "Tree", text)
	t.set_color("font_selected_color", "Tree", light)
	t.set_color("title_button_color", "Tree", text)
	t.set_color("guide_color", "Tree", dark)
	t.set_color("relationship_line_color", "Tree", muted)
	t.set_constant("v_separation", "Tree", 2)
	t.set_constant("h_separation", "Tree", 6)
	t.set_constant("item_margin", "Tree", 12)

	t.set_stylebox("panel", "ItemList", bevel_box(compare_back, dark, bevel, 3, 3))
	t.set_stylebox("selected", "ItemList", row_sel)
	t.set_stylebox("selected_focus", "ItemList", row_sel_focus)
	t.set_color("font_color", "ItemList", text)
	t.set_color("font_selected_color", "ItemList", light)

	# Tabs: UI.md rule — Active tab is sunken, Inactive tab is raised, tabs touch.
	var tab_active := bevel_box(surface, dark, bevel, 8, 3)
	var tab_inactive := bevel_box(raised, bevel, dark, 8, 3)
	var tab_hover := bevel_box(alt, light, dark, 8, 3)
	var tab_dis := bevel_box(soft, muted, dark, 8, 3)
	for ttype in ["TabBar", "TabContainer"]:
		t.set_stylebox("tab_selected", ttype, tab_active)
		t.set_stylebox("tab_unselected", ttype, tab_inactive)
		t.set_stylebox("tab_hovered", ttype, tab_hover)
		t.set_stylebox("tab_disabled", ttype, tab_dis)
		t.set_stylebox("tab_focus", ttype, focus_box)
		t.set_color("font_selected_color", ttype, light)
		t.set_color("font_unselected_color", ttype, text2)
		t.set_color("font_hovered_color", ttype, text)
		t.set_color("font_disabled_color", ttype, text3)
	t.set_constant("h_separation", "TabBar", 0)
	t.set_constant("side_margin", "TabContainer", 0)

	# Menus
	t.set_stylebox("normal", "MenuBar", bevel_box(soft, bevel, dark, 4, 2))
	t.set_stylebox("hover", "MenuBar", bevel_box(alt, light, dark, 4, 2))
	t.set_stylebox("pressed", "MenuBar", bevel_box(surface, dark, bevel, 4, 2))
	t.set_color("font_color", "MenuBar", text)
	t.set_stylebox("panel", "PopupMenu", bevel_box(surface, bevel, dark, 4, 4))
	t.set_stylebox("hover", "PopupMenu", bevel_box(accent_deep, light, dark, 3, 1))
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", light)
	t.set_color("font_disabled_color", "PopupMenu", text3)

	# Sliders: 2px sunken track, teal fill, rectangular 10x16 2px beveled thumb (no round circles).
	var track := bevel_box(compare_back, dark, bevel, 2, 3)
	var fill := bevel_box(accent_deep, bevel, dark, 2, 3)
	var fill_hi := bevel_box(accent, light, dark, 2, 3)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill_hi)
	t.set_icon("grabber", "HSlider", slider_thumb(raised, bevel, dark))
	t.set_icon("grabber_highlight", "HSlider", slider_thumb(alt, light, dark))
	t.set_icon("grabber_disabled", "HSlider", slider_thumb(soft, muted, dark))

	# Scrollbars: token-painted sunken track + raised grabber (no platform default leaks).
	var sb_track := bevel_box(soft, dark, bevel, 2, 2)
	var sb_grab := bevel_box(raised, bevel, dark, 2, 2)
	var sb_grab_hi := bevel_box(alt, light, dark, 2, 2)
	var sb_grab_pr := bevel_box(sel, dark, bevel, 2, 2)
	for sc_type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sc_type, sb_track)
		t.set_stylebox("scroll_focus", sc_type, sb_track)
		t.set_stylebox("grabber", sc_type, sb_grab)
		t.set_stylebox("grabber_highlight", sc_type, sb_grab_hi)
		t.set_stylebox("grabber_pressed", sc_type, sb_grab_pr)

	# Progress / separators / tooltips
	t.set_stylebox("background", "ProgressBar", bevel_box(compare_back, dark, bevel, 2, 2))
	t.set_stylebox("fill", "ProgressBar", bevel_box(success, bevel, dark, 2, 2))
	t.set_color("font_color", "ProgressBar", text)
	t.set_stylebox("separator", "HSeparator", _flat(dark, bevel, 1, 1, 1))
	t.set_stylebox("separator", "VSeparator", _flat(dark, bevel, 1, 1, 1))
	t.set_stylebox("panel", "TooltipPanel", bevel_box(raised, light, dark, 4, 2))
	t.set_color("font_color", "TooltipLabel", text)

	# GraphEdit (node graph)
	t.set_stylebox("panel", "GraphEdit", bevel_box(compare_back, dark, bevel, 2, 2))
	t.set_color("grid_minor", "GraphEdit", soft)
	t.set_color("grid_major", "GraphEdit", surface)
	t.set_color("selection_fill", "GraphEdit", sel)
	t.set_color("selection_stroke", "GraphEdit", light)
	t.set_stylebox("panel", "GraphNode", bevel_box(surface, bevel, dark, 5, 4))
	t.set_stylebox("panel_selected", "GraphNode", bevel_box(raised, light, dark, 5, 4))
	t.set_stylebox("titlebar", "GraphNode", bevel_box(raised, bevel, dark, 5, 2))
	t.set_stylebox("titlebar_selected", "GraphNode", bevel_box(alt, light, dark, 5, 2))
	t.set_color("resizer_color", "GraphNode", text3)

	t.set_color("default_color", "RichTextLabel", text)
	t.set_color("font_color", "RichTextLabel", text)
	t.set_stylebox("normal", "RichTextLabel", bevel_box(compare_back, dark, bevel, 4, 3))
	t.set_font("normal_font", "RichTextLabel", font)
	t.set_font("bold_font", "RichTextLabel", bold)
	t.set_font_size("normal_font_size", "RichTextLabel", 12)
	t.set_font_size("bold_font_size", "RichTextLabel", 12)

	t.set_constant("separation", "HBoxContainer", 4)
	t.set_constant("separation", "VBoxContainer", 4)
	t.set_constant("margin_left", "MarginContainer", 4)
	t.set_constant("margin_right", "MarginContainer", 4)
	t.set_constant("margin_top", "MarginContainer", 4)
	t.set_constant("margin_bottom", "MarginContainer", 4)

	# Resizable splitters: visible 8px Wintage grip bar so every pane resizes cleanly.
	var h_grab := _make_grabber_texture(true, surface, bevel, light, dark)
	var v_grab := _make_grabber_texture(false, surface, bevel, light, dark)
	var split_bg := bevel_box(surface, bevel, dark, 0, 0)
	for sp_type in ["HSplitContainer", "VSplitContainer", "SplitContainer"]:
		t.set_constant("separation", sp_type, 8)
		t.set_constant("minimum_grab_thickness", sp_type, 8)
		t.set_constant("autohide", sp_type, 0)
		t.set_stylebox("split_bar_background", sp_type, split_bg)
	t.set_icon("grabber", "HSplitContainer", h_grab)
	t.set_icon("h_grabber", "HSplitContainer", h_grab)
	t.set_icon("grabber", "VSplitContainer", v_grab)
	t.set_icon("v_grabber", "VSplitContainer", v_grab)
	t.set_icon("h_grabber", "SplitContainer", h_grab)
	t.set_icon("v_grabber", "SplitContainer", v_grab)

	t.set_color("font_color", "LinkButton", color("link"))
	t.set_color("font_color", "StatusBar", text2)
	return t


func status_color(kind: String) -> Color:
	match kind:
		"success":
			return color("success")
		"warning":
			return color("warning")
		"danger":
			return color("dangerText")
		"muted":
			return color("textMuted")
		_:
			return color("textSecondary")
