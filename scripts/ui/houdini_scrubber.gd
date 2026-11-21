class_name HoudiniScrubber
extends HBoxContainer
## Houdini-style numeric parameter control:
## - Zero tiny SpinBox up/down arrows.
## - Inline draggable numeric pill (subtle progress fill, LMB horizontal scrub,
##   Shift = 0.1x fine, Ctrl = 10x coarse, click without drag to type exact value
##   or simple math expression like "120*2").
## - Middle-Mouse Button (MMB) press & hold opens the Houdini Value Ladder right
##   at the cursor: move vertically to pick sensitivity rung (100 / 10 / 1 / 0.1 /
##   0.01 / 0.001), drag horizontally to scrub at that precision, release to close.
## - Optional inline HSlider (ON by default for scalar parameters) with smart
##   auto-range when bounds are wide/unbounded so values are never clamped away.
## - Drop-in API compatible with SpinBox (`value`, `min_value`, `max_value`,
##   `step`, `suffix`, `allow_greater`, `allow_lesser`, `rounded`, `value_changed`).

signal value_changed(new_value: float)

const DRAG_THRESHOLD_PX := 4.0
const FLOAT_LADDER: Array[float] = [100.0, 10.0, 1.0, 0.1, 0.01, 0.001]
const INT_LADDER: Array[float] = [1000.0, 100.0, 10.0, 1.0]

var min_value: float = 0.0:
	set(v):
		min_value = v
		_sync_slider_bounds()
		_redraw_pill()

var max_value: float = 100.0:
	set(v):
		max_value = v
		_sync_slider_bounds()
		_redraw_pill()

var step: float = 0.01:
	set(v):
		step = maxf(0.000001, v)
		_sync_slider_bounds()

var suffix: String = "":
	set(v):
		suffix = v
		_redraw_pill()

var prefix: String = "":
	set(v):
		prefix = v
		_redraw_pill()

var allow_greater: bool = false
var allow_lesser: bool = false
var rounded: bool = false

var show_slider: bool = true:
	set(v):
		show_slider = v
		if _slider != null:
			_slider.visible = show_slider

var ladder_steps: Array[float] = []
var default_value: float = 0.0
var has_default_value: bool = false
## Exact authoritative representation from the ODF before user edits (P1-06).
var exact_value_text: String = ""

var value: float = 0.0:
	set(v):
		var clamped := _normalize_value(v)
		var changed := absf(clamped - value) > 0.0000005
		value = clamped
		if changed and not _suppress_signal:
			exact_value_text = ""
		_sync_ui_from_value()
		if changed and not _suppress_signal:
			value_changed.emit(value)

var _suppress_signal := false
var _pill: Control
var _edit: LineEdit
var _slider: HSlider

var _lmb_down := false
var _lmb_dragging := false
var _lmb_press_pos := Vector2.ZERO
var _lmb_last_x := 0.0
var _lmb_start_val := 0.0

var _ladder_active := false
var _ladder_layer: Control
var _ladder_panel: PanelContainer
var _ladder_rows: Array[Label] = []
var _ladder_rung_idx: int = 2
var _ladder_last_x: float = 0.0
var _ladder_accum: float = 0.0
var _ladder_origin_y: float = 0.0


func _init() -> void:
	add_theme_constant_override("separation", 4)
	_build()


func _build() -> void:
	_pill = Control.new()
	_pill.custom_minimum_size = Vector2(68, 22)
	_pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL if not show_slider else Control.SIZE_FILL
	_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_pill.mouse_filter = Control.MOUSE_FILTER_STOP
	_pill.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_pill.focus_mode = Control.FOCUS_CLICK
	_pill.draw.connect(_on_pill_draw)
	_pill.gui_input.connect(_on_pill_gui_input)
	add_child(_pill)

	_edit = LineEdit.new()
	_edit.visible = false
	_edit.custom_minimum_size = Vector2(68, 22)
	_edit.size_flags_horizontal = Control.SIZE_FILL
	_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_edit.text_submitted.connect(_on_edit_submitted)
	_edit.focus_exited.connect(_on_edit_focus_exited)
	_edit.gui_input.connect(_on_edit_gui_input)
	add_child(_edit)

	_slider = HSlider.new()
	_slider.visible = show_slider
	_slider.custom_minimum_size = Vector2(72, 18)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.value_changed.connect(_on_slider_changed)
	_slider.gui_input.connect(_on_slider_gui_input)
	add_child(_slider)

	_sync_slider_bounds()
	_sync_ui_from_value()


func configure(p_min: float, p_max: float, p_step: float, p_val: float,
		p_suffix: String = "", p_show_slider: bool = true,
		p_allow_unbounded: bool = false, p_rounded: bool = false) -> void:
	_suppress_signal = true
	min_value = p_min
	max_value = p_max
	step = p_step
	suffix = p_suffix
	show_slider = p_show_slider
	allow_greater = p_allow_unbounded
	allow_lesser = p_allow_unbounded
	rounded = p_rounded
	if not show_slider and _pill != null:
		_pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	elif _pill != null:
		_pill.size_flags_horizontal = Control.SIZE_FILL
		_edit.size_flags_horizontal = Control.SIZE_FILL
	value = _normalize_value(p_val)
	_suppress_signal = false
	_sync_slider_bounds()
	_sync_ui_from_value()


func set_value_no_signal(v: float) -> void:
	_suppress_signal = true
	value = _normalize_value(v)
	_suppress_signal = false
	_sync_ui_from_value()


func set_exact_value(v: float, raw_text: String = "") -> void:
	_suppress_signal = true
	# Never clamp an authoritative ODF value on load even if outside default slider range (P1-06).
	if v < min_value:
		allow_lesser = true
	if v > max_value:
		allow_greater = true
	value = roundf(v) if rounded else v
	exact_value_text = raw_text.strip_edges()
	_suppress_signal = false
	_sync_slider_bounds()
	_sync_ui_from_value()


func set_default_value(def_val: float) -> void:
	default_value = def_val
	has_default_value = true
	var tip := "LMB drag: scrub · Click/DblClick: type math · MMB hold: Value Ladder · RMB: Reset to default (%s)" % str(def_val)
	if _pill != null:
		_pill.tooltip_text = tip
	if _slider != null:
		_slider.tooltip_text = "Drag slider or RMB to reset to default (%s)" % str(def_val)


func reset_to_default() -> bool:
	if not has_default_value:
		return false
	exact_value_text = ""
	value = default_value
	return true


func set_pill_width(w: float) -> void:
	if _pill != null:
		_pill.custom_minimum_size.x = w
	if _edit != null:
		_edit.custom_minimum_size.x = w


func _active_ladder_steps() -> Array[float]:
	if not ladder_steps.is_empty():
		return ladder_steps
	if rounded or step >= 1.0:
		return INT_LADDER
	return FLOAT_LADDER


func _normalize_value(v: float) -> float:
	var out := v
	if not allow_lesser and out < min_value:
		out = min_value
	if not allow_greater and out > max_value:
		out = max_value
	if rounded:
		out = roundf(out)
	return out


func _slider_range() -> Vector2:
	var span := max_value - min_value
	# Practical bounded range: use directly unless huge/unbounded.
	if span > 0.0 and span <= 50000.0 and not (allow_greater and allow_lesser and span > 10000.0):
		var lo := min_value
		var hi := max_value
		if allow_lesser and value < lo:
			lo = value
		if allow_greater and value > hi:
			hi = value
		return Vector2(lo, hi)
	# Unbounded Inspector field: smart dynamic Houdini-like slider window around current value.
	var mag := maxf(10.0, absf(value) * 2.0)
	if rounded:
		mag = maxf(20.0, ceilf(absf(value) * 2.0))
	if value < 0.0:
		return Vector2(-mag, mag)
	return Vector2(0.0, mag)


func _sync_slider_bounds() -> void:
	if _slider == null:
		return
	var r := _slider_range()
	_suppress_signal = true
	_slider.min_value = r.x
	_slider.max_value = r.y
	var slider_step := step
	if (r.y - r.x) > 0.0 and slider_step < (r.y - r.x) / 400.0 and not rounded:
		slider_step = (r.y - r.x) / 200.0
	_slider.step = maxf(0.0001, slider_step)
	_slider.value = clampf(value, r.x, r.y)
	_suppress_signal = false


func _sync_ui_from_value() -> void:
	if _slider != null and _slider.visible:
		var r := _slider_range()
		if value < _slider.min_value or value > _slider.max_value:
			_sync_slider_bounds()
		else:
			_suppress_signal = true
			_slider.value = clampf(value, r.x, r.y)
			_suppress_signal = false
	_redraw_pill()


func _redraw_pill() -> void:
	if _pill != null:
		_pill.queue_redraw()


func _format_display(v: float) -> String:
	if exact_value_text != "":
		return prefix + exact_value_text + suffix
	var txt := ""
	if rounded or step >= 1.0:
		txt = str(int(round(v)))
	elif step >= 0.1 and absf(v - roundf(v * 10.0) / 10.0) < 0.0001:
		txt = "%.1f" % v
	elif step >= 0.01 and absf(v - roundf(v * 100.0) / 100.0) < 0.00001:
		txt = "%.2f" % v
	else:
		txt = ("%.6f" % v).rstrip("0").rstrip(".")
		if txt == "" or txt == "-0":
			txt = "0"
	return prefix + txt + suffix


func _on_pill_draw() -> void:
	var rect := Rect2(Vector2.ZERO, _pill.size)
	# Canonical Golden Default tokens + 2px sunken Win95 bevel.
	var bg := Color("#14120C")
	var dark := Color("#100E08")
	var bevel := Color("#75663D")
	var highlight := Color("#F0D060")
	var fill_col := Color("#004C4C") if (_lmb_dragging or _ladder_active) else Color("#332E22")
	var text_col := Color("#D4C89A")
	_pill.draw_rect(rect, bg, true)
	var r := _slider_range()
	if r.y > r.x:
		var frac := clampf((value - r.x) / (r.y - r.x), 0.0, 1.0)
		var fill_w := floorf(maxf(0.0, (rect.size.x - 4.0) * frac))
		if fill_w >= 1.0:
			_pill.draw_rect(Rect2(2.0, 2.0, fill_w, maxf(1.0, rect.size.y - 4.0)), fill_col, true)
	# 2px sunken bevel: borderDark on top/left, bevelLight on bottom/right (or accentTeal when scrubbing).
	var tl := Color("#008080") if (_lmb_dragging or _ladder_active or _pill.has_focus()) else dark
	var br := highlight if (_lmb_dragging or _ladder_active) else bevel
	_pill.draw_rect(Rect2(0, 0, rect.size.x, 2), tl, true)
	_pill.draw_rect(Rect2(0, 0, 2, rect.size.y), tl, true)
	_pill.draw_rect(Rect2(0, rect.size.y - 2, rect.size.x, 2), br, true)
	_pill.draw_rect(Rect2(rect.size.x - 2, 0, 2, rect.size.y), br, true)
	var font := _pill.get_theme_default_font()
	var fsize := clampi(ThemeDB.fallback_font_size, 9, 24)
	if font != null:
		var label := _format_display(value)
		var ascent := font.get_ascent(fsize)
		var descent := font.get_descent(fsize)
		var ty := floorf((rect.size.y + ascent - descent) * 0.5)
		_pill.draw_string(font, Vector2(5.0, ty), label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10.0, fsize, highlight if _ladder_active else text_col)


func _input(event: InputEvent) -> void:
	if not _ladder_active:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		update_ladder(mm.global_position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE and not mb.pressed:
			end_ladder()


func _on_slider_changed(v: float) -> void:
	if _suppress_signal:
		return
	value = v


func _on_slider_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and has_default_value:
			reset_to_default()
			_slider.accept_event()


func _on_pill_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					_enter_text_edit()
					_pill.accept_event()
					return
				_lmb_down = true
				_lmb_dragging = false
				_lmb_press_pos = mb.position
				_lmb_last_x = mb.position.x
				_lmb_start_val = value
				_pill.accept_event()
			else:
				if _lmb_down and not _lmb_dragging:
					_enter_text_edit()
				_lmb_down = false
				_lmb_dragging = false
				_redraw_pill()
				_pill.accept_event()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				begin_ladder(mb.global_position)
				_pill.accept_event()
			else:
				end_ladder()
				_pill.accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if has_default_value:
				reset_to_default()
			else:
				_enter_text_edit()
			_pill.accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _ladder_active:
			update_ladder(mm.global_position)
			_pill.accept_event()
		elif _lmb_down:
			if not _lmb_dragging and absf(mm.position.x - _lmb_press_pos.x) >= DRAG_THRESHOLD_PX:
				_lmb_dragging = true
			if _lmb_dragging:
				var dx := mm.position.x - _lmb_last_x
				_lmb_last_x = mm.position.x
				var mult := 1.0
				if mm.shift_pressed or Input.is_key_pressed(KEY_SHIFT):
					mult = 0.1
				elif mm.ctrl_pressed or Input.is_key_pressed(KEY_CTRL):
					mult = 10.0
				scrub_delta(dx, mult)
				_pill.accept_event()


## Programmatic/mouse horizontal scrub (pixels -> value delta).
func scrub_delta(dx: float, mult: float = 1.0) -> void:
	if absf(dx) < 0.0001:
		return
	var base_step := step
	if not rounded:
		var r := _slider_range()
		var auto_step := maxf(step, (r.y - r.x) / 250.0)
		if step < 0.01:
			base_step = minf(auto_step, maxf(0.01, absf(value) * 0.01))
	var delta := (dx / 4.0) * base_step * mult
	if rounded:
		_ladder_accum += delta
		if absf(_ladder_accum) >= 1.0:
			var whole := int(_ladder_accum)
			_ladder_accum -= float(whole)
			value = value + float(whole)
	else:
		value = value + delta


## Open Houdini Value Ladder popup at `global_pos`.
func begin_ladder(global_pos: Vector2) -> void:
	if _ladder_active:
		return
	_ladder_active = true
	_ladder_last_x = global_pos.x
	_ladder_origin_y = global_pos.y
	_ladder_accum = 0.0
	var steps := _active_ladder_steps()
	_ladder_rung_idx = mini(steps.size() - 1, maxi(0, steps.size() / 2))
	_build_ladder_overlay(global_pos, steps)
	_redraw_pill()


func update_ladder(global_pos: Vector2) -> void:
	if not _ladder_active:
		return
	var steps := _active_ladder_steps()
	var row_h := 22.0
	var mid := int(steps.size() / 2)
	var dy := global_pos.y - _ladder_origin_y
	var idx := clampi(mid + int(round(dy / row_h)), 0, steps.size() - 1)
	if idx != _ladder_rung_idx:
		_ladder_rung_idx = idx
		_highlight_ladder_rung()
	var dx := global_pos.x - _ladder_last_x
	_ladder_last_x = global_pos.x
	if absf(dx) > 0.0001:
		_ladder_accum += dx / 6.0
		if absf(_ladder_accum) >= 1.0:
			var ticks := int(_ladder_accum)
			_ladder_accum -= float(ticks)
			value = value + float(ticks) * steps[_ladder_rung_idx]


func end_ladder() -> void:
	if not _ladder_active:
		return
	_ladder_active = false
	if is_instance_valid(_ladder_layer):
		_ladder_layer.queue_free()
	_ladder_layer = null
	_ladder_panel = null
	_ladder_rows.clear()
	_redraw_pill()


func _build_ladder_overlay(global_pos: Vector2, steps: Array[float]) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	_ladder_layer = Control.new()
	_ladder_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ladder_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ladder_layer.z_index = 4096
	vp.add_child(_ladder_layer)

	_ladder_panel = PanelContainer.new()
	_ladder_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 1)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ladder_panel.add_child(vb)

	_ladder_rows.clear()
	for s in steps:
		var lbl := Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.custom_minimum_size = Vector2(58, 20)
		lbl.text = str(int(s)) if s >= 1.0 else str(s)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(lbl)
		_ladder_rows.append(lbl)
	_ladder_layer.add_child(_ladder_panel)

	var est_h := float(steps.size()) * 22.0 + 10.0
	var pos := Vector2(global_pos.x - 32.0, global_pos.y - est_h * 0.5)
	var vrect := vp.get_visible_rect()
	pos.x = clampf(pos.x, 4.0, maxf(4.0, vrect.size.x - 74.0))
	pos.y = clampf(pos.y, 4.0, maxf(4.0, vrect.size.y - est_h - 4.0))
	_ladder_panel.position = pos
	_highlight_ladder_rung()


func _highlight_ladder_rung() -> void:
	for i in _ladder_rows.size():
		var lbl := _ladder_rows[i]
		if not is_instance_valid(lbl):
			continue
		if i == _ladder_rung_idx:
			lbl.add_theme_color_override("font_color", Color("#F0D060"))
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color("#004C4C")
			sb.border_color = Color("#F0D060")
			sb.set_border_width_all(1)
			lbl.add_theme_stylebox_override("normal", sb)
		else:
			lbl.add_theme_color_override("font_color", Color("#D4C89A"))
			lbl.remove_theme_stylebox_override("normal")


func _enter_text_edit() -> void:
	if _edit == null or _pill == null:
		return
	_pill.visible = false
	_edit.visible = true
	_edit.text = str(value) if not rounded else str(int(round(value)))
	_edit.grab_focus()
	_edit.select_all()


func _commit_text_edit(raw: String) -> void:
	var txt := raw.strip_edges()
	if suffix != "" and txt.ends_with(suffix.strip_edges()):
		txt = txt.trim_suffix(suffix.strip_edges()).strip_edges()
	var parsed_ok := false
	var parsed_val := value
	if txt.is_valid_float():
		parsed_val = txt.to_float()
		parsed_ok = true
	elif txt != "":
		# Houdini-style simple math expression evaluation (e.g. "120*2", "100+50").
		var expr := Expression.new()
		if expr.parse(txt) == OK:
			var res = expr.execute()
			if not expr.has_execute_failed() and (res is float or res is int):
				parsed_val = float(res)
				parsed_ok = true
	_exit_text_edit()
	if parsed_ok:
		value = parsed_val


func _exit_text_edit() -> void:
	if _edit != null:
		_edit.visible = false
	if _pill != null:
		_pill.visible = true
		_redraw_pill()


func _on_edit_submitted(new_text: String) -> void:
	_commit_text_edit(new_text)


func _on_edit_focus_exited() -> void:
	if _edit != null and _edit.visible:
		_commit_text_edit(_edit.text)


func _on_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode == KEY_ESCAPE:
			_exit_text_edit()
			_edit.accept_event()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and has_default_value:
			_exit_text_edit()
			reset_to_default()
			_edit.accept_event()


func _exit_tree() -> void:
	end_ladder()
