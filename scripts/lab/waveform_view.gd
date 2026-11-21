class_name WaveformView
extends Control
## Golden Wintage waveform display.

var peaks := PackedFloat32Array()
var duration := 0.0
var label_text := ""
var playhead := -1.0  # 0..1, negative hides


func set_data(p_peaks: PackedFloat32Array, p_duration: float, p_label: String) -> void:
	peaks = p_peaks
	duration = p_duration
	label_text = p_label
	queue_redraw()


func set_playhead(t: float) -> void:
	playhead = t
	queue_redraw()


func _draw() -> void:
	var bg := Color("#1C1208")
	var mid := Color("#665033")
	var wave := Color("#D3B57A")
	var wave_fill := Color("#969630")
	draw_rect(Rect2(Vector2.ZERO, size), bg)
	var h: float = size.y
	var w: float = size.x
	var cy := h * 0.5
	draw_line(Vector2(0, cy), Vector2(w, cy), mid, 1.0)
	if peaks.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(8, cy - 4), "no decodable PCM data", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#95804C"))
		return
	var n := peaks.size()
	for i in range(n):
		var x := (float(i) / float(maxi(1, n - 1))) * w
		var amp := peaks[i] * (h * 0.46)
		draw_line(Vector2(x, cy - amp), Vector2(x, cy + amp), wave, 1.0)
	# time ruler
	for s in range(0, int(ceil(duration)) + 1, maxi(1, int(ceil(duration / 10.0)))):
		var x2 := (float(s) / maxf(0.001, duration)) * w
		draw_line(Vector2(x2, h - 12), Vector2(x2, h), mid, 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(x2 + 2, h - 2), "%.1fs" % s, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("#95804C"))
	if playhead >= 0.0:
		var px := clampf(playhead, 0.0, 1.0) * w
		draw_line(Vector2(px, 0), Vector2(px, h), Color("#5B9630"), 2.0)
	if label_text != "":
		draw_string(ThemeDB.fallback_font, Vector2(6, 14), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#C5AB6E"))
