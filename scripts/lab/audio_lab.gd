class_name AudioLab
extends VBoxContainer
## Sound reference browser with real PCM playback and waveform display.
## Non-PCM codecs are reported instead of being guessed at.

signal status_changed(text: String, kind: String)

var index: ResourceIndex
var doc: OdfDocument
var refs: Array[Dictionary] = []
var current: WavReader = null

var list: ItemList
var waveform: WaveformView
var info: RichTextLabel
var play_button: Button
var stop_button: Button
var loop_check: CheckBox
var volume: HSlider
var player: AudioStreamPlayer
var path_label: Label


func setup(p_index: ResourceIndex) -> void:
	index = p_index
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	add_child(top)
	var title := Label.new()
	title.text = "AUDIO LAB"
	title.add_theme_color_override("font_color", Color("#D3B57A"))
	top.add_child(title)
	path_label = Label.new()
	path_label.text = "no document"
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.clip_text = true
	top.add_child(path_label)
	var fidelity := Label.new()
	fidelity.text = "PCM playback · REAL ASSET"
	fidelity.add_theme_color_override("font_color", Color("#5B9630"))
	top.add_child(fidelity)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	list = ItemList.new()
	list.custom_minimum_size = Vector2(330, 0)
	list.item_selected.connect(_on_selected)
	split.add_child(list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	waveform = WaveformView.new()
	waveform.custom_minimum_size = Vector2(0, 220)
	waveform.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(waveform)
	info = RichTextLabel.new()
	info.bbcode_enabled = true
	info.fit_content = true
	info.custom_minimum_size = Vector2(0, 90)
	right.add_child(info)
	var controls := HBoxContainer.new()
	right.add_child(controls)
	play_button = Button.new()
	play_button.text = "PLAY"
	play_button.disabled = true
	play_button.pressed.connect(_toggle_play)
	controls.add_child(play_button)
	stop_button = Button.new()
	stop_button.text = "STOP"
	stop_button.pressed.connect(_stop)
	controls.add_child(stop_button)
	loop_check = CheckBox.new()
	loop_check.text = "Loop"
	loop_check.toggled.connect(_on_loop)
	controls.add_child(loop_check)
	controls.add_child(_lbl("Volume"))
	volume = HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.01
	volume.value = 0.8
	volume.custom_minimum_size = Vector2(140, 0)
	volume.value_changed.connect(_on_volume_changed)
	controls.add_child(volume)
	var note := Label.new()
	note.text = "BZCC ODF sound references resolve to real files; distance attenuation is not simulated."
	note.add_theme_color_override("font_color", Color("#95804C"))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(note)

	player = AudioStreamPlayer.new()
	player.finished.connect(_on_finished)
	add_child(player)


func set_document(p_doc: OdfDocument) -> void:
	doc = p_doc
	refs.clear()
	list.clear()
	_stop()
	current = null
	waveform.set_data(PackedFloat32Array(), 0.0, "")
	info.text = "Select an ODF to list its sound references."
	play_button.disabled = true
	if doc == null:
		path_label.text = "no document"
		return
	path_label.text = doc.get_display_name() + "  —  " + doc.source_path
	var seen: Dictionary = {}
	for ref in DependencyGraph.extract_refs(doc):
		if str(ref.kind) != "audio":
			continue
		var id := str(ref.key).to_lower()
		seen[id] = true
		_add_ref(ref, str(ref.value), false)
	# Includes sounds inherited from parent ODFs (common for VSR weapons).
	for row in OdfInheritance.merged(doc, index):
		var k := str(row.key).to_lower()
		if not (k.ends_with("sound") or k.contains("soundeffect")):
			continue
		var rid := k + str(row.suffix).to_lower()
		if seen.has(rid):
			continue
		seen[rid] = true
		_add_ref({"key": str(row.key) + str(row.suffix), "value": str(row.value), "kind": "audio"}, str(row.value), bool(row.inherited))
	if refs.is_empty():
		info.text = "[color=#95804C]This ODF declares no sound references (fireSound, shotSound, explSound, SoundEffect…).[/color]"
	else:
		info.text = "%d sound reference(s), including inherited ones. Select one to inspect and play." % refs.size()
	status_changed.emit("Audio Lab: %d sound reference(s) in %s" % [refs.size(), doc.get_display_name()], "muted")


func _add_ref(ref: Dictionary, value: String, inherited: bool) -> void:
	var existing := index.find_asset(value, ["wav", "ogg", "mp3"])
	var label := "%s = %s" % [str(ref.get("key", "")), value]
	if inherited:
		label += "  (inherited)"
	var item := list.add_item(label)
	var entry := ref.duplicate()
	entry["value"] = value
	refs.append(entry)
	list.set_item_metadata(item, {"ref": entry, "path": existing})
	if existing != "":
		list.set_item_tooltip(item, existing)
	else:
		list.set_item_tooltip(item, "not indexed (possibly inside .pak)")
		list.set_item_custom_fg_color(item, Color("#D37676"))


func _on_selected(i: int) -> void:
	var meta = list.get_item_metadata(i)
	if not (meta is Dictionary):
		return
	var path := str(meta.get("path", ""))
	var ref: Dictionary = meta.get("ref", {})
	if path == "":
		current = null
		play_button.disabled = true
		waveform.set_data(PackedFloat32Array(), 0.0, "")
		info.text = "[color=#D37676]%s[/color]\nReference %s = %s is not in the asset index. It may live inside a .pak archive." % [
			"NOT FOUND", str(ref.get("key", "")), str(ref.get("value", ""))
		]
		return
	current = WavReader.read(path)
	play_button.disabled = current.stream == null
	waveform.set_data(current.peaks(1200), current.duration, path.get_file())
	var lines := "[b]%s[/b]\n" % path.get_file()
	lines += "%s · %d Hz · %d ch · %s · %.2f s · %d bytes" % [
		current.format_name(), current.sample_rate, current.channels,
		("PCM" if current.format_code == 1 else "compressed"), current.duration, current.data_bytes.size()
	]
	if current.error != "":
		lines += "\n[color=#D37676]" + current.error + "[/color]"
	elif current.stream == null:
		lines += "\n[color=#969630]Waveform metadata shown; this codec is not playable in Godot.[/color]"
	lines += "\n[color=#95804C]" + path + "[/color]"
	info.text = lines
	if current.stream != null:
		player.stream = current.stream
		player.volume_db = linear_to_db(maxf(0.0001, volume.value))


func _toggle_play() -> void:
	if current == null or current.stream == null:
		return
	if player.playing:
		player.stream_paused = not player.stream_paused
		play_button.text = "PLAY" if player.stream_paused else "PAUSE"
	else:
		player.play()
		play_button.text = "PAUSE"


func _stop() -> void:
	if player:
		player.stop()
	play_button.text = "PLAY"
	if waveform:
		waveform.set_playhead(-1.0)


func _on_loop(on: bool) -> void:
	if current != null and current.stream != null:
		current.stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if on else AudioStreamWAV.LOOP_DISABLED
		current.stream.loop_end = current.stream.data.size() / maxi(1, current.channels * maxi(1, current.bits / 8))


func _on_finished() -> void:
	play_button.text = "PLAY"
	waveform.set_playhead(-1.0)


func _process(_delta: float) -> void:
	if current != null and player.playing and current.duration > 0.0:
		waveform.set_playhead(player.get_playback_position() / current.duration)


func _on_volume_changed(v: float) -> void:
	if player != null:
		player.volume_db = linear_to_db(maxf(0.0001, v))


func _lbl(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#C5AB6E"))
	return l
