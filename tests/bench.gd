extends SceneTree
## Headless benchmark harness. Measures the real local corpus; it asserts nothing
## about speed, it only reports numbers so regressions can be compared.
## godot --headless --script res://tests/bench.gd

const BASE := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/bz2r_res"
const WORKSHOP := "V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970"
const VSR_TANK := WORKSHOP + "/3532748119/Recycler_Variants/Standard/ISDF/Vehicles/ivtank_vsr.odf"
const VSR_SCAV := WORKSHOP + "/3532748119/Recycler_Variants/Standard/ISDF/Vehicles/ivscav_vsr.odf"
const PARSE_SAMPLE := 500


func _initialize() -> void:
	print("BENCH BZ_ODF_SHAMAN (Godot %s)" % Engine.get_version_info().string)
	if not DirAccess.dir_exists_absolute(BASE):
		printerr("base corpus missing: " + BASE)
		quit(2)
		return
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": BASE, "label": "base", "kind": "game", "priority": 10, "enabled": true},
		{"path": WORKSHOP, "label": "workshop", "kind": "workshop", "priority": 30, "enabled": true},
	]
	var t0 := Time.get_ticks_usec()
	idx.scan(true)
	var scan_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("index: %d ODFs, %d asset names in %.1f ms" % [idx.count(), idx.asset_count(), scan_ms])

	var keys := idx.files.keys()
	keys.sort()
	var sample: int = mini(PARSE_SAMPLE, keys.size())
	var bytes := 0
	t0 = Time.get_ticks_usec()
	for i in sample:
		var list: Array = idx.files[keys[i]]
		if list.is_empty():
			continue
		var doc := OdfDocument.load_file(str(list[0].path))
		if doc != null:
			bytes += doc.to_bytes().size()
	var parse_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var mb := float(bytes) / (1024.0 * 1024.0)
	print("parse: %d ODFs, %.2f MB in %.1f ms (%.1f MB/s)" % [
		sample, mb, parse_ms, (mb / (parse_ms / 1000.0)) if parse_ms > 0.0 else 0.0
	])

	var tank := OdfDocument.load_cached(VSR_TANK)
	OdfInheritance.clear_cache()
	t0 = Time.get_ticks_usec()
	var rows := 0
	for i in 100:
		OdfInheritance.clear_cache()
		rows = OdfInheritance.merged(tank, idx).size()
	var inh_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("inheritance: 100 cold merges of ivtank_vsr in %.1f ms (%.2f ms each, %d rows)" % [
		inh_ms, inh_ms / 100.0, rows
	])

	var profile := WeaponProfile.new()
	if not profile.resolve(idx, VSR_TANK, VSR_SCAV):
		printerr("scenario unresolved: " + "; ".join(profile.errors))
		quit(1)
		return
	var target := Vector3(0, 2.4, -80)
	var dir := (target - Vector3(0, 1.8, 0)).normalized()
	t0 = Time.get_ticks_usec()
	var hits := 0
	for i in 500:
		var r := ProjectileSim.run_once(profile, Vector3(0, 1.8, 0), dir, target)
		if str(r.kind) == "vehicle":
			hits += 1
	var sim_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("sim: 500 shots in %.1f ms (%.2f ms each, %d hits)" % [sim_ms, sim_ms / 500.0, hits])
	print("memory: %.1f MB static" % (float(OS.get_static_memory_usage()) / (1024.0 * 1024.0)))
	print("RESULT: PASS (measurement only)")
	quit(0)
