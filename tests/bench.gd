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

	# Wave E long-session soak benchmark: 1-min (3600 frames) & 10-min (36000 frames)
	# moving-target timeline compression + sandboxed concurrent replay + reset memory check.
	var CombatScenarioScript = preload("res://scripts/sim/combat_scenario.gd")
	var mem_pre_soak := OS.get_static_memory_usage()
	var scn_1m = CombatScenarioScript.new(9001)
	scn_1m.create_new_scenario(profile, target)
	scn_1m.capture_replay_baseline(profile)
	t0 = Time.get_ticks_usec()
	var pos1 := target
	var vel1 := Vector3(8.0, 0.0, 0.0)
	for f in range(3600):
		if f % 360 == 180:
			vel1 = -vel1
		pos1 += vel1 * (1.0 / 60.0)
		scn_1m.record_actor_transform("primary", pos1, vel1, 0.0)
		if f % 120 == 10:
			scn_1m.fire_shot(profile, Vector3(0, 1.8, 0), (pos1 - Vector3(0, 1.8, 0)).normalized(), pos1, [], Vector3.ZERO, false)
		scn_1m.advance(1.0 / 60.0)
	var soak1_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var st1: Dictionary = scn_1m.timeline_compression_stats()
	var snap1: Dictionary = scn_1m.save_replay_snapshot("bench_1m")
	t0 = Time.get_ticks_usec()
	var rep1: Dictionary = CombatScenarioScript.replay_snapshot_sandboxed(snap1)
	var rep1_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("soak_1m: 3600 frames in %.1f ms (timeline=%d, compressed=%d, replay=%.1f ms, ok=%s)" % [
		soak1_ms, int(st1.get("timeline_size", 0)), int(st1.get("compressed_count", 0)), rep1_ms, str(bool(rep1.get("ok", false)))
	])

	var scn_10m = CombatScenarioScript.new(9002)
	scn_10m.create_new_scenario(profile, target)
	scn_10m.capture_replay_baseline(profile)
	t0 = Time.get_ticks_usec()
	var pos10 := target
	var vel10 := Vector3(8.0, 0.0, 0.0)
	for f in range(36000):
		if f % 600 == 300:
			vel10 = -vel10
		pos10 += vel10 * (1.0 / 60.0)
		scn_10m.record_actor_transform("primary", pos10, vel10, 0.0)
		if f % 1200 == 30:
			scn_10m.fire_shot(profile, Vector3(0, 1.8, 0), (pos10 - Vector3(0, 1.8, 0)).normalized(), pos10, [], Vector3.ZERO, false)
		scn_10m.advance(1.0 / 60.0)
	var soak10_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var st10: Dictionary = scn_10m.timeline_compression_stats()
	scn_1m.reset("ALL")
	scn_10m.reset("ALL")
	var mem_post_reset := OS.get_static_memory_usage()
	print("soak_10m: 36000 frames in %.1f ms (timeline=%d, compressed=%d, mem_delta_after_reset=%.2f MB)" % [
		soak10_ms, int(st10.get("timeline_size", 0)), int(st10.get("compressed_count", 0)),
		float(mem_post_reset - mem_pre_soak) / (1024.0 * 1024.0)
	])
	print("memory: %.1f MB static" % (float(OS.get_static_memory_usage()) / (1024.0 * 1024.0)))
	print("RESULT: PASS (measurement only)")
	quit(0)
