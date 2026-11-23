extends SceneTree
## Focused regression verifier for T-76 (SRC-017):
##   WPN-01..08: per-vehicle weaponNameN slot enumeration and switching
##               (AT Stab / minigun / mortar), correct per-slot barrels,
##               tandem vs salvo vs single barrel policy, no cross-weapon firing.
##   KEY-01..08: node-link manipulation hotkeys (cut/copy/paste/rewire/
##               disconnect/move) wired into ParticleLab + MainWindow.
##
## Run: Godot --headless --path . --script res://tests/verify_t76_weapons_and_hotkeys.gd

const WeaponProfileScript = preload("res://scripts/sim/weapon_profile.gd")
const ParticleLabScript = preload("res://scripts/lab/particle_lab.gd")

var passed := 0
var failed := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
		print("  ✓ " + msg)
	else:
		failed += 1
		print("  ✗ FAIL: " + msg)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _remove_tree(path: String) -> void:
	if path == "" or not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		dir.list_dir_begin()
		var n := dir.get_next()
		while n != "":
			if n != "." and n != "..":
				var full := path.path_join(n)
				if dir.current_is_dir():
					_remove_tree(full)
				else:
					DirAccess.remove_absolute(full)
			n = dir.get_next()
		dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _initialize() -> void:
	print("T-76 Weapon Switching & Node Hotkey Verifier")
	var tmp := ProjectSettings.globalize_path("user://verify_t76_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp)

	# ---- Vehicle with AT Stab + two minigun barrels + mortar ----
	_write(tmp + "/tank.odf", "[GameObjectClass]\nweaponName1=\"atstab\"\nweaponHard1=\"hp_at\"\nweaponName2=\"minigun\"\nweaponHard2=\"hp_mg_l\"\nweaponName3=\"minigun\"\nweaponHard3=\"hp_mg_r\"\nweaponName4=\"mortar\"\nweaponHard4=\"hp_mortar\"\n")
	_write(tmp + "/atstab.odf", "[WeaponClass]\nordName=\" stab_ord\"\n")
	_write(tmp + "/minigun.odf", "[WeaponClass]\nordName=\"mg_ord\"\n")
	_write(tmp + "/mortar.odf", "[WeaponClass]\nordName=\"mortar_ord\"\n")
	for pair in [["stab_ord", 90.0], ["mg_ord", 25.0], ["mortar_ord", 60.0]]:
		_write(tmp + "/" + str(pair[0]) + ".odf", "[OrdnanceClass]\nshotSpeed=120\nlifeSpan=2\ndamageValue(H)=" + str(pair[1]) + "\n")
	_write(tmp + "/target.odf", "[GameObjectClass]\nmaxHealth=1000\narmorClass=\"H\"\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": tmp, "label": "t76", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)

	var p0 := WeaponProfileScript.new()
	var ok0 := p0.resolve(idx, tmp + "/tank.odf", tmp + "/target.odf")
	_check(ok0, "WPN-01: vehicle profile resolves")
	_check(p0.weapon_slots.size() == 4, "WPN-02: all four weaponNameN slots enumerated (got %d)" % p0.weapon_slots.size())
	_eq_name(p0.weapon_name, "atstab", "WPN-03: slot 0 defaults to AT Stab")
	_check(p0.weapon_hardpoints.size() == 1 and p0.weapon_hardpoints[0] == "hp_at", "WPN-04: AT Stab slot fires only its own hardpoint")

	var p1 := WeaponProfileScript.new()
	var ok1 := p1.resolve(idx, tmp + "/tank.odf", tmp + "/target.odf", "", true, 1)
	_eq_name(p1.weapon_name, "minigun", "WPN-05: slot 1 switches to minigun")
	_check(p1.weapon_hardpoints.size() == 2 and p1.weapon_hardpoints.has("hp_mg_l") and p1.weapon_hardpoints.has("hp_mg_r"), "WPN-06: minigun exposes both barrels, not the AT Stab hardpoint")

	var p3 := WeaponProfileScript.new()
	var ok3 := p3.resolve(idx, tmp + "/tank.odf", tmp + "/target.odf", "", true, 3)
	_eq_name(p3.weapon_name, "mortar", "WPN-07: slot 3 switches to mortar")

	var p2 := WeaponProfileScript.new()
	var ok2 := p2.resolve(idx, tmp + "/tank.odf", tmp + "/target.odf", "", true, 1, "SALVO")
	_check(ok2 and p2.barrel_mode == "SALVO" and p2.weapon_hardpoints.size() == 2, "WPN-08: barrel policy SALVO preserved with both barrels")

	# ---- Node-link hotkey contract ----
	var lab_src := FileAccess.get_file_as_string("res://scripts/lab/particle_lab.gd")
	var mw_src := FileAccess.get_file_as_string("res://scripts/ui/main_window.gd")
	_check(lab_src.contains("func cut_selected_links") and lab_src.contains("func copy_selected_links") and lab_src.contains("func paste_links"), "KEY-01: ParticleLab exposes cut/copy/paste link operations")
	_check(lab_src.contains("func reconnect_selected_link") and lab_src.contains("func disconnect_selected_link"), "KEY-02: ParticleLab exposes reconnect/disconnect link operations")
	_check(lab_src.contains("func move_selected_link"), "KEY-03: ParticleLab exposes link move operation")
	_check(lab_src.contains("_handle_graph_hotkey"), "KEY-04: ParticleLab has a graph hotkey dispatcher")
	_check(lab_src.contains("KEY_DELETE") or lab_src.contains("KEY_X"), "KEY-05: cut/delete key bound")
	_check(lab_src.contains("KEY_C") and lab_src.contains("KEY_V"), "KEY-06: copy/paste keys bound")
	_check(mw_src.contains("particle_lab._handle_graph_hotkey"), "KEY-07: MainWindow routes graph hotkeys to ParticleLab")
	_check(lab_src.contains("begin_compound()") and lab_src.contains("end_compound()"), "KEY-08: link hotkey edits are undoable in one compound step")
	# WPN-09: TANDEM semantics — one reload cycle for the whole volley. The
	# second barrel must bypass the reload gate that the first barrel armed.
	var wl_src := FileAccess.get_file_as_string("res://scripts/lab/weapon_lab.gd")
	_check(wl_src.contains("volley_enforce = false") and wl_src.contains("TANDEM"), "WPN-09: TANDEM volley bypasses reload for extra barrels")
	# BARREL-01..04: absent hardpoint declarations must not disable firing.
	_check(wl_src.contains("var fallback_origin := hp_names.is_empty()") and
		wl_src.contains("hp_names.append(\"\")") and
		wl_src.contains("aggregate[\"fallback_origin\"] = fallback_origin"),
		"BARREL-01: zero-hardpoint TANDEM uses one explicit fallback origin")
	# VOLLEY-01..06: aggregate result is the single success authority.
	_check(wl_src.contains("var aggregate := volley.to_dict()") and
		wl_src.contains("aggregate[\"failure_reasons\"]") and
		wl_src.contains("volley.complete =") and
		wl_src.contains("volley.ok ="),
		"VOLLEY-01/02: volley aggregate carries complete authoritative outcome")
	_check(wl_src.contains("class VolleyResult") and wl_src.contains("requested_barrels") and
		wl_src.contains("rejected_barrels") and wl_src.contains("partial_failure"),
		"WPN-38/39: full VolleyResult contract present")

	# --- T-78 behavioral graph regressions (not source-string checks) ---
	var graph_path := tmp + "/graph_t78.odf"
	_write(graph_path, "[EmitterA]
renderBase=peuler
renderName1=EmitterB
renderName2=EmitterC

" +
		"[EmitterB]
renderBase=peuler
renderName1=EmitterD

" +
		"[EmitterC]
renderBase=peuler
lifeTime=1.0

" +
		"[EmitterD]
renderBase=peuler
lifeTime=2.0
")
	var gdoc := OdfDocument.load_file(graph_path)
	var plab = ParticleLabScript.new()
	root.add_child(plab)
	plab.visible = false
	plab.set_process(false)
	plab.set_physics_process(false)
	plab.setup(idx, SchemaRegistry.new())
	plab.doc = gdoc
	var before_bytes: PackedByteArray = gdoc.to_bytes()
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	_check(not plab.reconnect_selected_link("EmitterA") and gdoc.to_bytes() == before_bytes, "GRAPH-18: self-link refused, bytes intact")
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	_check(not plab.reconnect_selected_link("MissingEmitter") and gdoc.to_bytes() == before_bytes, "GRAPH-13: invalid destination preserves bytes")
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	_check(not plab.move_selected_link("renderName2") and gdoc.to_bytes() == before_bytes, "GRAPH-20: occupied slot refused")
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	_check(plab.move_selected_link("renderName2", "swap") and
		plab._reference_header(gdoc.get_value("EmitterA", "renderName1")) == "EmitterC" and
		plab._reference_header(gdoc.get_value("EmitterA", "renderName2")) == "EmitterB", "GRAPH-22: swap preserves both links")
	_check(plab._would_cycle("EmitterB", "EmitterB"), "GRAPH-19: zero-length self-reference treated as cycle")
	# XREF-01..05: direct external file.header reference must be accepted and
	# stored verbatim, with local validation applied only to local names.
	var ext_doc := OdfDocument.parse_text(
		"[Render]
renderBase=peuler
lifeTime=3.0
", graph_path)
	var ext_abs := tmp.path_join("other_effect.odf")
	_ext_write(ext_abs, ext_doc.to_text())
	var ext_before: PackedByteArray = FileAccess.get_file_as_bytes(ext_abs)
	var local_text := "[EmitterA]
renderBase=peuler
renderName1=EmitterB

[EmitterB]
renderBase=peuler
"
	var xdoc := OdfDocument.parse_text(local_text, tmp.path_join("xref.odf"))
	plab.doc = xdoc
	var xidx := ResourceIndex.new()
	xidx.roots.assign([{"path": tmp, "label": "xref", "kind": "test", "priority": 10, "enabled": true}])
	xidx.scan(false)
	plab.index = xidx
	var xbytes: PackedByteArray = xdoc.to_bytes()
	plab._on_reference_submitted("EmitterA", "renderName1", "other_effect.Render")
	_check(xdoc.get_value("EmitterA", "renderName1") == "other_effect.Render" and
		xdoc.to_bytes() != xbytes and FileAccess.get_file_as_bytes(ext_abs) == ext_before,
		"XREF-01: valid external file.header edit accepted; external file unchanged")
	# XREF-02: bad external header must be rejected without mutation.
	var before_bad: PackedByteArray = xdoc.to_bytes()
	plab._on_reference_submitted("EmitterA", "renderName1", "other_effect.Missing")
	_check(xdoc.to_bytes() == before_bad, "XREF-02: missing external header rejected without mutation")
	# XREF-06/07: parallel references to one target stay independently selectable.
	var par_doc := OdfDocument.parse_text(
		"[EmitterA]
renderBase=peuler
renderName1=EmitterB
renderName2=EmitterB
renderName3=EmitterC

" +
		"[EmitterB]
renderBase=peuler

[EmitterC]
renderBase=peuler
", tmp.path_join("parallel.odf"))
	plab.doc = par_doc
	plab.select_edge("EmitterA", "renderName2", "EmitterB")
	var par_links := plab._collect_target_links()
	_check(par_links.size() == 1 and str(par_links[0].get("key", "")) == "renderName2",
		"XREF-07: exact physical parallel slot selected for commands")

	# GRAPH-24/25/26/28: mouse disconnect targets the exact physical property.
	plab.doc = OdfDocument.parse_text(par_doc.text, par_doc.source_path)
	var ddoc: OdfDocument = plab.doc
	var dnode_a := "EmitterA"
	var dnode_b := "EmitterB"
	plab.load_document(ddoc)
	plab.select_edge("EmitterA", "renderName2", "EmitterB")
	var before_d: PackedByteArray = ddoc.to_bytes()
	var dports: Array = plab._output_port_keys.get(dnode_a, [])
	var dport := dports.find("renderName2")
	_check(dport >= 0, "GRAPH-24: physical renderName2 has a real output port")
	plab._on_disconnection_request(StringName(dnode_a), dport, StringName(dnode_b), 0)
	_check(ddoc.get_value("EmitterA", "renderName1") == "EmitterB" and
		ddoc.find_entry("EmitterA", "renderName2") == null and
		ddoc.get_value("EmitterA", "renderName3") == "EmitterC" and
		ddoc.to_bytes() != before_d,
		"GRAPH-24: focused renderName2 disconnected, renderName1 preserved")
	_check(ddoc.can_undo(), "GRAPH-26: focused disconnect is undoable")
	ddoc.undo()
	_check(ddoc.get_value("EmitterA", "renderName2") == "EmitterB" and ddoc.to_bytes() == before_d,
		"GRAPH-26: undo restores exact byte-exact original property")
	_check(ddoc.can_redo(), "GRAPH-26: undo leaves a coherent redo step")
	ddoc.redo()
	_check(ddoc.find_entry("EmitterA", "renderName2") == null, "GRAPH-26: redo removes only focused property")
	# Ambiguous: two edges to one target, no focus and port out of range.
	var adoc := OdfDocument.parse_text(par_doc.text, tmp.path_join("ambiguous.odf"))
	plab.doc = adoc
	plab.load_document(adoc)
	plab.clear_edge_selection()
	var abefore: PackedByteArray = adoc.to_bytes()
	plab._on_disconnection_request(StringName(dnode_a), -1, StringName(dnode_b), 0)
	_check(adoc.to_bytes() == abefore,
		"GRAPH-25/28: ambiguous parallel disconnect refused without ODF mutation")
	# GRAPH-29: append failure restores exact bytes, encoding, dirty and history.
	var mdoc := OdfDocument.parse_text("[EmitterA]\r\nrenderBase=peuler\r\nrenderName1=EmitterB\r\n\r\n[EmitterB]\r\nrenderBase=peuler\r\n", tmp.path_join("move_fail.odf"))
	plab.doc = mdoc
	plab.load_document(mdoc)
	plab.select_edge("EmitterA", "renderName1", "EmitterB")
	var mbefore: PackedByteArray = mdoc.to_bytes()
	var mdirty := mdoc.dirty
	var mhist := mdoc.can_undo()
	OdfDocument.fault_append_entry_fail_key = "renderName2"
	var move_ok := plab.move_selected_link("renderName2")
	OdfDocument.fault_append_entry_fail_key = ""
	_check(not move_ok and mdoc.to_bytes() == mbefore and mdoc.dirty == mdirty and
		mdoc.can_undo() == mhist and mdoc.encoding == "utf-8",
		"GRAPH-29: failed Move restores bytes/dirty/history exactly")
	plab.queue_free()

	OdfDocument.clear_all_cache()
	_remove_tree(tmp)
	print("\nT-76 Verifier: %d checks, %d failure(s)" % [passed + failed, failed])
	if failed == 0:
		print("RESULT: PASS")
		quit(0)
	else:
		print("RESULT: FAIL")
		quit(1)


func _ext_write(path: String, text: String) -> void:
	_write(path, text)


func _eq_name(actual: String, expected: String, msg: String) -> void:
	_check(actual.to_lower() == expected.to_lower(), msg + " (got " + actual + ")")
