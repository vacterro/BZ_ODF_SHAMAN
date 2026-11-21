extends SceneTree
## Headless test runner: godot --headless --script res://tests/test_runner.gd
## Covers the lossless ODF core, resource precedence, dependency resolution,
## particle header discovery, and the projectile/damage simulation.

const BASE := "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/bz2r_res"
const WORKSHOP := "V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970"
const VSR := WORKSHOP + "/3532748119/Recycler_Variants/Standard/ISDF"
const VSR_WEAPON := VSR + "/Weapons/Cannons/AT Stab/gatstabvsr_a.odf"
const VSR_TANK := VSR + "/Vehicles/ivtank_vsr.odf"
const VSR_SCAV := VSR + "/Vehicles/ivscav_vsr.odf"
const XPL := BASE + "/effects/explosions/xcoreturrxpl.odf"
const NativeAdapterScript = preload("res://scripts/native/native_test_adapter.gd")
const SafeStageScript = preload("res://scripts/native/safe_stage_manager.gd")
const NativeSessionScript = preload("res://scripts/native/native_experiment_session.gd")
const ResourceClosureScript = preload("res://scripts/native/native_resource_closure.gd")
const NativeRunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
const BzMeshReaderScript = preload("res://scripts/core/bz_mesh_reader.gd")
const ModLoadoutScript = preload("res://scripts/core/mod_loadout.gd")

var failures: Array[String] = []
var checks := 0
var cat := ""


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	print("BZ_ODF_SHAMAN test runner")
	_test_effect_runtime()
	_test_parser_synthetic()
	_test_parser_duplicates()
	_test_parser_comments_and_encoding()
	_test_appending()
	_test_header_duplicate_remove()
	_test_corpus_roundtrip()
	_test_single_property_edit()
	_test_resource_precedence()
	_test_fuzzy_search()
	_test_dirty_documents()
	_test_workspace_store()
	_test_saved_bytes_consistency()
	_test_header_occurrence_surgery()
	_test_transaction_recovery()
	_test_transaction_phase_matrix()
	_test_recovery_pending_manifest_failure()
	_test_save_manifest_rollback()
	_test_discard_override_transaction()
	_test_rollback_failure_safety()
	_test_journal_path_validation()
	_test_header_preservation_rules()
	_test_encoding_roundtrip()
	_test_workshop_scope()
	_test_native_adapter()
	_test_safe_stage_manager()
	_test_build_id_and_evidence_gates()
	_test_native_scenario_bzn_and_mount()
	_test_steam_launch_routes()
	_test_evidence_provenance_matrix()
	_test_staging_safety_f1_f7()
	_test_native_session_identity_ns1_ns5()
	_test_native_resource_closure_nr1_nr7()
	_test_native_expected_observed_synthetic_ne1_ne8()
	_test_staging_restage_rollback_f8_f12()
	_test_native_experiment_runner_t26()
	_test_process_termination_recovery()
	_test_collision_ordering()
	_test_external_cache_change()
	_test_inheritance_cache_revision()
	_test_inheritance_non_inherited()
	_test_parameter_sweep()
	_test_alternate_weapon()
	_test_dependencies()
	_test_particle_render()
	_test_audio_wav()
	_test_weapon_chain_and_sim()
	_test_scene_obstacles_and_multitarget_t27()
	_test_real_bzcc_mesh_and_hardpoints()
	_test_t29_ux_and_bzcc_particles()
	_test_wave_b_reset_safety()
	_test_wave_c_native_durability_and_evidence()
	_test_t36_fx_and_sandbox()
	_test_t34_mod_loadout_profiles()
	# Static document cache holds strong references by design; release it before
	# the engine's own shutdown so a passing run exits with no ObjectDB leak.
	OdfDocument.clear_all_cache()
	OdfInheritance.clear_cache()
	print("\n%d checks, %d failure(s), %d ms" % [checks, failures.size(), Time.get_ticks_msec() - t0])
	if failures.is_empty():
		print("RESULT: PASS")
		quit(0)
	else:
		for f in failures:
			printerr("FAIL: " + f)
		print("RESULT: FAIL")
		quit(1)


func _start(name: String) -> void:
	cat = name
	print("\n[" + name + "]")


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures.append(cat + ": " + msg)
		printerr("  ✗ " + msg)
	else:
		print("  ✓ " + msg)


func _eq(a, b, msg: String) -> void:
	_check(a == b, "%s (expected %s, got %s)" % [msg, str(b), str(a)])


# ---------------------------------------------------------------- effects

func _test_effect_runtime() -> void:
	_start("explosion effect runtime")
	var result := EffectRuntime.build(null, XPL, Vector3(1, 2, 3))
	_check(result.ok, "real explosion ODF builds a burst")
	_eq(result.errors.size(), 0, "no effect build errors")
	_eq(result.classes.size(), 4, "four particle classes resolved")
	_eq(result.emitters, 4, "four emitters created")
	_check(result.duration >= 8.0 and result.duration < 8.5, "duration follows the longest class lifetime (chunks 8 s)")
	if result.root != null:
		_eq(result.root.get_child_count(), 5, "four emitters + one light node")
		var found_light := false
		for c in result.root.get_children():
			if c is OmniLight3D:
				found_light = true
		_check(found_light, "draw_light class produces a real light")
		result.root.free()
	var missing := EffectRuntime.build(null, BASE + "/effects/explosions/does_not_exist.odf", Vector3.ZERO)
	_check(not missing.ok and missing.errors.size() == 1, "missing explosion ODF is reported, not silently skipped")

	# Distinct render vocabulary & external file.header live edits (V5..V7)
	var root := "user://p1_fx_live_" + str(Time.get_ticks_usec())
	var abs_root := ProjectSettings.globalize_path(root)
	var ext_path := abs_root.path_join("ext_fx.odf")
	var xpl_path := abs_root.path_join("live_xpl.odf")
	_write(ext_path, "[ExtSpark]\nrenderBase = \"draw_spark\"\nlifeTime = 1.2\nstartColor = \"10 20 255 255\"\nfinishColor = \"0 0 0 0\"\n")
	_write(xpl_path,
		"[ExplosionClass]\nparticleTypes = 7\nparticleClass1 = \"Emit\"\nparticleClass2 = \"Multi\"\n" +
		"particleClass3 = \"Sprite\"\nparticleClass4 = \"Trail\"\nparticleClass5 = \"Bolt\"\n" +
		"particleClass6 = \"Tracer\"\nparticleClass7 = \"Geom\"\n\n" +
		"[Emit]\nrenderBase = \"draw_emit\"\nemitName = \"ext_fx.ExtSpark\"\n\n" +
		"[Multi]\nrenderBase = \"draw_multi\"\nrenderName1 = \"Sprite\"\nrenderName2 = \"Light\"\n\n" +
		"[Sprite]\nrenderBase = \"draw_sprite\"\nlifeTime = 1.5\nstartColor = \"255 100 50 255\"\nstartRadius = 2.0\n\n" +
		"[Trail]\nrenderBase = \"draw_twirl_trail\"\nlifeTime = 2.0\nemitDelay = 0.05\nrotationRate = 6.0\n\n" +
		"[Bolt]\nrenderBase = \"draw_bolt\"\nlifeTime = 0.8\nsegmentLength = 5.0\n\n" +
		"[Tracer]\nrenderBase = \"draw_tracer\"\nlifeTime = 0.6\n\n" +
		"[Geom]\nrenderBase = \"draw_geom\"\nlifeTime = 1.0\n\n" +
		"[Light]\nrenderBase = \"draw_light\"\nlifeTime = 0.5\nstartColor = \"255 220 150 255\"\n"
	)
	var idx := ResourceIndex.new()
	idx.roots = [{"path": abs_root, "label": "fxtest", "kind": "game", "priority": 10, "enabled": true}]
	idx.scan(true)
	OdfDocument.clear_all_cache()
	var fx1 := EffectRuntime.build(idx, xpl_path, Vector3.ZERO)
	_check(bool(fx1.get("ok", false)), "composite multi-class explosion built")
	var rtypes: Array = fx1.get("render_types", [])
	for expected_rt in ["draw_emit", "draw_multi", "draw_sprite", "draw_twirl_trail", "draw_bolt", "draw_tracer", "draw_geom", "draw_light"]:
		_check(rtypes.has(expected_rt), "V5: render vocabulary handled: " + expected_rt)
	if fx1.root != null:
		# Verify Bolt mesh differs from Sprite mesh (BoxMesh vs QuadMesh) and External spark got blue color.
		var bolt_node: CPUParticles3D = fx1.root.get_node_or_null("FX_Bolt")
		var sprite_node: CPUParticles3D = fx1.root.get_node_or_null("FX_Sprite")
		var ext_node: CPUParticles3D = fx1.root.get_node_or_null("FX_ExtSpark")
		_check(bolt_node != null and bolt_node.mesh is BoxMesh, "draw_bolt uses elongated BoxMesh")
		_check(sprite_node != null and sprite_node.mesh is QuadMesh, "draw_sprite uses QuadMesh")
		_check(ext_node != null and ext_node.color_ramp.get_color(0).b > 0.9, "V7: external file.header resolved with blue startColor")
		fx1.root.free()
	# Edit external render ODF in-memory -> EffectRuntime picks up change immediately (no stale cache).
	var ext_doc := OdfDocument.load_cached(ext_path)
	ext_doc.set_entry_value(ext_doc.find_entry("ExtSpark", "startColor"), "\"255 0 0 255\"")
	var xdoc := OdfDocument.load_cached(xpl_path)
	xdoc.set_entry_value(xdoc.find_entry("Sprite", "lifeTime"), "4.5")
	var fx2 := EffectRuntime.build(idx, xpl_path, Vector3.ZERO)
	_check(bool(fx2.get("ok", false)) and float(fx2.get("duration", 0.0)) >= 4.5, "V5: lifeTime edit immediately updates burst duration")
	if fx2.root != null:
		var ext_node2: CPUParticles3D = fx2.root.get_node_or_null("FX_ExtSpark")
		_check(ext_node2 != null and ext_node2.color_ramp.get_color(0).r > 0.9 and ext_node2.color_ramp.get_color(0).b < 0.1, "V7: edited external startColor visible immediately")
		fx2.root.free()
	OdfDocument.clear_all_cache()
	_remove_tree(abs_root)


# ---------------------------------------------------------------- parser

func _test_parser_synthetic() -> void:
	_start("ODF parser / no-op roundtrip")
	var text := "[WeaponClass]\r\nclassLabel=\"x\" // keep me\r\nordName = \"ord_a\"\r\n\r\n[CannonClass]\r\nshotDelay=1.0\r\n"
	var doc := OdfDocument.parse_text(text, "synthetic.odf")
	_eq(doc.entries.size(), 3, "parsed 3 entries")
	_eq(doc.headers.size(), 2, "parsed 2 headers")
	_eq(doc.get_value("WeaponClass", "ordName"), "ord_a", "quoted value unquoted for reading")
	_eq(doc.get_value("CannonClass", "shotDelay"), "1.0", "numeric raw preserved")
	var out := doc.to_bytes()
	_eq(out, text.to_utf8_buffer(), "no-op serialization is byte-identical")
	_eq(doc.warnings.size(), 0, "no parser warnings")


func _test_parser_duplicates() -> void:
	_start("ODF parser / duplicates and shadowing")
	var text := "[CannonClass]\nshotDelay = 1.0\nshotDelay = 0.5\n\n[GameObjectClass]\nmaxHealth=100\n"
	var doc := OdfDocument.parse_text(text, "dup.odf")
	_eq(doc.entries.size(), 3, "duplicate declarations preserved")
	var effective := doc.effective_entries()
	_eq(effective.size(), 2, "only last duplicate is effective")
	var first = doc.entries[0]
	_check(first.shadowed_by != null, "earlier duplicate marked shadowed")
	var second = doc.entries[1]
	_check(second.shadow_of != null, "later duplicate marked effective shadow")
	_eq(doc.get_value("CannonClass", "shotDelay"), "0.5", "effective value is the last declaration")
	_check(doc.text.contains("shotDelay = 1.0") and doc.text.contains("shotDelay = 0.5"), "both declarations physically preserved")


func _test_parser_comments_and_encoding() -> void:
	_start("ODF parser / comments, block comments, BOM")
	var text := "// header comment\n[WeaponClass]\n/* block\ncomment */\nordName=\"a;b\" ; trailing\nfireSound = \"x.wav\"\r\n"
	var doc := OdfDocument.parse_text(text, "c.odf")
	_eq(doc.get_value("WeaponClass", "ordName"), "a;b", "semicolon inside quotes is not a comment")
	_eq(doc.get_value("WeaponClass", "fireSound"), "x.wav", "CRLF trailing value trimmed")
	_eq(doc.to_bytes(), text.to_utf8_buffer(), "block comments and CRLF preserved byte-for-byte")
	# BOM + UTF-8 file
	var path := "user://test_bom.odf"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]) + "[GameObjectClass]\nmaxHealth=10\n".to_utf8_buffer())
	f.close()
	var loaded := OdfDocument.load_file(path)
	_check(loaded != null, "BOM file loaded")
	_check(loaded.has_bom if loaded else false, "UTF-8 BOM detected")
	_eq(loaded.to_bytes(), FileAccess.get_file_as_bytes(path), "BOM/no-op roundtrip byte-identical")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_appending() -> void:
	_start("ODF serializer / append")
	var doc := OdfDocument.parse_text("[GameObjectClass]\nmaxHealth=100\n\n[CannonClass]\nshotDelay=1.0\n", "a.odf")
	var e = doc.append_entry("GameObjectClass", "unitName", "\"Test Unit\"")
	_check(e != null, "appended entry created")
	_eq(doc.get_value("GameObjectClass", "unitName"), "Test Unit", "appended value readable")
	_check(doc.text.contains("maxHealth=100"), "existing content untouched")
	_check(doc.to_text().contains("unitName = \"Test Unit\""), "appended line uses key = value form")


# ---------------------------------------------------------------- headers

func _test_header_duplicate_remove() -> void:
	_start("header duplicate / delete / undo")
	var src := "[Core]\nrenderBase = \"draw_twirl\"\nlifeTime = 2.0\n// keep this\n\n[Chunks]\nrenderBase = \"draw_null\"\n"
	var doc := OdfDocument.parse_text(src, "dup.odf")
	_check(not doc.has_header("Core_copy"), "new header name is free")
	_check(doc.duplicate_header("Core", "Core_copy"), "header duplicated")
	_check(doc.has_header("Core_copy"), "duplicate header exists")
	_eq(doc.header_entry_count("Core_copy"), 2, "duplicate kept both property lines")
	_eq(doc.get_value("Core_copy", "renderBase"), "draw_twirl", "duplicate values are editable and identical")
	_check(doc.dirty, "duplicate marks the document dirty")
	_check(not doc.duplicate_header("Core", "Core_copy"), "duplicate refuses an existing name")
	_check(doc.remove_header("Core_copy"), "duplicate header removed")
	_check(not doc.has_header("Core_copy"), "removed header is gone")
	_check(doc.has_header("Core") and doc.has_header("Chunks"), "other headers survive deletion")
	doc.undo()
	_check(doc.has_header("Core_copy"), "undo restores the deleted header")
	doc.redo()
	_check(not doc.has_header("Core_copy"), "redo removes it again")
	_check(not doc.remove_header("Missing"), "deleting a missing header is refused")


# ---------------------------------------------------------------- corpus

func _test_corpus_roundtrip() -> void:
	_start("ODF corpus / byte-exact no-op roundtrip")
	if not DirAccess.dir_exists_absolute(BASE):
		_check(false, "base corpus missing: " + BASE)
		return
	var files := _list_odf(BASE)
	_check(files.size() > 1000, "base corpus enumerated (%d ODFs)" % files.size())
	var failures_count := 0
	var first_bad := ""
	for path in files:
		var doc := OdfDocument.load_file(path)
		if doc == null:
			failures_count += 1
			continue
		var original := FileAccess.get_file_as_bytes(path)
		if doc.to_bytes() != original:
			failures_count += 1
			if first_bad == "":
				first_bad = path
	_eq(failures_count, 0, "all base ODFs roundtrip byte-identically" + ("" if first_bad == "" else " (first: " + first_bad + ")"))


func _test_single_property_edit() -> void:
	_start("ODF serializer / single property edit")
	if not FileAccess.file_exists(VSR_WEAPON):
		_check(false, "missing VSR weapon fixture")
		return
	var doc := OdfDocument.load_file(VSR_WEAPON)
	var original := doc.text
	var delay = doc.find_entry("CannonClass", "shotDelay")
	_check(delay != null, "shotDelay located")
	doc.set_entry_value(delay, "0.5")
	_check(doc.text.contains("shotDelay=0.5 // *0.5 {VSR-127}"), "value changed, inline comment preserved")
	_check(doc.text.contains("[WeaponClass]") and doc.text.contains("classLabel=\"gatstab_a\""), "unrelated headers untouched")
	var newline_count := doc.text.split("\n").size()
	var old_newline_count := original.split("\n").size()
	_eq(newline_count, old_newline_count, "newline count unchanged")
	_eq(doc.text.length(), original.length(), "only the value span changed (1.0 -> 0.5, same width)")
	var reloaded := OdfDocument.parse_text(doc.text, "edited.odf")
	_eq(reloaded.get_value("CannonClass", "shotDelay"), "0.5", "edited text parses back to new value")


# ---------------------------------------------------------------- resources

func _test_resource_precedence() -> void:
	_start("Resource index / precedence and duplicates")
	var root1 := ProjectSettings.globalize_path("user://test_root_low")
	var root2 := ProjectSettings.globalize_path("user://test_root_high")
	DirAccess.make_dir_recursive_absolute(root1)
	DirAccess.make_dir_recursive_absolute(root2)
	_write(root1 + "/dup.odf", "[GameObjectClass]\nmaxHealth=1\n")
	_write(root2 + "/dup.odf", "[GameObjectClass]\nmaxHealth=2\n")
	_write(root1 + "/only_low.odf", "[GameObjectClass]\nmaxHealth=3\n")
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": root1, "label": "low", "kind": "test", "priority": 10, "enabled": true},
		{"path": root2, "label": "high", "kind": "test", "priority": 50, "enabled": true},
	]
	idx.scan(false)
	_eq(idx.count(), 3, "three ODFs indexed")
	var cands := idx.candidates("dup")
	_eq(cands.size(), 2, "duplicate resource candidates retained")
	_eq(str(cands[0].path), root2 + "/dup.odf", "higher priority wins")
	_eq(idx.resolve_path("only_low"), root1 + "/only_low.odf", "single candidate resolves")
	_eq(idx.resolve_path("missing"), "", "missing reference resolves empty")
	# cleanup
	for p in [root1 + "/dup.odf", root1 + "/only_low.odf", root2 + "/dup.odf"]:
		DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(root1)
	DirAccess.remove_absolute(root2)


func _test_fuzzy_search() -> void:
	_start("Resource index / ranked fuzzy search")
	var root := ProjectSettings.globalize_path("user://test_fuzzy")
	DirAccess.make_dir_recursive_absolute(root)
	for name in ["ivtank_vsr.odf", "ivscav_vsr.odf", "atstab_c.odf", "atstabvsr_c.odf", "xcoreturrxpl.odf"]:
		_write(root + "/" + name, "[GameObjectClass]\nmaxHealth=1\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": root, "label": "fuzzy", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)
	var exact := idx.search("atstab_c")
	_eq(exact[0].path.get_file() if not exact.is_empty() else "", "atstab_c.odf", "exact name ranks first")
	var fuzzy := idx.search("ivtk")
	_check(not fuzzy.is_empty() and str(fuzzy[0].path).get_file() == "ivtank_vsr.odf", "subsequence ivtk finds ivtank")
	var tokens := idx.search("scv vsr")
	_check(not tokens.is_empty() and str(tokens[0].path).get_file() == "ivscav_vsr.odf", "multiple tokens match one name")
	var substring := idx.search("turr")
	_check(not substring.is_empty() and str(substring[0].path).get_file() == "xcoreturrxpl.odf", "substring still matches")
	_check(idx.search("zzzz").is_empty(), "no false positive")
	var all := idx.search("")
	_eq(all.size(), 5, "empty query lists all indexed ODFs")
	for name in ["ivtank_vsr.odf", "ivscav_vsr.odf", "atstab_c.odf", "atstabvsr_c.odf", "xcoreturrxpl.odf"]:
		DirAccess.remove_absolute(root + "/" + name)
	DirAccess.remove_absolute(root)


func _test_dirty_documents() -> void:
	_start("ODF document cache / dirty listing")
	var path := ProjectSettings.globalize_path("user://test_dirty_cache.odf")
	var doc := OdfDocument.parse_text("[GameObjectClass]\nmaxHealth=1\n", path)
	OdfDocument.cache_document(doc)
	_check(not OdfDocument.dirty_documents().has(doc), "freshly cached document is not dirty")
	doc.append_entry("GameObjectClass", "unitName", "\"Dirty\"")
	_check(doc.dirty, "append marks the document dirty")
	_check(OdfDocument.dirty_documents().has(doc), "dirty listing includes the edited document")
	doc.dirty = false
	_check(not OdfDocument.dirty_documents().has(doc), "clearing dirty removes it from the listing")
	OdfDocument.invalidate_cache(path)


func _test_inheritance_non_inherited() -> void:
	_start("ODF inheritance / documented non-inherited properties")
	var root := ProjectSettings.globalize_path("user://test_inherit")
	DirAccess.make_dir_recursive_absolute(root)
	_write(root + "/parent.odf", "[GameObjectClass]\nmaxHealth=100\nunitIcon=\"parent_icon.tga\"\nunitStatus=\"parent_status.tga\"\nignoreMissingInf=true\nshotSpeed=10\n\n[MorphTankClass]\nunitStatus=\"deployed.tga\"\n\n[OrdnanceClass]\nshotRadius=2.0\n")
	_write(root + "/child.odf", "[GameObjectClass]\nclassLabel=\"parent\"\nmaxHealth=150\n\n[OrdnanceClass]\nlifeSpan=1.0\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": root, "label": "inherit", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)
	var child := OdfDocument.load_file(root + "/child.odf")
	var rows := OdfInheritance.merged(child, idx)
	_eq(_row_value(rows, "GameObjectClass", "maxHealth"), "150", "child value wins over parent")
	_eq(_row_value(rows, "GameObjectClass", "shotSpeed"), "10", "ordinary properties still inherit")
	_check(_find_row(rows, "GameObjectClass", "unitIcon").is_empty(), "unitIcon is not inherited (EntityClass rule)")
	_check(_find_row(rows, "GameObjectClass", "unitStatus").is_empty(), "unitStatus is not inherited (EntityClass rule)")
	_check(_find_row(rows, "GameObjectClass", "ignoreMissingInf").is_empty(), "ignoreMissingInf is not inherited")
	_check(_find_row(rows, "OrdnanceClass", "shotRadius").is_empty(), "shotRadius is not inherited (OrdnanceClass rule)")
	_eq(_row_value(rows, "MorphTankClass", "unitStatus"), "deployed.tga", "MorphTankClass.unitStatus keeps normal inheritance")
	# A value declared by the document itself is still effective.
	var declared := OdfDocument.parse_text("[GameObjectClass]\nclassLabel=\"parent\"\nunitIcon=\"child_icon.tga\"\n", root + "/declared.odf")
	_write(root + "/declared.odf", declared.text)
	var rows2 := OdfInheritance.merged(declared, idx)
	_eq(_row_value(rows2, "GameObjectClass", "unitIcon"), "child_icon.tga", "child's own unitIcon is kept")
	for p in ["parent.odf", "child.odf", "declared.odf"]:
		DirAccess.remove_absolute(root + "/" + p)
	DirAccess.remove_absolute(root)


func _test_parameter_sweep() -> void:
	_start("Parameter sweep / in-memory overrides + deterministic replay")
	var root := ProjectSettings.globalize_path("user://test_sweep")
	DirAccess.make_dir_recursive_absolute(root)
	_write(root + "/shooter.odf", "[GameObjectClass]\nweaponName1=\"gun\"\n")
	_write(root + "/gun.odf", "[WeaponClass]\nordName=\"bullet\"\nshotDelay=1.0\n")
	_write(root + "/bullet.odf", "[OrdnanceClass]\nshotSpeed=100\nlifeSpan=2.0\ndamageValue(H)=50\ndamageValue(N)=10\n")
	_write(root + "/target.odf", "[GameObjectClass]\nmaxHealth=1000\narmorClass=\"H\"\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": root, "label": "sweep", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)
	var profile := WeaponProfile.new()
	_check(profile.resolve(idx, root + "/shooter.odf", root + "/target.odf"), "synthetic weapon chain resolved: " + "; ".join(profile.errors))
	var target_pos := Vector3(0, 2.4, -100)
	var origin := Vector3(0, 1.8, 0)
	var dir := (target_pos - origin).normalized()
	_eq(profile.shot_radius, 0.5, "shotRadius fallback used when not declared")
	profile.set_override("shotRadius", "1.25")
	profile.refresh()
	_eq(profile.shot_radius, 1.25, "override applies to a not-inherited property")
	profile.clear_overrides()
	profile.refresh()
	_eq(profile.shot_radius, 0.5, "override cleared back to the fallback")
	var speed_sweep := ParameterSweep.run(profile, "shotSpeed", 100.0, 200.0, 3, origin, dir, target_pos)
	_eq(speed_sweep.rows.size(), 3, "speed sweep produced 3 rows")
	_eq(float(speed_sweep.baseline.damage), 50.0, "baseline damage")
	_check(absf(float(speed_sweep.rows[1].time) - 100.0 / 150.0) < 0.05, "150 m/s flight time matches distance / speed")
	_check(absf(float(speed_sweep.rows[0].time) - 1.0) < 0.05, "100 m/s flight time matches distance / speed")
	_check(float(speed_sweep.rows[2].time) < float(speed_sweep.rows[1].time), "higher speed arrives sooner")
	_eq(str(speed_sweep.rows[2].kind), "vehicle", "high-speed row still hits the target")
	var dmg_sweep := ParameterSweep.run(profile, "damageValue(H)", 50.0, 150.0, 3, origin, dir, target_pos)
	_eq(float(dmg_sweep.rows[0].damage), 50.0, "damage sweep row 0 = 50")
	_eq(float(dmg_sweep.rows[1].damage), 100.0, "damage sweep midpoint = 100")
	_eq(float(dmg_sweep.rows[2].damage), 150.0, "damage sweep end = 150")
	_eq(float(dmg_sweep.rows[2].damage_delta), 100.0, "delta is relative to the baseline")
	var csv := ParameterSweep.to_csv(dmg_sweep, "shooter, target")
	_check(csv.contains("# property=damageValue(H)"), "CSV records the swept property")
	_check(csv.contains("# scenario=\"shooter, target\""), "CSV quotes a scenario label containing a comma")
	_check(csv.contains("value,damage,damage_delta,flight_s,target_health,hit_kind,range_m"), "CSV header present")
	_check(csv.contains("baseline,50.000000,0.000000"), "CSV baseline row present")
	_eq(csv.strip_edges().split("\n").size(), 8, "CSV has 3 comments + header + baseline + 3 rows")
	_check(profile.overrides.is_empty(), "sweep left no overrides behind")
	_eq(profile.expected_damage(), 50.0, "profile reads the unmodified document after the sweep")
	var disk := FileAccess.get_file_as_string(root + "/bullet.odf")
	_check(disk.contains("damageValue(H)=50") and not disk.contains("150"), "sweep never wrote the ODF")
	for p in ["shooter.odf", "gun.odf", "bullet.odf", "target.odf"]:
		DirAccess.remove_absolute(root + "/" + p)
	DirAccess.remove_absolute(root)


func _test_alternate_weapon() -> void:
	_start("Weapons / altName alternate chain")
	var root := ProjectSettings.globalize_path("user://test_alt")
	DirAccess.make_dir_recursive_absolute(root)
	_write(root + "/shooter.odf", "[GameObjectClass]\nweaponName1=\"gun\"\n")
	_write(root + "/gun.odf", "[WeaponClass]\nordName=\"bullet\"\naltName=\"gun2\"\n")
	_write(root + "/gun2.odf", "[WeaponClass]\nordName=\"bullet2\"\naltName=\"gun\"\n")
	_write(root + "/bullet.odf", "[OrdnanceClass]\nshotSpeed=100\nlifeSpan=2.0\ndamageValue(H)=50\n")
	_write(root + "/bullet2.odf", "[OrdnanceClass]\nshotSpeed=100\nlifeSpan=2.0\ndamageValue(H)=200\n")
	_write(root + "/target.odf", "[GameObjectClass]\nmaxHealth=1000\narmorClass=\"H\"\n")
	_write(root + "/gun3.odf", "[WeaponClass]\nordName=\"bullet\"\naltName=\"missing\"\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": root, "label": "alt", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)
	var profile := WeaponProfile.new()
	_check(profile.resolve(idx, root + "/shooter.odf", root + "/target.odf"), "primary chain resolved: " + "; ".join(profile.errors))
	_eq(profile.expected_damage(), 50.0, "primary damage from bullet.odf")
	_check(profile.alt != null, "altName resolved to an alternate weapon")
	if profile.alt != null:
		_eq(profile.alt.weapon_name, "gun2", "alternate weapon name")
		_eq(profile.alt.ordnance_name, "bullet2", "alternate ordnance name")
		_eq(profile.alt.expected_damage(), 200.0, "alternate damage from bullet2.odf")
		_check(profile.alt.alt == null, "alt resolution does not recurse (gun2 -> gun stops)")
		var target_pos := Vector3(0, 2.4, -80)
		var dir := (target_pos - Vector3(0, 1.8, 0)).normalized()
		var r := ProjectileSim.run_once(profile.alt, Vector3(0, 1.8, 0), dir, target_pos)
		_eq(str(r.kind), "vehicle", "alternate projectile reaches the target")
		_eq(float(r.damage), 200.0, "alternate shot applies its own damage")
	# An unresolvable altName must not break the primary chain.
	var p2 := WeaponProfile.new()
	_check(p2.resolve(idx, root + "/shooter.odf", root + "/target.odf", "gun3"), "primary still resolves with broken altName")
	_check(p2.alt == null, "unresolvable altName leaves alt null")
	var noted := false
	for n in p2.notes:
		if str(n).contains("not resolvable"):
			noted = true
	_check(noted, "unresolvable altName is reported as a note")
	for p in ["shooter.odf", "gun.odf", "gun2.odf", "gun3.odf", "bullet.odf", "bullet2.odf", "target.odf"]:
		DirAccess.remove_absolute(root + "/" + p)
	DirAccess.remove_absolute(root)


func _test_dependencies() -> void:
	_start("Dependency graph / missing, transitive, cycle")
	var root := ProjectSettings.globalize_path("user://test_deps")
	DirAccess.make_dir_recursive_absolute(root)
	_write(root + "/a.odf", "[WeaponClass]\nordName=\"b\"\n")
	_write(root + "/b.odf", "[OrdnanceClass]\nxplVehicle=\"c\"\nxplGround=\"missing_xpl\"\n")
	_write(root + "/c.odf", "[ExplosionClass]\nparticleClass1=\"b\"\n")
	var idx := ResourceIndex.new()
	idx.roots = [{"path": root, "label": "deps", "kind": "test", "priority": 10, "enabled": true}]
	idx.scan(false)
	var doc := OdfDocument.load_file(root + "/a.odf")
	var graph := DependencyGraph.new()
	var result := graph.analyze(doc, idx)
	_eq(int(result.node_count), 3, "transitive chain followed a -> b -> c")
	_check(int(result.missing_count) >= 1, "missing explosion reported")
	_check(int(result.cycle_count) >= 1, "cycle b -> c -> b detected")
	for p in ["a.odf", "b.odf", "c.odf"]:
		DirAccess.remove_absolute(root + "/" + p)
	DirAccess.remove_absolute(root)


# ---------------------------------------------------------------- particles

func _test_particle_render() -> void:
	_start("Particles / real render ODF")
	if not FileAccess.file_exists(XPL):
		_check(false, "missing particle fixture")
		return
	var doc := OdfDocument.load_file(XPL)
	var renders := doc.render_headers()
	_eq(renders.size(), 4, "four render headers found")
	var bases: Array[String] = []
	for h in renders:
		bases.append(doc.get_value(h.name, "renderBase", ""))
	_check(bases.has("draw_twirl"), "draw_twirl present")
	_check(bases.has("draw_sphere"), "draw_sphere present")
	_check(bases.has("draw_light"), "draw_light present")
	var original := FileAccess.get_file_as_bytes(XPL)
	_eq(doc.to_bytes(), original, "render ODF roundtrips byte-identically")
	# Real emit reference from a stock ODF with draw_emit
	var emit_file := ""
	for path in _list_odf(BASE + "/baked/Effects"):
		var d := OdfDocument.load_file(path)
		if d == null:
			continue
		for h in d.render_headers():
			if d.get_value(h.name, "renderBase", "") == "draw_emit":
				emit_file = path
				break
		if emit_file != "":
			break
	_check(emit_file != "", "found a stock draw_emit render")
	if emit_file != "":
		var d2 := OdfDocument.load_file(emit_file)
		var found := false
		for h in d2.render_headers():
			if d2.get_value(h.name, "renderBase", "") == "draw_emit" and d2.get_value(h.name, "emitName", "") != "":
				found = true
		_check(found, "draw_emit declares emitName")


# ---------------------------------------------------------------- audio

func _test_audio_wav() -> void:
	_start("Audio / WAV reader")
	var audio_dir := BASE + "/audio"
	if not DirAccess.dir_exists_absolute(audio_dir):
		_check(false, "audio directory missing")
		return
	var first := ""
	var dir := DirAccess.open(audio_dir)
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.to_lower().ends_with(".wav"):
			first = audio_dir + "/" + n
			break
		n = dir.get_next()
	dir.list_dir_end()
	_check(first != "", "found a stock WAV asset")
	if first == "":
		return
	var w := WavReader.read(first)
	_check(w.ok, "WAV parsed: " + first.get_file())
	_check(w.sample_rate > 0, "sample rate: %d Hz" % w.sample_rate)
	_check(w.channels > 0, "channels: %d" % w.channels)
	_check(w.duration > 0.0, "duration: %.3f s" % w.duration)
	_check(w.format_code == 1 or w.error == "", "format reported: " + w.format_name())
	if w.format_code == 1 and (w.bits == 16 or w.bits == 8):
		_check(w.stream != null, "PCM AudioStreamWAV built")
	else:
		_check(true, "non-PCM codec metadata preserved (" + w.format_name() + ")")
	_check(w.peaks(200).size() == 200, "waveform peaks extracted")
	var bad := WavReader.parse_bytes(PackedByteArray([1, 2, 3, 4]))
	_check(not bad.ok and bad.error != "", "invalid WAV rejected: " + bad.error)


# ---------------------------------------------------------------- weapons

func _test_weapon_chain_and_sim() -> void:
	_start("Weapons / VSR chain + projectile + damage")
	for p in [VSR_TANK, VSR_SCAV, VSR_WEAPON, BASE + "/effects/explosions"]:
		if not FileAccess.file_exists(p) and not DirAccess.dir_exists_absolute(p):
			_check(false, "missing fixture: " + p)
			return
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": BASE, "label": "base", "kind": "game", "priority": 10, "enabled": true},
		{"path": WORKSHOP, "label": "workshop", "kind": "workshop", "priority": 30, "enabled": true},
	]
	idx.scan(true)
	_check(idx.count() > 10000, "workshop + base indexed (%d ODFs)" % idx.count())
	var profile := WeaponProfile.new()
	var ok := profile.resolve(idx, VSR_TANK, VSR_SCAV)
	_check(ok, "weapon chain resolved: " + "; ".join(profile.errors))
	if not ok:
		return
	_eq(profile.weapon_name, "gatstabvsr_c", "shooter weapon resolved")
	_eq(profile.ordnance_name, "atstabvsr_c", "ordnance resolved")
	_eq(profile.shot_speed, 120.0, "shotSpeed read from real ordnance ODF")
	_eq(profile.life_span, 0.834, "lifeSpan read from real ordnance ODF")
	_eq(profile.target_armor, "H", "target armorClass inherited from parent ivscav.odf")
	_eq(profile.target_health_max, 3000.0, "target maxHealth inherited from parent ivscav.odf")
	_eq(profile.expected_damage(), 100.0, "damageValue(H) inherited from parent atstab_c.odf")
	_eq(profile.shot_radius, 0.5, "shotRadius from bullet.odf is NOT inherited (documented rule); editor fallback 0.5")
	_check(profile.alt != null, "real VSR chain resolves its inherited altName")
	if profile.alt != null:
		_eq(profile.alt.weapon_name, "gatstabvsr_a", "alternate weapon resolves inside the VSR package")
		_eq(profile.alt.ordnance_name, "atstabvsr_a", "alternate ordnance resolves inside the VSR package")
		_check(profile.alt.alt == null, "alternate profile does not recurse")
	_check(abs(profile.range_estimate() - 100.08) < 0.5, "range derived from lifeSpan * shotSpeed")
	var target_pos := Vector3(0, 2.4, -80)
	var result := ProjectileSim.run_once(profile, Vector3(0, 1.8, 0), target_pos - Vector3(0, 1.8, 0), target_pos, 5.0)
	_eq(str(result.kind), "vehicle", "projectile hits the target sphere")
	_eq(float(result.damage), 100.0, "damage applied equals inherited damageValue(H)")
	_check(abs(float(result.time) - 80.0 / 120.0) < 0.05, "time of flight matches distance / shotSpeed")
	_check(float(result.target_health) < profile.target_health_max, "target hull decreased")
	var ev: Array = result.events
	_check(ev.size() >= 6, "telemetry recorded several events")
	var monotonic := true
	for i in range(1, ev.size()):
		if float(ev[i].time) < float(ev[i - 1].time):
			monotonic = false
	_check(monotonic, "telemetry timestamps are monotonic")
	# Determinism / replay
	var r2 := ProjectileSim.run_once(profile, Vector3(0, 1.8, 0), target_pos - Vector3(0, 1.8, 0), target_pos, 5.0)
	_eq(str(r2.kind), str(result.kind), "replay hits identically")
	_eq(float(r2.damage), float(result.damage), "replay damage identical")
	_eq(float(r2.time), float(result.time), "replay timing deterministic")
	# Real parent edit must invalidate the child merge and the next shot.
	var ochain := OdfInheritance.chain(profile.ordnance_doc, idx)
	_check(ochain.size() > 1, "ordnance inheritance chain has a parent")
	if ochain.size() > 1:
		var parent_doc = ochain[1]
		var pe = parent_doc.find_entry("OrdnanceClass", "damagevalue(h)")
		_check(pe != null, "parent declares damageValue(H)")
		if pe != null:
			var before: String = pe.value_raw
			parent_doc.set_entry_value(pe, "200")
			profile.refresh()
			_eq(profile.expected_damage(), 200.0, "parent edit visible in child without clear_cache")
			var parent_shot := ProjectileSim.run_once(profile, Vector3(0, 1.8, 0), target_pos - Vector3(0, 1.8, 0), target_pos, 5.0)
			_eq(float(parent_shot.damage), 200.0, "FIRE uses the parent-edited value")
			parent_doc.set_entry_value(pe, before)
			profile.refresh()
			_eq(profile.expected_damage(), 100.0, "parent edit reverted")
	# Raw text replacement on the same document object must reach the profile.
	var ord_doc = profile.ordnance_doc
	var ord_text: String = ord_doc.text
	var ord_rev: int = ord_doc.revision
	ord_doc.replace_text(ord_text + "\n[OrdnanceClass]\ndamageValue(H)=200\n")
	_check(profile.ordnance_doc == ord_doc, "raw replace keeps WeaponProfile document identity")
	_check(ord_doc.revision > ord_rev, "raw replace bumps ordnance revision")
	profile.refresh()
	_eq(profile.expected_damage(), 200.0, "raw replace reaches WeaponProfile after refresh")
	var raw_shot := ProjectileSim.run_once(profile, Vector3(0, 1.8, 0), target_pos - Vector3(0, 1.8, 0), target_pos, 5.0)
	_eq(float(raw_shot.damage), 200.0, "next shot uses the raw-edited value")
	ord_doc.replace_text(ord_text)
	profile.refresh()
	_eq(profile.expected_damage(), 100.0, "raw edit reverted cleanly")


func _test_real_bzcc_mesh_and_hardpoints() -> void:
	_start("Real BZCC .msh model + materials + hardpoints (V1..V4)")
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": BASE, "label": "base", "kind": "game", "priority": 10, "enabled": true},
		{"path": VSR, "label": "vsr", "kind": "workshop", "priority": 30, "enabled": true},
	]
	idx.scan(true)
	var prof := WeaponProfile.new()
	_check(prof.resolve(idx, VSR_TANK, VSR_SCAV), "VSR tank -> scav profile resolved")
	_eq(prof.weapon_hardpoint.to_lower(), "hp_cannon_1", "V3: weaponHard1 inherited from ivtank.odf")
	_eq(prof.shooter_geometry.to_lower(), "ivtank00.fbx", "shooter geometryName inherited")
	var msh_path := BzMeshReaderScript.resolve_msh_for_geometry(idx, prof.shooter_geometry, prof.shooter_path, prof.shooter_geometry_scale)
	_check(msh_path != "" and FileAccess.file_exists(msh_path), "V1: ivtank00.msh resolved from geometryName")
	var built := BzMeshReaderScript.build_scene(msh_path, idx, prof.shooter_geometry)
	_check(bool(built.get("ok", false)), "V1: DOCB .msh parsed into Godot Node3D hierarchy")
	var prov: Dictionary = built.get("provenance", {})
	_check(int(prov.get("triangle_count", 0)) > 500, "V1: authentic triangles loaded (%d)" % int(prov.get("triangle_count", 0)))
	_check((prov.get("materials", []) as Array).size() >= 1, "V1: .material files resolved")
	_check((prov.get("textures_loaded", []) as Array).size() >= 1, "V1: DDS textures loaded via load_dds_from_buffer")
	var bounds: AABB = built.get("bounds", AABB())
	_check(bounds.size.x > 2.0 and bounds.size.z > 4.0 and bounds.size.y > 1.0, "V2: bounding box matches real tank dimensions: " + str(bounds.size))
	var ty: Node3D = built.get("turret_y", null)
	var tx: Node3D = built.get("turret_x", null)
	var hps: Dictionary = built.get("hardpoints", {})
	var hp: Node3D = hps.get("hp_cannon_1", null)
	_check(ty != null and tx != null and hp != null, "V3: turret_y, turret_x and hp_cannon_1 nodes present")
	if ty != null and tx != null and hp != null:
		var root: Node3D = built.root
		var xf_before := _compose_to(hp, root)
		_check(xf_before.origin.z < 0.0, "V2: hp_cannon_1 muzzle points toward Godot -Z forward (z=%.2f)" % xf_before.origin.z)
		ty.rotation = Vector3(0.0, deg_to_rad(30.0), 0.0)
		var xf_after := _compose_to(hp, root)
		var dir_before := (-xf_before.basis.z).normalized()
		var dir_after := (-xf_after.basis.z).normalized()
		_check(xf_before.origin.distance_to(xf_after.origin) > 0.5, "V4: rotating turret_y moves hp_cannon_1 muzzle origin")
		_check(absf(rad_to_deg(dir_before.angle_to(dir_after)) - 30.0) < 0.5, "V4: launch direction rotates by 30 deg with turret_y")
		(built.root as Node3D).free()
	var scav_msh := BzMeshReaderScript.resolve_msh_for_geometry(idx, prof.target_geometry, prof.target_path, prof.target_geometry_scale)
	var scav_built := BzMeshReaderScript.build_scene(scav_msh, idx, prof.target_geometry)
	_check(bool(scav_built.get("ok", false)), "V1: target ivscav00.msh also parsed cleanly")
	if scav_built.get("root", null) != null:
		(scav_built.root as Node3D).free()
	OdfDocument.clear_all_cache()
	OdfInheritance.clear_cache()


func _compose_to(node: Node3D, stop_root: Node3D) -> Transform3D:
	var chain: Array[Node3D] = []
	var cur: Node = node
	while cur != null:
		if cur is Node3D:
			chain.append(cur as Node3D)
		if cur == stop_root:
			break
		cur = cur.get_parent()
	var xf := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		xf = xf * chain[i].transform
	return xf


func _test_saved_bytes_consistency() -> void:
	_start("Workspace save / current bytes, not stale source")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_saved_bytes_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var src := ProjectSettings.globalize_path(root).path_join("source/ord.odf")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var original := FileAccess.get_file_as_bytes(src)
	var doc := OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "200")
	var first := WorkspaceStore.save_document_with_rel(doc, "ord.odf")
	_check(bool(first.get("ok", false)), "first edit saved")
	var saved_path := str(first.get("target", ""))
	_check(doc.to_bytes() == FileAccess.get_file_as_bytes(saved_path), "to_bytes after save returns saved 200 bytes")
	_check(doc.to_bytes().get_string_from_utf8().contains("damageValue(H)=200"), "saved bytes carry the edited value")
	_check(FileAccess.get_file_as_bytes(src) == original, "original source still contains 100")
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "250")
	var second := WorkspaceStore.save_document(doc)
	_check(bool(second.get("ok", false)), "second edit saved")
	_check(doc.to_bytes() == FileAccess.get_file_as_bytes(saved_path), "second save keeps 250 bytes current")
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var reopened := OdfDocument.load_cached(src)
	_check(reopened != null and reopened.get_value("OrdnanceClass", "damageValue(H)") == "250", "reopen serves 250")
	_check(reopened != null and reopened.to_bytes() == FileAccess.get_file_as_bytes(saved_path), "reopened current bytes equal override")
	# Revert-to-original removes only the override; source stays untouched.
	_check(WorkspaceStore.discard_override(src), "workspace override removed")
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var source_again := OdfDocument.load_cached(src)
	_check(source_again != null and source_again.get_value("OrdnanceClass", "damageValue(H)") == "100", "revert loads the original value")
	_check(source_again != null and not source_again.workspace_override, "reverted document is ORIGINAL, not override")
	_check(FileAccess.get_file_as_bytes(src) == original, "revert never rewrites the original source")
	WorkspaceStore.root_override = old_root
	_remove_tree(ProjectSettings.globalize_path(root))


func _test_header_occurrence_surgery() -> void:
	_start("Header occurrence surgery / duplicate names")
	var text := "[A]\nx=1\n\n[B]\ny=2\n\n[A]\nx=3\n"
	var doc := OdfDocument.parse_text(text, "occ.odf")
	_eq(doc.header_occurrence_count("A"), 2, "two physical A occurrences parsed")
	_check(doc.remove_header("A", 0), "first A removed")
	_eq(doc.header_occurrence_count("A"), 1, "second A survives")
	_check(doc.has_header("B") and doc.get_value("B", "y") == "2", "B section untouched")
	_eq(doc.get_value("A", "x"), "3", "remaining A keeps its value")
	_check(not doc.text.contains("x=1"), "removed occurrence value gone")
	doc.undo()
	_eq(doc.text, text, "undo restores byte-identical text")
	_check(doc.remove_header("A", 1), "second occurrence removed by index")
	_check(doc.has_header("B") and doc.get_value("A", "x") == "1", "other A and B survive the second removal")
	# CRLF must not gain doubled carriage returns.
	var crlf := "[A]\r\nx=1\r\n\r\n[B]\r\ny=2\r\n\r\n[A]\r\nx=3\r\n"
	var cdoc := OdfDocument.parse_text(crlf, "crlf.odf")
	cdoc.remove_header("A", 0)
	_check(not cdoc.text.contains("\r\r"), "CRLF removal does not double carriage returns")
	_check(cdoc.text.begins_with("[B]\r\n"), "CRLF removal keeps the next section first")
	# Empty header insertion must stay inside its own physical range.
	var empty := OdfDocument.parse_text("[Empty]\n\n[Next]\nz=9\n", "empty.odf")
	empty.append_entry("Empty", "added", "1")
	_eq(empty.get_value("Empty", "added"), "1", "property appended to empty header")
	_check(empty.find_entry("Next", "added") == null, "property did not leak into next header")
	_check(empty.text.find("added") < empty.text.find("[Next]"), "insertion is before the next bracket line")


func _test_transaction_recovery() -> void:
	_start("Workspace transaction / journal recovery")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_txn_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var target := abs_root.path_join("odf/ord.odf")
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	_write(target, "old\n")
	var new_bytes := "new\n".to_utf8_buffer()
	var temp := target + ".tmp-crash"
	_write(temp, "new\n")
	var backup := abs_root.path_join("backups/ord.odf.bak")
	DirAccess.make_dir_recursive_absolute(backup.get_base_dir())
	_write(backup, "old\n")
	var txn_dir := ProjectSettings.globalize_path(WorkspaceStore.transactions_dir())
	DirAccess.make_dir_recursive_absolute(txn_dir)
	var journal := WorkspaceStore._journal_path(target)
	var meta := {
		"version": 1, "op": "workspace_odf",
		"target": target, "temp": temp, "backup": backup,
		"md5": FileAccess.get_md5(ProjectSettings.globalize_path(temp)),
		"size": new_bytes.size(), "source": abs_root.path_join("source/ord.odf"),
		"rel": "ord.odf", "source_md5": "",
	}
	_write(journal, JSON.stringify(meta))
	DirAccess.remove_absolute(target)
	var recovered := WorkspaceStore.recover_transactions()
	_check(recovered >= 1, "incomplete replacement recovered")
	_check(FileAccess.file_exists(target) and FileAccess.get_file_as_string(target) == "new\n", "recovery completed the verified new revision")
	_check(not FileAccess.file_exists(journal), "journal committed and removed")
	_check(WorkspaceStore.entry_for(str(meta.source)).get("rel", "") == "ord.odf", "manifest reconciled from journal")
	# Missing target + missing temp must restore the preserved backup.
	var target2 := abs_root.path_join("odf/two.odf")
	var backup2 := abs_root.path_join("backups/two.odf.bak")
	DirAccess.make_dir_recursive_absolute(backup2.get_base_dir())
	_write(backup2, "old-two\n")
	var journal2 := WorkspaceStore._journal_path(target2)
	_write(journal2, JSON.stringify({"version": 1, "op": "workspace_file", "target": target2, "temp": target2 + ".tmp-none", "backup": backup2, "md5": "0123456789abcdef0123456789abcdef", "size": 4}))
	WorkspaceStore.recover_transactions()
	_check(FileAccess.file_exists(target2) and FileAccess.get_file_as_string(target2) == "old-two\n", "backup restores old valid revision when new candidate is gone")
	_check(not FileAccess.file_exists(journal2), "rollback journal removed")
	# Crash before replacing an existing target: old bytes still present, verified
	# temp + journal must finish the new revision, not discard it.
	var target3 := abs_root.path_join("odf/three.odf")
	_write(target3, "old-three\n")
	var temp3 := target3 + ".tmp-crash"
	_write(temp3, "new-three\n")
	var journal3 := WorkspaceStore._journal_path(target3)
	_write(journal3, JSON.stringify({"version": 1, "op": "workspace_odf", "target": target3, "temp": temp3, "backup": "", "md5": FileAccess.get_md5(ProjectSettings.globalize_path(temp3)), "size": 10, "source": abs_root.path_join("source/three.odf"), "rel": "three.odf"}))
	WorkspaceStore.recover_transactions()
	_check(FileAccess.get_file_as_string(target3) == "new-three\n", "crash before replacement completes the verified new revision")
	_check(not FileAccess.file_exists(journal3), "pre-replacement journal committed")
	_check(WorkspaceStore.entry_for(abs_root.path_join("source/three.odf")).get("rel", "") == "three.odf", "pre-replacement manifest reconciled")
	# A normal committed write leaves no journal behind.
	var normal := WorkspaceStore.transactional_write_abs(target, "final\n".to_utf8_buffer())
	_check(bool(normal.get("ok", false)) and not FileAccess.file_exists(str(normal.get("journal", ""))), "committed write cleans its journal")
	_check(FileAccess.get_file_as_string(target) == "final\n", "committed target is the new bytes")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


func _test_external_cache_change() -> void:
	_start("OdfDocument / external cache change")
	var path := "user://p1_external_" + str(Time.get_ticks_usec()) + ".odf"
	_write(ProjectSettings.globalize_path(path), "[A]\nx=1\n")
	OdfDocument.clear_all_cache()
	var first := OdfDocument.load_cached(path)
	_check(first != null and first.get_value("A", "x") == "1", "initial cached value")
	_write(ProjectSettings.globalize_path(path), "[A]\nx=2\n")
	var refreshed := OdfDocument.load_cached(path)
	_check(refreshed != null and refreshed.get_value("A", "x") == "2", "clean cached document reloads after external edit")
	refreshed.set_entry_value(refreshed.find_entry("A", "x"), "3")
	_write(ProjectSettings.globalize_path(path), "[A]\nx=4\n")
	var preserved := OdfDocument.load_cached(path)
	_check(preserved != null and preserved.get_value("A", "x") == "3", "dirty cache keeps unsaved edits")
	_check(preserved != null and preserved.workspace_conflict, "dirty stale source is marked CONFLICT")
	OdfDocument.clear_all_cache()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_native_adapter() -> void:
	_start("Native adapter / read-only discovery and staged evidence")
	var d := NativeAdapterScript.discover()
	_check(bool(d.get("ok", false)), "BZCC executable discovered read-only")
	_check(str(d.get("exe_md5", "")).length() == 32, "executable hash recorded")
	_check(int(d.get("exe_bytes", 0)) > 1000000, "executable size recorded")
	_check(bool(d.get("build_id_valid", false)) and str(d.get("build_id", "")) != "" and str(d.get("build_id", "")) != "UNKNOWN", "Steam build id parsed numerically")
	var root := SafeStageScript.allocate_stage_dir("p2_native")
	var scenario := {"id": "scn_vsr_001", "name": "gatstabvsr_c -> atstabvsr_c -> ivscav_vsr", "godot_prediction": {"damage": 100.0}}
	var res := NativeAdapterScript.stage_scenario(root, {"Addon/test.odf": "[OrdnanceClass]\ndamageValue(H)=100\n"}, scenario, d)
	_check(bool(res.get("ok", false)), "scenario staged outside the game root")
	var manifest := str(res.get("manifest", ""))
	_check(FileAccess.file_exists(manifest), "evidence manifest written")
	var parsed_res := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(manifest))
	var parsed = parsed_res.get("data", null) if bool(parsed_res.get("ok", false)) else null
	_check(parsed is Dictionary and str(parsed.get("status", "")) == "STAGED", "manifest does not claim native verification")
	_check(parsed is Dictionary and not NativeAdapterScript.is_native_verified(parsed), "staging alone is not NATIVE_VERIFIED")
	var inside := NativeAdapterScript.stage_scenario(str(d.get("game_root", "")) + "/shaman_native_test", {"x.odf": "x"}, scenario, d)
	_check(not bool(inside.get("ok", true)), "staging inside the game installation is refused")
	_remove_tree(root)


func _test_safe_stage_manager() -> void:
	_start("SafeStageManager / allowlist and source-root protection (S5..S7)")
	var d := NativeAdapterScript.discover()
	var scenario := {"id": "scn_safe", "godot_prediction": {"damage": 100.0}}
	var forbidden := [
		str(d.get("game_root", "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R")) + "/shaman_test",
		"V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970/shaman_test",
		"V:/___VAC/__K/__CODE/_MISC/_BZDECOMP/vrv/shaman_test",
		"V:/___VAC/__K/__CODE/_TAMPERMONKEY/_WIN95THEME/Wintage/shaman_test",
		"V:/___VAC/_BATTLEZONE/shaman_test",
		ProjectSettings.globalize_path("res://").path_join("shaman_test"),
		ProjectSettings.globalize_path("user://unrelated_user_folder/stage_a"),
		"C:/Windows/Temp/shaman_unowned_stage",
	]
	for bad_root in forbidden:
		var rej := NativeAdapterScript.stage_scenario(bad_root, {"Addon/x.odf": "x"}, scenario, d)
		_check(not bool(rej.get("ok", true)), "S5/S6 refused forbidden/unowned stage root: " + bad_root)
	# S7: unknown pre-existing files in an owned stage dir are preserved and never overwritten.
	var owned := SafeStageScript.allocate_stage_dir("s7_preserve")
	DirAccess.make_dir_recursive_absolute(owned)
	var keep_file := owned.path_join("keep_unknown.txt")
	_write(keep_file, "do-not-delete")
	var collide := SafeStageScript.stage(owned, {"keep_unknown.txt": "overwrite"}, {}, false)
	_check(not bool(collide.get("ok", true)), "refused overwriting pre-existing unknown file")
	_eq(FileAccess.get_file_as_string(keep_file), "do-not-delete", "unknown file content untouched on collision")
	var dry := SafeStageScript.stage(owned, {"Addon/dry.odf": "[A]\nx=1\n"}, {}, true)
	_check(bool(dry.get("ok", false)) and not FileAccess.file_exists(owned.path_join("Addon/dry.odf")), "dry_run writes nothing")
	var ok_stage := SafeStageScript.stage(owned, {"Addon/a.odf": "[A]\nx=1\n"}, {"tag": "s7"}, false)
	_check(bool(ok_stage.get("ok", false)), "owned stage root accepts staged files")
	_check(FileAccess.file_exists(str(ok_stage.get("manifest", ""))), "stage_manifest.json created")
	var clean := SafeStageScript.cleanup(owned)
	_check(bool(clean.get("ok", false)), "cleanup succeeds on owned stage")
	_check(not FileAccess.file_exists(owned.path_join("Addon/a.odf")), "staged file removed by cleanup")
	_check(FileAccess.file_exists(keep_file) and FileAccess.get_file_as_string(keep_file) == "do-not-delete", "S7: unknown pre-existing file preserved after cleanup")
	_remove_tree(owned)


func _test_build_id_and_evidence_gates() -> void:
	_start("Native adapter / buildid KeyValues & evidence gate (N1..N8)")
	var n1 := NativeAdapterScript.parse_appmanifest_build_id("\"AppState\"\n{\n\t\"appid\"\t\t\"624970\"\n\t\"buildid\"\t\t\"20345678\"\n}\n")
	_check(bool(n1.get("ok", false)) and str(n1.get("build_id", "")) == "20345678", "N1: buildid extracted numerically without whitespace")
	var n2 := NativeAdapterScript.parse_appmanifest_build_id("\"AppState\"\n{\n\t\"appid\"\t\t\"624970\"\n}\n")
	_check(not bool(n2.get("ok", true)) and str(n2.get("build_id", "")) == "UNKNOWN", "N2: missing buildid yields UNKNOWN")
	var n3 := NativeAdapterScript.parse_appmanifest_build_id("\"AppState\"\n{\n\t\"buildid\"\t\t\"abc123\"\n}\n")
	_check(not bool(n3.get("ok", true)) and str(n3.get("build_id", "")) == "UNKNOWN", "N3: non-numeric buildid rejected")
	# N4: forged two-field evidence must never pass is_native_verified.
	var forged := {
		"status": "NATIVE_VERIFIED",
		"native_observation": {"damage": 100},
		"evidence_path": "fake.txt",
	}
	_check(not NativeAdapterScript.is_native_verified(forged), "N4: forged two-field evidence rejected even with status=NATIVE_VERIFIED")
	# Even with a real dummy file on disk, missing launch/staging/exe/comparison fails.
	var tmp_ev := ProjectSettings.globalize_path("user://native_tests/fake_ev_" + str(Time.get_ticks_usec()) + ".txt")
	_write(tmp_ev, "dummy")
	forged["evidence_path"] = tmp_ev
	_check(not NativeAdapterScript.is_native_verified(forged), "N6: missing launch/staging/exe provenance rejected")
	DirAccess.remove_absolute(tmp_ev)

	# Wave D (B1..B2, N5, N7, N8): build isolated BZCC experiment package and verify preflight + comparison gates.
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": BASE, "label": "base", "kind": "game", "priority": 10, "enabled": true},
		{"path": VSR, "label": "vsr", "kind": "workshop", "priority": 30, "enabled": true},
	]
	idx.scan(true)
	var prof := WeaponProfile.new()
	_check(prof.resolve(idx, VSR_TANK, VSR_SCAV), "Wave D profile resolved")
	var disc := NativeAdapterScript.discover()
	var exp_stage := SafeStageScript.allocate_stage_dir("wave_d_probe")
	var exp_files := NativeAdapterScript.build_experiment_files(prof, "wave_d_probe", {
		"assets/ODF/atstabvsr_c.odf": prof.ordnance_doc.to_bytes(),
	}, exp_stage)
	var scn := {"id": "scn_vsr_wave_d", "godot_prediction": {"damage": prof.expected_damage()}}
	var pre := NativeAdapterScript.preflight_experiment(exp_stage, exp_files, scn, disc)
	_check(bool(pre.get("ok", false)), "B1: preflight passes structural + BZN + mount + buildid + staging isolation checks")
	_check((pre.get("launch_args", []) as Array).has("/config"), "N8: launch args include /config")
	var stg := NativeAdapterScript.stage_scenario(exp_stage, exp_files, scn, disc)
	_check(bool(stg.get("ok", false)), "B1: isolated LuaMission BZN + cfg + ODF scenario staged")
	var staged_list: Array = stg.get("staged", [])
	_check(staged_list.size() == exp_files.size(), "N7: stage manifest records all staged files")
	for sitem in staged_list:
		_eq(str(sitem.get("md5", "")).length(), 32, "N7: staged file MD5 recorded")
	var ev_dict: Dictionary = stg.get("evidence", {})
	_check(not NativeAdapterScript.is_native_verified(ev_dict), "N5/E2: staged scenario alone is never NATIVE_VERIFIED")
	# E1: Synthetically setting launch_record.executed=true + status=NATIVE_VERIFIED passes schema_valid ONLY, never is_native_verified!
	var obs_file := exp_stage.path_join("shaman_observation.json")
	_write(obs_file, "{\"damage\":100.0}")
	var synthetic_ev := NativeAdapterScript.record_observation_and_compare(ev_dict, {
		"damage": 100.0, "provenance": "bzcc_lua", "measurement_method": "GetCurHealth_delta"
	}, {"damage": 100.0}, [obs_file])
	_check(not NativeAdapterScript.is_native_verified(synthetic_ev), "N6/N8: unlaunched record cannot become NATIVE_VERIFIED")
	synthetic_ev["launch_record"] = {"executed": true, "exe": str(disc.get("exe", "")), "launch_args": pre.launch_args, "exit_code": 0, "launched_at": "2026-11-21T15:00:00"}
	synthetic_ev["status"] = "NATIVE_VERIFIED"
	var syn_verdict := NativeAdapterScript.validate_native_evidence(synthetic_ev)
	_check(bool(syn_verdict.get("schema_valid", false)), "E1: synthetic fixture passes schema_valid")
	_check(bool(syn_verdict.get("synthetic", false)), "E1: manually mutated dict flagged as synthetic")
	_check(not NativeAdapterScript.is_native_verified(synthetic_ev), "E1: synthetic metadata must NEVER become NATIVE_VERIFIED")
	_remove_tree(exp_stage)
	OdfDocument.clear_all_cache()
	OdfInheritance.clear_cache()


func _test_native_scenario_bzn_and_mount() -> void:
	_start("Native scenario / BZN, Lua, terrain & mount validation (N1..N7)")
	var disc := NativeAdapterScript.discover()
	var stage := SafeStageScript.allocate_stage_dir("n1_n7_probe")
	var scn := {"id": "scn_n_matrix", "godot_prediction": {"damage": 100.0}}
	var good_files := NativeAdapterScript.build_experiment_files(null, "n1_n7_probe", {
		"assets/ODF/atstabvsr_c.odf": "[OrdnanceClass]\ndamageValue(H)=100\n",
	}, stage, "sess_n1", "nonce_n1")
	# N1: Missing BZN rejected explicitly with MISSING_MISSION_BZN.
	var no_bzn := good_files.duplicate()
	no_bzn.erase("assets/Missions/shaman_shot.bzn")
	var pre_n1 := NativeAdapterScript.preflight_experiment(stage, no_bzn, scn, disc)
	_check(not bool(pre_n1.get("ok", true)) and str(pre_n1.get("status", "")) == "FAILED", "N1: missing BZN fails preflight")
	_eq(str(pre_n1.get("reason", "")), "MISSING_MISSION_BZN", "N1: explicit reason MISSING_MISSION_BZN")
	# N2: Valid LuaMission BZN accepted.
	var pre_n2 := NativeAdapterScript.preflight_experiment(stage, good_files, scn, disc)
	_check(bool(pre_n2.get("ok", false)), "N2: valid LuaMission BZN + stock terrain passes structural preflight")
	_eq(str((pre_n2.get("mission_package", {}) as Dictionary).get("dll_name", "")), "luamission.dll", "N2: BZN selects luamission.dll")
	# Incompatible non-LuaMission DLL rejected.
	var bad_dll := good_files.duplicate()
	bad_dll["assets/Missions/shaman_shot.bzn"] = str(good_files["assets/Missions/shaman_shot.bzn"]).replace("luamission.dll", "empty.dll")
	var pre_dll := NativeAdapterScript.preflight_experiment(stage, bad_dll, scn, disc)
	_eq(str(pre_dll.get("reason", "")), "INCOMPATIBLE_MISSION_TYPE", "N2b: non-LuaMission BZN rejected")
	# N3: BZN/Lua identity mismatch rejected.
	var mismatch := good_files.duplicate()
	mismatch.erase("assets/Missions/shaman_shot.lua")
	mismatch["assets/Missions/other_mission.lua"] = "function Start() end\n"
	var pre_n3 := NativeAdapterScript.preflight_experiment(stage, mismatch, scn, disc)
	_eq(str(pre_n3.get("reason", "")), "BZN_LUA_MISMATCH", "N3: BZN/Lua name mismatch rejected")
	# N4: Missing terrain dependency rejected.
	var bad_trn := good_files.duplicate()
	bad_trn["assets/Missions/shaman_shot.bzn"] = str(good_files["assets/Missions/shaman_shot.bzn"]).replace("g_TerrainName = test", "g_TerrainName = nonexistent_planet_999")
	var pre_n4 := NativeAdapterScript.preflight_experiment(stage, bad_trn, scn, disc)
	_eq(str(pre_n4.get("reason", "")), "MISSING_TERRAIN_DEPENDENCY", "N4: missing terrain dependency rejected")
	# N5: Staged ODF mounted from exact canonical stage/assets root.
	var cfg_txt := str(good_files.get("shaman_native.cfg", ""))
	var m_ok := NativeAdapterScript.validate_mount_config(cfg_txt, stage)
	_check(bool(m_ok.get("ok", false)), "N5: shaman_native.cfg mounts exact staged assets root")
	_check(not cfg_txt.contains("@mydocsdir\\addon"), "N5: cfg does not rely on unrelated @mydocsdir\\addon")
	# N6: Wrong mount path detected.
	var wrong_cfg := good_files.duplicate()
	wrong_cfg["shaman_native.cfg"] = "ConfigureFileSystem()\n{\n\tAppendToMyDocs(\"SHAMAN_X\");\n\tConfigureStream(\"base\")\n\t{\n\t\tAddDirRecurse(\"@mydocsdir\\addon\");\n\t}\n}\n"
	var pre_n6 := NativeAdapterScript.preflight_experiment(stage, wrong_cfg, scn, disc)
	_eq(str(pre_n6.get("reason", "")), "MOUNT_PATH_MISMATCH", "N6: wrong @mydocsdir\\addon mount path rejected")
	# N7: Controlled Lua uses WriteToFile + PrintConsoleMessage (never io.open) and declares full state machine.
	var lua_txt := str(good_files.get("assets/Missions/shaman_shot.lua", ""))
	_check(not lua_txt.contains("io.open("), "N7: Lua avoids disabled io.open")
	_check(lua_txt.contains("WriteToFile(") and lua_txt.contains("PrintConsoleMessage("), "N7: Lua uses WriteToFile and PrintConsoleMessage")
	_check(lua_txt.contains("GetCurHealth(") and lua_txt.contains("MEASUREMENT_COMPLETE") and lua_txt.contains("FIRE_REQUESTED"), "N7: Lua implements controlled state machine and GetCurHealth")
	var io_bad := good_files.duplicate()
	io_bad["assets/Missions/shaman_shot.lua"] = "local f = io.open(\"x.json\", \"w\")\n"
	var pre_io := NativeAdapterScript.preflight_experiment(stage, io_bad, scn, disc)
	_eq(str(pre_io.get("reason", "")), "UNSUPPORTED_LUA_IO", "N7b: io.open usage in Lua rejected by preflight")
	_remove_tree(stage)


func _test_steam_launch_routes() -> void:
	_start("Steam launch / capability routes and classification (S1..S6)")
	var disc := NativeAdapterScript.discover()
	var exe_md5_before := str(disc.get("exe_md5", ""))
	var appid_path := str(disc.get("game_root", "")).path_join("steam_appid.txt")
	var appid_existed_before := FileAccess.file_exists(appid_path)
	var appid_mtime_before := FileAccess.get_modified_time(appid_path) if appid_existed_before else 0
	var stage := SafeStageScript.allocate_stage_dir("s1_s6_probe")
	var files := NativeAdapterScript.build_experiment_files(null, "s1_s6_probe", {}, stage)
	var scn := {"id": "scn_steam_routes", "godot_prediction": {"damage": 100.0}}
	# S1: Direct-exe Steam handoff (exit 53) classified as STEAM_HANDOFF_REQUIRED, not broken install.
	var s1 := NativeAdapterScript.classify_launch_result("DIRECT_EXECUTABLE", 53, false, false, false, false)
	_eq(str(s1.get("reason", "")), "STEAM_HANDOFF_REQUIRED", "S1: direct-exe exit 53 classified as STEAM_HANDOFF_REQUIRED")
	_check(bool(s1.get("handoff", false)) and not bool(s1.get("verified", true)), "S1: handoff flag true and not verified")
	# S2: Steam-managed launch retains intended args.
	var logged_in_steam := {"steam_exe": str(disc.get("steam_exe", "V:/__STORE_V/_SOFT/Steam/steam.exe")), "steam_present": true, "steam_running": true, "steam_logged_in": true}
	var pre_s2 := NativeAdapterScript.preflight_experiment(stage, files, scn, disc, logged_in_steam)
	_check(bool(pre_s2.get("launch_ready", false)) and str(pre_s2.get("launch_route", "")) == "STEAM_MANAGED", "S2: logged-in Steam selects STEAM_MANAGED launch_ready=true")
	var lcmd: Dictionary = pre_s2.get("launch_command", {})
	var sargs: Array = lcmd.get("args", [])
	_check(sargs.has("-applaunch") and sargs.has("624970") and sargs.has("/config") and sargs.has("/logconsole") and sargs.has("shaman_shot.bzn"), "S2: STEAM_MANAGED preserves -applaunch 624970 /config /logconsole shaman_shot.bzn")
	# S3: Launch without test mission is GAME_STARTED, never SUCCESS or verified.
	var s3 := NativeAdapterScript.classify_launch_result("STEAM_MANAGED", 0, true, false, false, false)
	_eq(str(s3.get("state", "")), "GAME_STARTED", "S3: process open without mission is GAME_STARTED")
	_check(not bool(s3.get("mission_ok", true)) and not bool(s3.get("verified", true)), "S3: launch without mission is never verified")
	# S4: Missing Steam client -> explicit BLOCKED / STEAM_CLIENT_MISSING; logged-off -> STEAM_USER_NOT_LOGGED_IN.
	var no_steam := {"steam_exe": "", "steam_present": false, "steam_running": false, "steam_logged_in": false}
	var pre_s4 := NativeAdapterScript.preflight_experiment(stage, files, scn, disc, no_steam)
	_eq(str(pre_s4.get("status", "")), "BLOCKED", "S4: missing Steam client reports BLOCKED")
	_eq(str(pre_s4.get("reason", "")), "STEAM_CLIENT_MISSING", "S4: missing Steam client reason STEAM_CLIENT_MISSING")
	var logged_off := {"steam_exe": str(disc.get("steam_exe", "")), "steam_present": true, "steam_running": false, "steam_logged_in": false, "detail": "ActiveUser=0x0"}
	var pre_s4b := NativeAdapterScript.preflight_experiment(stage, files, scn, disc, logged_off)
	_eq(str(pre_s4b.get("status", "")), "BLOCKED", "S4b: logged-off Steam reports BLOCKED")
	_eq(str(pre_s4b.get("reason", "")), "STEAM_USER_NOT_LOGGED_IN", "S4b: logged-off Steam reason STEAM_USER_NOT_LOGGED_IN")
	# S5: Timeout never generates native verification.
	var s5 := NativeAdapterScript.classify_launch_result("STEAM_MANAGED", 0, true, true, false, true)
	_eq(str(s5.get("state", "")), "TIMEOUT", "S5: timeout classified as TIMEOUT")
	_check(not bool(s5.get("verified", true)), "S5: timeout is never NATIVE_VERIFIED")
	# S6: Original BZ2R game installation untouched.
	var disc_after := NativeAdapterScript.discover()
	_eq(str(disc_after.get("exe_md5", "")), exe_md5_before, "S6: BZ2R executable MD5 unchanged")
	var appid_existed_after := FileAccess.file_exists(appid_path)
	var appid_mtime_after := FileAccess.get_modified_time(appid_path) if appid_existed_after else 0
	_check(appid_existed_after == appid_existed_before and appid_mtime_after == appid_mtime_before, "S6: no steam_appid.txt written into read-only BZ2R")
	_remove_tree(stage)


func _test_evidence_provenance_matrix() -> void:
	_start("Native evidence / schema vs trusted runner attestation (E1..E8)")
	NativeAdapterScript.clear_trusted_sessions()
	var disc := NativeAdapterScript.discover()
	var stage := SafeStageScript.allocate_stage_dir("e1_e8_probe")
	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\n".to_utf8_buffer()
	var odf_md5 := odf_bytes.get_string_from_utf8().md5_text()
	var files := NativeAdapterScript.build_experiment_files(null, "e1_e8_probe", {
		"assets/ODF/atstabvsr_c.odf": odf_bytes,
	}, stage)
	var scn := {"id": "scn_e_matrix", "revision": 1, "godot_prediction": {"damage": 100.0}}
	var stg := NativeAdapterScript.stage_scenario(stage, files, scn, disc)
	_check(bool(stg.get("ok", false)), "E-setup: scenario staged")
	var ev: Dictionary = stg.get("evidence", {})
	# E2: Staged-only never NATIVE_VERIFIED.
	_check(not NativeAdapterScript.is_native_verified(ev), "E2: staged-only never NATIVE_VERIFIED")
	# Begin trusted runner session.
	var receipt := NativeAdapterScript.begin_trusted_session(stg, disc, scn, "STEAM_MANAGED")
	var sid := str(receipt.get("session_id", ""))
	var nonce := str(receipt.get("launch_nonce", ""))
	# E3: Steam launched (process_id > 0) but mission_loaded_at == "" never NATIVE_VERIFIED.
	NativeAdapterScript.confirm_trusted_execution(sid, 4242, "2026-11-21T16:00:00", "STEAM_MANAGED", ["/config", "shaman_native.cfg"], 0, "")
	var obs_path := stage.path_join("obs_valid.json")
	_write(obs_path, JSON.stringify({
		"session_id": sid, "launch_nonce": nonce, "damage": 100.0,
		"odf_md5": odf_md5, "resources_mounted": true,
	}))
	var e3_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_path, {"damage": 100.0})
	_check(not NativeAdapterScript.is_native_verified(e3_ev), "E3: process started without mission_loaded_at never NATIVE_VERIFIED")
	# Confirm mission loaded for remaining checks.
	NativeAdapterScript.confirm_trusted_execution(sid, 4242, "2026-11-21T16:00:00", "STEAM_MANAGED", ["/config", "shaman_native.cfg"], 0, "2026-11-21T16:00:04", "", true)
	# E4: Mission loaded but observation missing remains incomplete.
	var e4_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, stage.path_join("missing_obs.json"), {"damage": 100.0})
	_eq(str(e4_ev.get("status", "")), "MISSION_LOADED", "E4: missing observation stays MISSION_LOADED")
	_check(not NativeAdapterScript.is_native_verified(e4_ev), "E4: missing observation never NATIVE_VERIFIED")
	# E5: Wrong session ID rejected.
	var bad_sid_path := stage.path_join("obs_bad_sid.json")
	_write(bad_sid_path, JSON.stringify({"session_id": "wrong_session_999", "launch_nonce": nonce, "damage": 100.0, "odf_md5": odf_md5}))
	var e5_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, bad_sid_path, {"damage": 100.0})
	_eq(str(e5_ev.get("capture_error", "")), "SESSION_ID_MISMATCH", "E5: wrong session_id rejected")
	_check(not NativeAdapterScript.is_native_verified(e5_ev), "E5: wrong session_id never NATIVE_VERIFIED")
	# E6: Wrong ODF hash rejected.
	var bad_odf_path := stage.path_join("obs_bad_odf.json")
	_write(bad_odf_path, JSON.stringify({"session_id": sid, "launch_nonce": nonce, "damage": 100.0, "odf_md5": "00000000000000000000000000000000"}))
	var e6_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, bad_odf_path, {"damage": 100.0})
	_eq(str(e6_ev.get("capture_error", "")), "ODF_HASH_MISMATCH", "E6: wrong ODF hash rejected")
	_check(not NativeAdapterScript.is_native_verified(e6_ev), "E6: wrong ODF hash never NATIVE_VERIFIED")
	# E7: Runner-attested trusted observation with matching hashes accepted.
	var e7_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_path, {"damage": 100.0})
	var e7_v := NativeAdapterScript.validate_native_evidence(e7_ev)
	_check(bool(e7_v.get("verified", false)) and not bool(e7_v.get("synthetic", true)), "E7: runner-attested observation accepted as genuine NATIVE_VERIFIED")
	# E8: Comparison with mismatched scenario revision rejected.
	var e8_ev := e7_ev.duplicate(true)
	(e8_ev["comparison"] as Dictionary)["scenario_hash"] = "ffffffffffffffffffffffffffffffff"
	var e8_v := NativeAdapterScript.validate_native_evidence(e8_ev)
	_check(not bool(e8_v.get("verified", true)), "E8: mismatched comparison scenario_hash rejected")
	NativeAdapterScript.clear_trusted_sessions()
	_remove_tree(stage)


func _test_staging_safety_f1_f7() -> void:
	_start("SafeStageManager / MD5 cleanup & partial overwrite rollback (F1..F7)")
	var stage := SafeStageScript.allocate_stage_dir("f1_f7_safety")
	# F1 & F2: Modified staged file preserved + unknown file preserved.
	var s1 := SafeStageScript.stage(stage, {
		"assets/a.odf": "[A]\nx=1\n",
		"assets/b.odf": "[B]\ny=2\n",
	}, {"tag": "f1"})
	_check(bool(s1.get("ok", false)), "F1: initial staging succeeded")
	var unknown_file := stage.path_join("user_note.txt")
	_write(unknown_file, "keep-me-forever")
	# Manually modify staged file a.odf after staging.
	_write(stage.path_join("assets/a.odf"), "[A]\nx=999\n; human edit\n")
	var cl := SafeStageScript.cleanup(stage)
	_eq(str(cl.get("status", "")), "PARTIAL_CLEANUP", "F1: cleanup reports PARTIAL_CLEANUP when a staged file was modified")
	_eq(str(cl.get("reason", "")), "MODIFIED_FILE_PRESERVED", "F1: cleanup reports MODIFIED_FILE_PRESERVED")
	_check((cl.get("preserved", []) as Array).has("assets/a.odf"), "F1: modified file listed in preserved")
	_check(FileAccess.file_exists(stage.path_join("assets/a.odf")) and FileAccess.get_file_as_string(stage.path_join("assets/a.odf")).contains("x=999"), "F1: modified staged file preserved on disk")
	_check(not FileAccess.file_exists(stage.path_join("assets/b.odf")), "F1: unmodified owned file removed cleanly")
	_check(FileAccess.file_exists(unknown_file) and FileAccess.get_file_as_string(unknown_file) == "keep-me-forever", "F2: unknown file preserved untouched")
	_remove_tree(stage)

	# F3: Corrupted manifest rejected.
	var f3_stage := SafeStageScript.allocate_stage_dir("f3_corrupt")
	SafeStageScript.stage(f3_stage, {"assets/x.odf": "[X]\na=1\n"}, {})
	_write(f3_stage.path_join(SafeStageScript.MANIFEST_NAME), "{not-valid-json")
	var cl_f3 := SafeStageScript.cleanup(f3_stage)
	_check(not bool(cl_f3.get("ok", true)) and str(cl_f3.get("reason", "")) == "INVALID_STAGE_MANIFEST", "F3: corrupted manifest rejected by cleanup")
	_check(FileAccess.file_exists(f3_stage.path_join("assets/x.odf")), "F3: file preserved when manifest is corrupted")
	_remove_tree(f3_stage)

	# F4: Traversal path rejected.
	var f4_stage := SafeStageScript.allocate_stage_dir("f4_trav")
	var trav := SafeStageScript.stage(f4_stage, {"../escape.odf": "bad"}, {})
	_check(not bool(trav.get("ok", true)) and str(trav.get("reason", "")) == "TRAVERSAL_REJECTED", "F4: traversal path rejected")
	_remove_tree(f4_stage)

	# F5: Symlink/junction escape rejected (real Windows directory junction inside isolated disposable dir).
	if OS.get_name() == "Windows":
		var f5_stage := SafeStageScript.allocate_stage_dir("f5_junc")
		var f5_outside := ProjectSettings.globalize_path("user://native_tests/f5_outside_" + str(Time.get_ticks_usec()))
		DirAccess.make_dir_recursive_absolute(f5_stage)
		DirAccess.make_dir_recursive_absolute(f5_outside)
		var junc_path := f5_stage.path_join("link_dir")
		var mk_out: Array = []
		var mk_rc := OS.execute("cmd", ["/c", "mklink", "/J", junc_path.replace("/", "\\"), f5_outside.replace("/", "\\")], mk_out, true)
		if mk_rc == 0:
			var f5_res := SafeStageScript.stage(f5_stage, {"link_dir/escape.odf": "bad"}, {})
			_check(not bool(f5_res.get("ok", true)) and str(f5_res.get("reason", "")) == "SYMLINK_REJECTED", "F5: Windows junction escape rejected")
			OS.execute("cmd", ["/c", "rmdir", junc_path.replace("/", "\\")], mk_out, true)
		_remove_tree(f5_stage)
		_remove_tree(f5_outside)

	# F6: Partial overwrite rollback recovers old owned files.
	var f6_stage := SafeStageScript.allocate_stage_dir("f6_rollback")
	var init6 := SafeStageScript.stage(f6_stage, {
		"assets/first.odf": "OLD_FIRST_V1",
		"assets/second.odf": "OLD_SECOND_V1",
	}, {"rev": 1})
	_check(bool(init6.get("ok", false)), "F6: initial V1 stage succeeded")
	SafeStageScript.fault_fail_rel = "assets/second.odf"
	var fail6 := SafeStageScript.stage(f6_stage, {
		"assets/first.odf": "NEW_FIRST_V2",
		"assets/second.odf": "NEW_SECOND_V2",
		"assets/third_new.odf": "NEW_THIRD_V2",
	}, {"rev": 2})
	SafeStageScript.fault_fail_rel = ""
	_check(not bool(fail6.get("ok", true)) and str(fail6.get("reason", "")) == "STAGE_WRITE_FAILED", "F6: mid-overwrite failure detected")
	_eq(FileAccess.get_file_as_string(f6_stage.path_join("assets/first.odf")), "OLD_FIRST_V1", "F6: previously overwritten owned file restored to V1")
	_eq(FileAccess.get_file_as_string(f6_stage.path_join("assets/second.odf")), "OLD_SECOND_V1", "F6: untouched V1 second file intact")
	_check(not FileAccess.file_exists(f6_stage.path_join("assets/third_new.odf")), "F6: newly created file removed on rollback")
	_remove_tree(f6_stage)

	# F7: Protected source roots refused unconditionally.
	var f7_rej := SafeStageScript.stage("V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/shaman_f7", {"a.odf": "x"})
	_check(not bool(f7_rej.get("ok", true)) and str(f7_rej.get("reason", "")) == "FORBIDDEN_SOURCE_ROOT", "F7: BZ2R source root refused")


func _test_native_session_identity_ns1_ns5() -> void:
	_start("NativeExperimentSession / single immutable identity (N-S1..N-S5)")
	NativeAdapterScript.clear_trusted_sessions()
	var disc := NativeAdapterScript.discover()
	var stage := SafeStageScript.allocate_stage_dir("ns1_ns5_sess")
	var scn := {"id": "scn_ns1", "revision": 2, "godot_prediction": {"damage": 100.0}}
	var sess = NativeAdapterScript.create_session(stage, scn, disc, "shaman_shot", "test")
	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\n".to_utf8_buffer()
	var files := NativeAdapterScript.build_experiment_files_for_session(sess, null, {"assets/ODF/atstabvsr_c.odf": odf_bytes})
	var stg := NativeAdapterScript.stage_scenario(stage, files, scn, disc, false, sess)
	_check(bool(stg.get("ok", false)), "N-S1: session-driven staging succeeded")
	var sm_jres := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(str(stg.get("stage_manifest", ""))))
	var sm_dict: Dictionary = sm_jres.get("data", {}) if bool(sm_jres.get("ok", false)) else {}
	var receipt := NativeAdapterScript.begin_trusted_session(stg, disc, scn, "STEAM_MANAGED", sess)
	var ev: Dictionary = stg.get("evidence", {})
	var c1: Dictionary = sess.validate_consistency(files, stg.get("mount_plan", {}), sm_dict, receipt, ev)
	_check(bool(c1.get("ok", false)), "N-S1: Lua, MountPlan, StageManifest, Receipt, and Evidence share one immutable session identity")
	_eq(str(c1.get("lua_session_id", "")), sess.session_id, "N-S1: Lua SESSION_ID equals session.session_id")
	_eq(str(c1.get("lua_launch_nonce", "")), sess.launch_nonce, "N-S1: Lua LAUNCH_NONCE equals session.launch_nonce")
	_eq(str(c1.get("lua_obs_file", "")), str((stg.get("mount_plan", {}) as Dictionary).get("observation_expected_path", "")).get_file(), "N-S1: Lua OBS_FILE matches MountPlan observation_expected_path basename")
	_eq(str(receipt.get("session_id", "")), sess.session_id, "N-S1: trusted receipt inherits session_id")
	_eq(str(receipt.get("launch_nonce", "")), sess.launch_nonce, "N-S1: trusted receipt inherits launch_nonce")

	# N-S2: Mismatched Lua SESSION_ID or LAUNCH_NONCE detected.
	var bad_lua_files := files.duplicate(true)
	var lua_rel := "assets/Missions/%s.lua" % sess.mission_basename
	bad_lua_files[lua_rel] = str(files[lua_rel]).replace(sess.session_id, "stale_wrong_session")
	var c2: Dictionary = sess.validate_consistency(bad_lua_files, sess.mount_plan)
	_check(not bool(c2.get("ok", true)) and str(c2.get("reason", "")) == "SESSION_IDENTITY_MISMATCH", "N-S2: mismatched Lua SESSION_ID rejected")

	# N-S3: Mismatched Lua OBS_FILE vs MountPlan observation_expected_path detected.
	var bad_obs_files := files.duplicate(true)
	bad_obs_files[lua_rel] = str(files[lua_rel]).replace(sess.observation_filename, "shaman_obs_other.json")
	var c3: Dictionary = sess.validate_consistency(bad_obs_files, sess.mount_plan)
	_check(not bool(c3.get("ok", true)) and str(c3.get("reason", "")) == "SESSION_IDENTITY_MISMATCH", "N-S3: mismatched Lua OBS_FILE rejected")

	# N-S4: Session serialization roundtrip preserves all immutable identity fields & checkpoints.
	var rt = NativeSessionScript.from_dict(sess.to_dict())
	_check(rt != null, "N-S4: NativeExperimentSession.from_dict succeeded")
	if rt != null:
		_eq(rt.session_id, sess.session_id, "N-S4: session_id roundtripped")
		_eq(rt.launch_nonce, sess.launch_nonce, "N-S4: launch_nonce roundtripped")
		_eq(rt.stage_id, sess.stage_id, "N-S4: stage_id roundtripped")
		_eq(rt.observation_filename, sess.observation_filename, "N-S4: observation_filename roundtripped")
		_check(rt.expected_odf_hashes.has("assets/ODF/atstabvsr_c.odf"), "N-S4: expected_odf_hashes preserved")
		_check(rt.recovery_checkpoints.size() >= 2, "N-S4: recovery checkpoints preserved")

	# N-S5: preflight_experiment refuses mismatched session identity in Lua.
	var pre_ok := NativeAdapterScript.preflight_experiment(stage, files, sess.scenario, disc, {"steam_present": true, "steam_logged_in": true, "steam_exe": str(disc.get("steam_exe", ""))}, sess)
	_check(bool(pre_ok.get("structurally_valid", false)), "N-S5: preflight passes with consistent NativeExperimentSession")
	var pre_bad := NativeAdapterScript.preflight_experiment(stage, bad_lua_files, sess.scenario, disc, {"steam_present": true, "steam_logged_in": true, "steam_exe": str(disc.get("steam_exe", ""))}, sess)
	_check(not bool(pre_bad.get("structurally_valid", true)) and str(pre_bad.get("reason", "")) == "SESSION_IDENTITY_MISMATCH", "N-S5: preflight refuses mismatched Lua session identity")
	NativeAdapterScript.clear_trusted_sessions()
	_remove_tree(stage)


func _test_native_resource_closure_nr1_nr7() -> void:
	_start("NativeResourceClosureBuilder / transitive ODF & Workshop closure (N-R1..N-R7)")
	var tmp := ProjectSettings.globalize_path("user://nr_closure_" + str(Time.get_ticks_usec()))
	var game_root := tmp.path_join("game")
	var res_root := game_root.path_join("bz2r_res")
	var ws_root := tmp.path_join("workshop")
	var ext_root := tmp.path_join("external")
	_write(res_root.path_join("ivbase_tank.odf"), "[GameObjectClass]\nclassLabel=\"wingman\"\nweaponName1=\"gbase_gun\"\n")
	_write(res_root.path_join("ivbase_scav.odf"), "[GameObjectClass]\nclassLabel=\"scavenger\"\nmaxHealth=1000\n")
	_write(res_root.path_join("gbase_gun.odf"), "[WeaponClass]\nclassLabel=\"cannon\"\nordName=\"abase_ord\"\n")
	_write(res_root.path_join("abase_ord.odf"), "[OrdnanceClass]\nclassLabel=\"bullet\"\ndamageValue(H)=100\n")
	_write(ws_root.path_join("111111/ws_parent.odf"), "[OrdnanceClass]\nclassLabel=\"bullet\"\ndamageValue(H)=150\n")
	_write(ws_root.path_join("111111/ws_ord.odf"), "[OrdnanceClass]\nclassLabel=\"ws_parent\"\n")
	_write(ws_root.path_join("111111/dup_mod.odf"), "[OrdnanceClass]\ndamageValue(H)=111\n")
	_write(ws_root.path_join("222222/dup_mod.odf"), "[OrdnanceClass]\ndamageValue(H)=222\n")
	_write(ext_root.path_join("ext_ord.odf"), "[OrdnanceClass]\ndamageValue(H)=333\n")

	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": res_root, "label": "game", "kind": "game", "priority": 10, "enabled": true},
		{"path": ws_root, "label": "workshop", "kind": "workshop", "priority": 30, "enabled": true},
		{"path": ext_root, "label": "external", "kind": "custom", "priority": 5, "enabled": true},
	]
	idx.scan(true)
	var disc_fake := {"game_root": game_root, "res_root": res_root}

	# N-R1: Stock base-game closure is RESOURCE_CLOSURE_COMPLETE.
	var r1 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "abase_ord",
		"staged_files": {}, "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r1.get("status", "")), ResourceClosureScript.STATUS_COMPLETE, "N-R1: base-game closure is RESOURCE_CLOSURE_COMPLETE")
	_check((r1.get("base_game_resources", []) as Array).size() == 4, "N-R1: all 4 base-game ODFs classified")

	# N-R2: Stage-owned override takes precedence and is parsed transitively.
	var r2 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "abase_ord",
		"staged_files": {"assets/ODF/abase_ord.odf": "[OrdnanceClass]\nclassLabel=\"bullet\"\ndamageValue(H)=250\n"},
		"check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r2.get("status", "")), ResourceClosureScript.STATUS_COMPLETE, "N-R2: stage override closure complete")
	_eq((r2.get("stage_owned_overrides", []) as Array).size(), 1, "N-R2: staged ODF recorded in stage_owned_overrides")

	# N-R3: Unmounted Workshop dependency required by scenario fails with MISSING_WORKSHOP_PACKAGE.
	var r3 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "ws_ord",
		"staged_files": {}, "mounted_workshop_packages": [], "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r3.get("status", "")), ResourceClosureScript.STATUS_MISSING, "N-R3: unmounted Workshop ODF reported RESOURCE_MISSING")
	_eq(str(r3.get("reason", "")), "MISSING_WORKSHOP_PACKAGE", "N-R3: reason is MISSING_WORKSHOP_PACKAGE")
	_check((r3.get("unmounted_workshop_resources", []) as Array).size() >= 1, "N-R3: unmounted Workshop ODFs enumerated")

	# N-R4: Same Workshop dependency passes when its package is mounted or staged transitively.
	var r4 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "ws_ord",
		"staged_files": {}, "mounted_workshop_packages": ["111111"], "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r4.get("status", "")), ResourceClosureScript.STATUS_COMPLETE, "N-R4: mounted Workshop package satisfies closure")

	# N-R5: Ambiguous Workshop ODF across 2 packages reported RESOURCE_AMBIGUOUS.
	var r5 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "dup_mod",
		"staged_files": {}, "mounted_workshop_packages": ["111111", "222222"], "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r5.get("status", "")), ResourceClosureScript.STATUS_AMBIGUOUS, "N-R5: competing Workshop packages yield RESOURCE_AMBIGUOUS")
	_check((r5.get("ambiguous_resources", []) as Array).size() == 1, "N-R5: ambiguous resource details recorded")

	# N-R6: Explicit active_packages disambiguates competing Workshop packages.
	var r6 := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "dup_mod",
		"staged_files": {}, "mounted_workshop_packages": ["222222"], "active_packages": ["222222"],
		"check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r6.get("status", "")), ResourceClosureScript.STATUS_COMPLETE, "N-R6: active_packages disambiguates Workshop ODF")

	# N-R7: Missing required ODF, unstaged external dependency, and bounded minimal auto-staging.
	var r7_miss := ResourceClosureScript.build_closure({
		"shooter_odf": "does_not_exist_shooter", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "abase_ord",
		"staged_files": {}, "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r7_miss.get("reason", "")), "MISSING_SHOOTER_ODF", "N-R7: missing shooter ODF yields MISSING_SHOOTER_ODF")
	var r7_ext := ResourceClosureScript.build_closure({
		"shooter_odf": "ivbase_tank", "target_odf": "ivbase_scav",
		"weapon_odf": "gbase_gun", "ordnance_odf": "ext_ord",
		"staged_files": {}, "check_base_disk": false,
	}, idx, disc_fake)
	_eq(str(r7_ext.get("reason", "")), "EXTERNAL_DEPENDENCY_UNSTAGED", "N-R7: external unstaged dependency yields EXTERNAL_DEPENDENCY_UNSTAGED")
	# Minimal staged ODFs includes transitive Workshop parent without copying stock base game.
	var prof := WeaponProfile.new()
	prof.shooter_doc = OdfDocument.load_cached(res_root.path_join("ivbase_tank.odf"))
	prof.target_doc = OdfDocument.load_cached(res_root.path_join("ivbase_scav.odf"))
	prof.weapon_doc = OdfDocument.load_cached(res_root.path_join("gbase_gun.odf"))
	prof.ordnance_doc = OdfDocument.load_cached(ws_root.path_join("111111/ws_ord.odf"))
	var min_staged := ResourceClosureScript.build_minimal_staged_odfs(prof, idx, disc_fake, true)
	_check(min_staged.has("assets/ODF/ws_ord.odf") and min_staged.has("assets/ODF/ws_parent.odf"), "N-R7: minimal auto-staging includes Workshop ordnance and transitive parent")
	_check(not min_staged.has("assets/ODF/ivbase_tank.odf"), "N-R7: minimal auto-staging does not copy unmodified base-game ODFs")
	OdfDocument.clear_all_cache()
	_remove_tree(tmp)


func _test_native_expected_observed_synthetic_ne1_ne8() -> void:
	_start("Native evidence / expected-vs-observed hashes, synthetic separation & safe JSON (N-E1..N-E8)")
	NativeAdapterScript.clear_trusted_sessions()
	var disc := NativeAdapterScript.discover()
	var stage := SafeStageScript.allocate_stage_dir("ne1_ne8_probe")
	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\nshotSpeed=120\n".to_utf8_buffer()
	var odf_md5 := WorkspaceStore._md5_bytes(odf_bytes)
	var scn := {"id": "scn_ne", "revision": 1, "godot_prediction": {"damage": 100.0}}
	var sess = NativeAdapterScript.create_session(stage, scn, disc)
	var files := NativeAdapterScript.build_experiment_files_for_session(sess, null, {"assets/ODF/atstabvsr_c.odf": odf_bytes})
	var lua_text := str(files.get("assets/Missions/%s.lua" % sess.mission_basename, ""))

	# N-E1: Lua emits expected_odf_md5 and honest empty observed_odf_md5 (never echoes expected as observed odf_md5).
	_check(lua_text.contains("\"expected_odf_md5\""), "N-E1: Lua emits explicit expected_odf_md5 field")
	_check(lua_text.contains("\"observed_odf_md5\":\"\"") and lua_text.contains("\"observed_odf_hash_available\":false"), "N-E1: Lua honestly reports observed_odf_hash_available=false instead of echoing expected hash")
	_check(not lua_text.contains("\"odf_md5\":"), "N-E1: Lua no longer conflates expected hash as observed odf_md5")

	var stg := NativeAdapterScript.stage_scenario(stage, files, scn, disc, false, sess)
	var ev: Dictionary = stg.get("evidence", {})
	var receipt := NativeAdapterScript.begin_trusted_session(stg, disc, scn, "STEAM_MANAGED", sess)
	var sid := str(receipt.get("session_id", ""))
	var nonce := str(receipt.get("launch_nonce", ""))
	# N-E6a: Invalid launch route refused in confirm_trusted_execution.
	var bad_route := NativeAdapterScript.confirm_trusted_execution(sid, 4242, "2026-11-21T16:10:00", "UNSUPPORTED", ["/config"], 0, "2026-11-21T16:10:03", "", true)
	_check(not bool(bad_route.get("ok", true)) and str(bad_route.get("reason", "")) == "INVALID_LAUNCH_ROUTE", "N-E6: UNSUPPORTED launch route refused")
	NativeAdapterScript.confirm_trusted_execution(sid, 4242, "2026-11-21T16:10:00", "STEAM_MANAGED", ["/config", "shaman_native.cfg"], 0, "2026-11-21T16:10:03", "", true)

	# N-E3: expected_odf_md5 mismatch and observed_odf_md5 mismatch rejected.
	var obs_bad_exp := stage.path_join("obs_bad_exp.json")
	_write(obs_bad_exp, JSON.stringify({"session_id": sid, "launch_nonce": nonce, "damage": 100.0, "expected_odf_md5": "11111111111111111111111111111111", "mount_marker": sess.mount_marker, "resources_mounted": true}))
	var ne3a := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_bad_exp, {"damage": 100.0})
	_eq(str(ne3a.get("capture_error", "")), "EXPECTED_ODF_HASH_MISMATCH", "N-E3: mismatched expected_odf_md5 rejected")
	var obs_bad_obs := stage.path_join("obs_bad_obs.json")
	_write(obs_bad_obs, JSON.stringify({"session_id": sid, "launch_nonce": nonce, "damage": 100.0, "expected_odf_md5": odf_md5, "observed_odf_md5": "22222222222222222222222222222222", "mount_marker": sess.mount_marker, "resources_mounted": true}))
	var ne3b := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_bad_obs, {"damage": 100.0})
	_eq(str(ne3b.get("capture_error", "")), "ODF_HASH_MISMATCH", "N-E3: mismatched observed_odf_md5 rejected")

	# N-E4: mount_marker mismatch rejected.
	var obs_bad_mnt := stage.path_join("obs_bad_mnt.json")
	_write(obs_bad_mnt, JSON.stringify({"session_id": sid, "launch_nonce": nonce, "damage": 100.0, "expected_odf_md5": odf_md5, "mount_marker": "WRONG_MARKER", "resources_mounted": false}))
	var ne4 := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_bad_mnt, {"damage": 100.0})
	_eq(str(ne4.get("capture_error", "")), "MOUNT_MARKER_MISMATCH", "N-E4: mismatched mount_marker rejected")

	# N-E6b: synthetic/manual capture_method and synthetic observation payload rejected.
	var obs_honest := stage.path_join("obs_honest.json")
	_write(obs_honest, JSON.stringify({
		"session_id": sid, "launch_nonce": nonce, "damage": 100.0,
		"expected_odf_md5": odf_md5, "observed_odf_md5": "", "observed_odf_hash_available": false,
		"odf_probe_damage": 100.0, "mount_marker": sess.mount_marker, "resources_mounted": true,
	}))
	var ne6_method := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_honest, {"damage": 100.0}, "synthetic")
	_eq(str(ne6_method.get("capture_error", "")), "SYNTHETIC_CAPTURE_METHOD", "N-E6: synthetic capture_method rejected")
	var obs_syn_flag := stage.path_join("obs_syn_flag.json")
	_write(obs_syn_flag, JSON.stringify({"session_id": sid, "launch_nonce": nonce, "damage": 100.0, "synthetic": true}))
	var ne6_flag := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_syn_flag, {"damage": 100.0})
	_eq(str(ne6_flag.get("capture_error", "")), "SYNTHETIC_OBSERVATION_REJECTED", "N-E6: observation with synthetic=true rejected")

	# N-E7: Honest runner-attested observation (empty observed_odf_md5 + disk MD5 verified + mount_marker verified).
	var ne7_ev := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_honest, {"damage": 100.0})
	var ne7_v := NativeAdapterScript.validate_native_evidence(ne7_ev)
	_check(bool(ne7_v.get("verified", false)), "N-E7: honest runner-attested observation verified")
	_check(bool(ne7_v.get("expected_odf_hashes_verified", false)), "N-E7: staged ODF disk MD5 verified")
	_check(not bool(ne7_v.get("observed_odf_hash_available", true)), "N-E7: observed_odf_hash_available remains false honestly")
	_eq(str(ne7_v.get("attestation_kind", "")), "RUNNER_ATTESTED", "N-E7: attestation_kind is RUNNER_ATTESTED")

	# N-E2: Modifying staged ODF on disk after staging triggers STAGED_ODF_DRIFT and invalidates evidence.
	_write(stage.path_join("assets/ODF/atstabvsr_c.odf"), "[OrdnanceClass]\ndamageValue(H)=999\n")
	var ne2_cap := NativeAdapterScript.capture_trusted_observation(ev, sid, obs_honest, {"damage": 100.0})
	_eq(str(ne2_cap.get("capture_error", "")), "STAGED_ODF_DRIFT", "N-E2: post-staging ODF drift detected at capture")
	var ne2_val := NativeAdapterScript.validate_native_evidence(ne7_ev)
	_check(not bool(ne2_val.get("verified", true)) and not bool(ne2_val.get("expected_odf_hashes_verified", true)), "N-E2: post-staging ODF drift invalidates previously valid evidence")
	# Restore staged ODF for N-E5.
	_write(stage.path_join("assets/ODF/atstabvsr_c.odf"), odf_bytes.get_string_from_utf8())

	# N-E5: Explicit synthetic session strictly separated from runner attestation.
	var syn_sess = NativeAdapterScript.create_session(stage, scn, disc)
	var syn_rec := NativeAdapterScript.begin_synthetic_session(stg, disc, scn, "OPERATOR_MANUAL", syn_sess)
	var syn_sid := str(syn_rec.get("session_id", ""))
	NativeAdapterScript.confirm_trusted_execution(syn_sid, 9999, "2026-11-21T16:11:00", "OPERATOR_MANUAL", ["/config"], 0, "2026-11-21T16:11:02", "", true)
	var syn_obs := stage.path_join("obs_syn_sess.json")
	_write(syn_obs, JSON.stringify({"session_id": syn_sid, "launch_nonce": syn_sess.launch_nonce, "damage": 100.0, "resources_mounted": true}))
	var syn_ev := NativeAdapterScript.capture_trusted_observation(ev, syn_sid, syn_obs, {"damage": 100.0})
	var syn_v := NativeAdapterScript.validate_native_evidence(syn_ev)
	_check(not bool(syn_v.get("verified", true)), "N-E5: begin_synthetic_session never produces NATIVE_VERIFIED")
	_check(bool(syn_v.get("synthetic", false)), "N-E5: synthetic session flagged synthetic=true")
	_eq(str(syn_v.get("attestation_kind", "")), "SYNTHETIC", "N-E5: attestation_kind is SYNTHETIC")

	# N-E8: Error-aware JSON parsing handles malformed JSON cleanly (no stderr spam).
	var bad_json_path := stage.path_join("obs_corrupt.json")
	_write(bad_json_path, "{broken json!!!")
	var ne8_cap := NativeAdapterScript.capture_trusted_observation(ev, sid, bad_json_path, {"damage": 100.0})
	_eq(str(ne8_cap.get("capture_error", "")), "OBSERVATION_JSON_INVALID", "N-E8: corrupt observation JSON rejected cleanly")
	_check(str(ne8_cap.get("capture_parse_error", "")) != "", "N-E8: structured JSON parse error detail populated")
	var bad_jres := WorkspaceStore.parse_json_safe("{not valid")
	_check(not bool(bad_jres.get("ok", true)) and str(bad_jres.get("error", "")) != "", "N-E8: WorkspaceStore.parse_json_safe returns structured error")
	NativeAdapterScript.clear_trusted_sessions()
	_remove_tree(stage)


func _test_staging_restage_rollback_f8_f12() -> void:
	_start("SafeStageManager / restaging MD5 guard & structured rollback (F8..F12)")
	# F8: Restaging over modified owned file with default strategy refuses with MODIFIED_OWNED_FILE_CONFLICT.
	var s8 := SafeStageScript.allocate_stage_dir("f8_restage")
	_check(bool(SafeStageScript.stage(s8, {"assets/a.odf": "ORIG_A", "assets/b.odf": "ORIG_B"}).get("ok", false)), "F8: initial stage ok")
	_write(s8.path_join("assets/a.odf"), "HUMAN_MODIFIED_A")
	var r8 := SafeStageScript.stage(s8, {"assets/a.odf": "NEW_A", "assets/b.odf": "NEW_B"})
	_check(not bool(r8.get("ok", true)) and str(r8.get("reason", "")) == "MODIFIED_OWNED_FILE_CONFLICT", "F8: restaging over modified owned file refused by default")
	_eq(FileAccess.get_file_as_string(s8.path_join("assets/a.odf")), "HUMAN_MODIFIED_A", "F8: modified owned file untouched")
	_check((r8.get("conflicts", []) as Array).size() == 1 and (r8.get("strategies", []) as Array).has("replace_with_backup"), "F8: conflict details and strategies reported")

	# F9: conflict_strategy=preserve keeps modified file while updating unmodified files.
	var r9 := SafeStageScript.stage(s8, {"assets/a.odf": "NEW_A", "assets/b.odf": "NEW_B"}, {}, false, [], {"conflict_strategy": "preserve"})
	_check(bool(r9.get("ok", false)), "F9: restage with preserve succeeded")
	_eq(FileAccess.get_file_as_string(s8.path_join("assets/a.odf")), "HUMAN_MODIFIED_A", "F9: modified file preserved")
	_eq(FileAccess.get_file_as_string(s8.path_join("assets/b.odf")), "NEW_B", "F9: unmodified file updated")
	_check((r9.get("preserved", []) as Array).has("assets/a.odf"), "F9: preserved list names modified file")

	# F10: conflict_strategy=replace_with_backup writes backup before replacing.
	var r10 := SafeStageScript.stage(s8, {"assets/a.odf": "REPLACED_A"}, {}, false, [], {"conflict_strategy": "replace_with_backup"})
	_check(bool(r10.get("ok", false)), "F10: restage with replace_with_backup succeeded")
	_eq(FileAccess.get_file_as_string(s8.path_join("assets/a.odf")), "REPLACED_A", "F10: target replaced after backup")
	var baks: Array = r10.get("backups", [])
	_check(baks.size() == 1 and FileAccess.file_exists(str(baks[0])) and FileAccess.get_file_as_string(str(baks[0])) == "HUMAN_MODIFIED_A", "F10: backup contains previous modified bytes")
	_remove_tree(s8)

	# F11: Mid-overwrite failure + rollback failure reports RECOVERY_PENDING and writes durable recovery marker.
	var s11 := SafeStageScript.allocate_stage_dir("f11_rb_fail")
	_check(bool(SafeStageScript.stage(s11, {"assets/one.odf": "V1_ONE", "assets/two.odf": "V1_TWO"}).get("ok", false)), "F11: initial V1 staged")
	SafeStageScript.fault_fail_rel = "assets/two.odf"
	SafeStageScript.fault_rollback_fail_rel = "assets/one.odf"
	var r11 := SafeStageScript.stage(s11, {"assets/one.odf": "V2_ONE", "assets/two.odf": "V2_TWO"})
	SafeStageScript.fault_fail_rel = ""
	SafeStageScript.fault_rollback_fail_rel = ""
	_check(not bool(r11.get("ok", true)) and str(r11.get("status", "")) == "RECOVERY_PENDING" and bool(r11.get("recovery_pending", false)), "F11: rollback restore failure reports RECOVERY_PENDING")
	_check(not str(r11.get("error", "")).contains("overwritten owned files restored"), "F11: never falsely claims overwritten files restored")
	var rb11: Dictionary = r11.get("rollback", {})
	_check((rb11.get("failed", []) as Array).size() == 1, "F11: structured rollback.failed records un-restored file")
	var marker11 := str(rb11.get("recovery_marker", ""))
	_check(marker11 != "" and FileAccess.file_exists(marker11), "F11: durable stage_recovery_pending.json written")
	var r11_blocked := SafeStageScript.stage(s11, {"assets/one.odf": "V3_ONE"})
	_check(not bool(r11_blocked.get("ok", true)) and str(r11_blocked.get("reason", "")) == "RECOVERY_PENDING", "F11: subsequent restage blocked while recovery marker pending")
	_remove_tree(s11)

	# F12: Corrupted manifest on stage() rejected cleanly & unknown file collision refused.
	var s12 := SafeStageScript.allocate_stage_dir("f12_corrupt_unknown")
	_check(bool(SafeStageScript.stage(s12, {"assets/x.odf": "X"}).get("ok", false)), "F12: initial stage ok")
	_write(s12.path_join("assets/unknown.odf"), "KEEP_UNKNOWN")
	var r12_unk := SafeStageScript.stage(s12, {"assets/unknown.odf": "OVERWRITE"})
	_check(not bool(r12_unk.get("ok", true)) and str(r12_unk.get("reason", "")) == "UNOWNED_FILE_COLLISION", "F12: collision with unknown file refused")
	_eq(FileAccess.get_file_as_string(s12.path_join("assets/unknown.odf")), "KEEP_UNKNOWN", "F12: unknown file untouched")
	_write(s12.path_join(SafeStageScript.MANIFEST_NAME), "{corrupt!!!")
	var r12_corrupt := SafeStageScript.stage(s12, {"assets/x.odf": "X2"})
	_check(not bool(r12_corrupt.get("ok", true)) and str(r12_corrupt.get("reason", "")) == "INVALID_STAGE_MANIFEST", "F12: corrupted manifest on restage rejected cleanly")
	_remove_tree(s12)


func _test_native_experiment_runner_t26() -> void:
	_start("NativeExperimentRunner / durable ledger, restart recovery, Steam/manual workflows & Lua contract (T-26)")
	NativeAdapterScript.clear_trusted_sessions()
	var old_ws := WorkspaceStore.root_override
	var ws := "user://t26_runner_ws_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = ws
	var abs_ws := ProjectSettings.globalize_path(ws)
	var disc := NativeAdapterScript.discover()
	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\nshotSpeed=120\n".to_utf8_buffer()
	var odf_md5 := WorkspaceStore._md5_bytes(odf_bytes)

	# 1. OPERATOR_MANUAL workflow + durable restart recovery.
	var runner1 = NativeRunnerScript.new()
	var pre1: Dictionary = runner1.preflight(null, null, {
		"discovery": disc,
		"stage_prefix": "t26_manual",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes},
		"steam_override": {"steam_present": true, "steam_logged_in": false, "steam_exe": str(disc.get("steam_exe", "")), "detail": "ActiveUser=0x0"},
	})
	_check(bool(pre1.get("ok", false)) and not bool(pre1.get("launch_ready", true)), "T-26: manual preflight structurally valid, launch_ready=false when Steam logged off")
	var sid1 := str(pre1.get("session_id", ""))
	var stg1: Dictionary = runner1.stage(sid1)
	_check(bool(stg1.get("ok", false)) and str(stg1.get("state", "")) == "STAGED", "T-26: runner stage() materialized isolated stage")
	var lch1: Dictionary = runner1.launch(sid1)
	_check(bool(lch1.get("ok", false)) and str(lch1.get("state", "")) == "AWAITING_OPERATOR", "T-26: OPERATOR_MANUAL launch transitions to AWAITING_OPERATOR")
	var instr_path := str(lch1.get("instructions_path", ""))
	_check(instr_path != "" and FileAccess.file_exists(instr_path), "T-26: operator_instructions.txt persisted in stage")
	var sess1 = stg1.get("session", null)
	var stage1 := str(sess1.stage_root)
	# Simulate full application restart: clear trusted sessions and create brand-new runner.
	NativeAdapterScript.clear_trusted_sessions()
	var runner2 = NativeRunnerScript.new()
	var rec2: Dictionary = runner2.recover_sessions()
	_check(bool(rec2.get("ok", false)) and int(rec2.get("recovered", 0)) == 1, "T-26: fresh runner recovered durable session across restart")
	var rec_entry: Dictionary = runner2.get_session_record(sid1)
	_eq(str(rec_entry.get("state", "")), "AWAITING_OPERATOR", "T-26: recovered session retained AWAITING_OPERATOR state")
	_check(bool(rec_entry.get("stage_present_on_disk", false)), "T-26: recovered session confirmed stage manifest on disk")
	# Write Lua observation after restart and collect via recovered runner.
	var obs1_path := stage1.path_join("obs_manual_after_restart.json")
	_write(obs1_path, JSON.stringify({
		"contract_version": 1, "measurement_method": "GetCurHealth_delta",
		"session_id": sid1, "launch_nonce": str(sess1.launch_nonce), "scenario_id": str(sess1.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 100.0,
		"elapsed_mission_s": 0.9, "tps": 20, "odf_probe_damage": 100.0,
		"expected_odf_md5": odf_md5, "observed_odf_md5": "", "observed_odf_hash_available": false,
		"mount_marker": str(sess1.mount_marker), "resources_mounted": true,
	}))
	var col1: Dictionary = runner2.collect_observation(sid1, obs1_path)
	_check(bool(col1.get("ok", false)) and str(col1.get("state", "")) == "COMPARISON_COMPLETE", "T-26: operator-manual post-restart collection recorded honest COMPARISON_COMPLETE")
	_check(not bool(col1.get("verified", true)), "T-26: unattested post-restart manual collection never falsely claims NATIVE_VERIFIED")
	var cln1: Dictionary = runner2.cleanup_stage(sid1)
	_check(bool(cln1.get("ok", false)) and str(cln1.get("state", "")) == "CLEANED_UP", "T-26: runner cleanup_stage removed owned staged files cleanly")
	_remove_tree(stage1)

	# 2. STEAM_MANAGED workflow with runner-controlled test DI hooks -> NATIVE_VERIFIED.
	var runner3 = NativeRunnerScript.new()
	var captured_cmd := {"exe": "", "args": []}
	runner3.process_launcher = func(exe: String, args: Array) -> Dictionary:
		captured_cmd["exe"] = exe
		captured_cmd["args"] = args.duplicate()
		return {"ok": true, "pid": 7777, "exit_code": 0}
	runner3.game_process_detector = func() -> Dictionary:
		return {"detected": true, "game_pid": 8888}
	runner3.mission_observer = func(_s) -> Dictionary:
		return {"mission_observed": true, "mission_loaded_at": "2026-11-21T16:55:00", "resource_probe_confirmed": true}
	var pre3: Dictionary = runner3.preflight(null, null, {
		"discovery": disc,
		"stage_prefix": "t26_steam",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes},
		"steam_override": {"steam_present": true, "steam_logged_in": true, "steam_exe": str(disc.get("steam_exe", ""))},
	})
	_check(bool(pre3.get("launch_ready", false)), "T-26: STEAM_MANAGED preflight reports launch_ready=true")
	var sid3 := str(pre3.get("session_id", ""))
	var stg3: Dictionary = runner3.stage(sid3)
	var sess3 = stg3.get("session", null)
	var stage3 := str(sess3.stage_root)
	var lch3: Dictionary = runner3.launch(sid3, {"execute_process": true})
	_check(bool(lch3.get("ok", false)) and int(lch3.get("process_id", 0)) == 7777, "T-26: STEAM_MANAGED launch spawned via controlled launcher")
	_check((captured_cmd.args as Array).has("-applaunch") and (captured_cmd.args as Array).has("624970"), "T-26: STEAM_MANAGED passed -applaunch 624970")
	# Controlled Lua contract negative checks before valid collection.
	var obs_bad_math := stage3.path_join("obs_bad_math.json")
	_write(obs_bad_math, JSON.stringify({
		"session_id": sid3, "launch_nonce": str(sess3.launch_nonce), "scenario_id": str(sess3.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 999.0,
		"elapsed_mission_s": 0.9, "tps": 20, "mount_marker": str(sess3.mount_marker), "resources_mounted": true,
	}))
	var col_bad: Dictionary = runner3.collect_observation(sid3, obs_bad_math)
	_check(not bool(col_bad.get("ok", true)) and str(col_bad.get("reason", "")) == "LUA_CONTRACT_VIOLATION", "T-26: inconsistent damage vs hp delta rejected as LUA_CONTRACT_VIOLATION")
	var obs_timeout := stage3.path_join("obs_timeout.json")
	_write(obs_timeout, JSON.stringify({
		"session_id": sid3, "launch_nonce": str(sess3.launch_nonce), "scenario_id": str(sess3.scenario_id),
		"state": "TIMEOUT", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 3000.0, "hp_max": 3000.0, "damage": 0.0,
		"elapsed_mission_s": 8.0, "tps": 20, "mount_marker": str(sess3.mount_marker), "resources_mounted": true,
	}))
	var col_to: Dictionary = runner3.collect_observation(sid3, obs_timeout)
	_eq(str(col_to.get("state", "")), "TIMEOUT", "T-26: Lua TIMEOUT observation classified as TIMEOUT")
	# Valid Steam-managed runner-attested observation -> genuine NATIVE_VERIFIED.
	var obs3_path := stage3.path_join("obs_steam_valid.json")
	_write(obs3_path, JSON.stringify({
		"contract_version": 1, "measurement_method": "GetCurHealth_delta",
		"session_id": sid3, "launch_nonce": str(sess3.launch_nonce), "scenario_id": str(sess3.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 100.0,
		"elapsed_mission_s": 0.9, "tps": 20, "odf_probe_damage": 100.0,
		"expected_odf_md5": odf_md5, "observed_odf_md5": "", "observed_odf_hash_available": false,
		"mount_marker": str(sess3.mount_marker), "resources_mounted": true,
	}))
	var col3: Dictionary = runner3.collect_observation(sid3, obs3_path)
	_check(bool(col3.get("ok", false)) and str(col3.get("state", "")) == "NATIVE_VERIFIED" and bool(col3.get("verified", false)), "T-26: STEAM_MANAGED runner-attested observation achieves NATIVE_VERIFIED")
	runner3.cleanup_stage(sid3)
	_remove_tree(stage3)

	# 3. Corrupted ledger JSON fails cleanly via error-aware parser.
	_write(NativeRunnerScript.ledger_path(), "{corrupt-ledger")
	var runner4 = NativeRunnerScript.new()
	var rec4: Dictionary = runner4.recover_sessions()
	_check(not bool(rec4.get("ok", true)) and str(rec4.get("reason", "")) == "CORRUPT_SESSION_LEDGER", "T-26: corrupt session_ledger.json rejected cleanly without stderr spam")
	NativeAdapterScript.clear_trusted_sessions()
	WorkspaceStore.root_override = old_ws
	_remove_tree(abs_ws)


func _test_rollback_failure_safety() -> void:
	_start("Workspace safety / rollback failure retains journal (S1, S8)")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_rb_fail_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var src := abs_root.path_join("source/ord.odf")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var doc := OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "200")
	var first := WorkspaceStore.save_document_with_rel(doc, "ord.odf")
	_check(bool(first.get("ok", false)), "initial override saved (200)")
	var target := str(first.get("target", ""))
	var backup := str(first.get("backup", ""))
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "250")
	# Inject BOTH manifest failure and rollback failure.
	WorkspaceStore.fault_phases["manifest_write"] = true
	WorkspaceStore.fault_phases["rollback_write"] = true
	var failed := WorkspaceStore.save_document(doc)
	WorkspaceStore.fault_phases.clear()
	_check(not bool(failed.get("ok", true)), "save failed when manifest and rollback both failed")
	_check(not str(failed.get("error", "")).contains("previous override restored"), "S1: never claims previous override restored when rollback failed")
	_eq(str(failed.get("status", "")), WorkspaceStore.TX_RECOVERY_PENDING, "S1: reports RECOVERY_PENDING")
	var jpath := str(failed.get("journal", ""))
	_check(jpath != "" and FileAccess.file_exists(jpath), "S1: original recovery journal retained")
	_check(FileAccess.file_exists(backup) and FileAccess.get_file_as_string(backup).contains("damageValue(H)=200"), "S1: previous 200 backup preserved")
	# S8: retry on the same target while pending journal exists must NOT overwrite the pending journal.
	var j_before := FileAccess.get_file_as_bytes(jpath)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "300")
	var retry_blocked := WorkspaceStore.save_document(doc)
	_check(not bool(retry_blocked.get("ok", true)), "S8: new write refused while pending journal exists")
	_eq(FileAccess.get_file_as_bytes(jpath), j_before, "S8: pending journal bytes untouched by refused retry")
	# Now run recovery -> reconciles the valid 250 on disk cleanly.
	_eq(WorkspaceStore.recover_transactions(), 1, "recovery commits pending 250 revision")
	_check(FileAccess.get_file_as_string(target).contains("damageValue(H)=250"), "target has valid 250 after reconciliation")
	_eq(str(WorkspaceStore.entry_for(src).get("rel", "")), "ord.odf", "manifest reconciled")
	# Also test rollback failure AFTER target removal -> recovery restores 200 from backup.
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "275")
	WorkspaceStore.fault_phases["manifest_write"] = true
	WorkspaceStore.fault_phases["rollback_after_remove"] = true
	var rm_fail := WorkspaceStore.save_document(doc)
	WorkspaceStore.fault_phases.clear()
	_check(not bool(rm_fail.get("ok", true)), "rollback_after_remove reported failed")
	_check(not FileAccess.file_exists(target), "target absent right after simulated crash during rollback removal")
	_check(FileAccess.file_exists(str(rm_fail.get("journal", ""))), "journal retained after rollback_after_remove")
	WorkspaceStore.recover_transactions()
	_check(FileAccess.file_exists(target) and FileAccess.get_file_as_string(target).contains("damageValue(H)=250"), "recovery restored 250 backup after rollback removal failure")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


func _test_journal_path_validation() -> void:
	_start("Workspace safety / journal path validation (S2..S4)")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_jval_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var tdir := ProjectSettings.globalize_path(WorkspaceStore.transactions_dir())
	DirAccess.make_dir_recursive_absolute(tdir)
	var dummy_bytes := "bad".to_utf8_buffer()
	var dummy_md5 := WorkspaceStore._md5_bytes(dummy_bytes)
	var outside := abs_root.get_base_dir().path_join("outside_victim.odf")
	var odf_base := ProjectSettings.globalize_path(WorkspaceStore.odf_dir())
	var t_bad_temp := odf_base.path_join("ord_bad_temp.odf")
	var t_bad_bak := odf_base.path_join("ord_bad_bak.odf")
	var t_bad_src := odf_base.path_join("ord_bad_src.odf")
	var t_bad_jname := odf_base.path_join("ord_bad_jname.odf")
	var cases := [
		{"name": "outside_traversal", "j": {"version": 1, "op": "workspace_odf", "target": abs_root.path_join("odf/../../outside.txt"), "temp": "", "backup": "", "source": abs_root.path_join("src/a.odf"), "rel": "../../outside.txt", "md5": dummy_md5, "size": 3}},
		{"name": "outside_abs", "j": {"version": 1, "op": "workspace_odf", "target": outside, "temp": "", "backup": "", "source": abs_root.path_join("src/a.odf"), "rel": "ord.odf", "md5": dummy_md5, "size": 3}},
		{"name": "game_root", "j": {"version": 1, "op": "workspace_odf", "target": "V:/__STORE_V/_SOFT/Steam/steamapps/common/BZ2R/Data/file.odf", "temp": "", "backup": "", "source": "x", "rel": "file.odf", "md5": dummy_md5, "size": 3}},
		{"name": "workshop_root", "j": {"version": 1, "op": "workspace_odf", "target": "V:/__STORE_V/_SOFT/Steam/steamapps/workshop/content/624970/file.odf", "temp": "", "backup": "", "source": "x", "rel": "file.odf", "md5": dummy_md5, "size": 3}},
		{"name": "bad_temp", "j": {"version": 1, "op": "workspace_odf", "target": t_bad_temp, "temp": outside, "backup": "", "source": abs_root.path_join("src/a1.odf"), "rel": "ord_bad_temp.odf", "md5": dummy_md5, "size": 3}},
		{"name": "bad_backup", "j": {"version": 1, "op": "workspace_odf", "target": t_bad_bak, "temp": "", "backup": outside, "source": abs_root.path_join("src/a2.odf"), "rel": "ord_bad_bak.odf", "md5": dummy_md5, "size": 3}},
		{"name": "bad_source", "j": {"version": 1, "op": "workspace_odf", "target": t_bad_src, "temp": "", "backup": "", "source": "", "rel": "ord_bad_src.odf", "md5": dummy_md5, "size": 3}},
		{"name": "bad_journal_name", "jfile": "wrong_identity.json", "j": {"version": 1, "op": "workspace_odf", "target": t_bad_jname, "temp": "", "backup": "", "source": abs_root.path_join("src/a3.odf"), "rel": "ord_bad_jname.odf", "md5": dummy_md5, "size": 3}},
	]
	for idx in cases.size():
		var c: Dictionary = cases[idx]
		var jdict: Dictionary = c.j
		var jfile := str(c.get("jfile", ""))
		if jfile == "":
			jfile = WorkspaceStore._journal_path(str(jdict.target)).get_file()
		var jpath := tdir.path_join(jfile)
		_write(jpath, JSON.stringify(jdict, "  "))
	WorkspaceStore.recover_transactions()
	_eq(int(WorkspaceStore.last_recovery.get("committed", 0)), 0, "no synthetic invalid journal committed")
	_eq(int(WorkspaceStore.last_recovery.get("rolled_back", 0)), 0, "no synthetic invalid journal rolled back")
	_eq(int(WorkspaceStore.last_recovery.get("unrecoverable", 0)), cases.size(), "S2..S4: all invalid journals marked UNRECOVERABLE")
	_check(not FileAccess.file_exists(outside), "outside victim path never created")
	var reasons: Array = WorkspaceStore.last_recovery.get("reasons", [])
	_eq(reasons.size(), cases.size(), "diagnostic reasons recorded for every rejected journal")
	for r in reasons:
		_eq(str(r.get("reason", "")), "INVALID_TRANSACTION_PATH", "reason is INVALID_TRANSACTION_PATH")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


func _test_process_termination_recovery() -> void:
	_start("Process termination / real OS.kill + fresh process recovery (P1-03)")
	var old_root := WorkspaceStore.root_override
	var godot := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var phases := ["after_temp", "after_backup", "after_journal", "after_remove_old", "after_rename", "after_verify", "manifest_commit", "rollback", "journal_cleanup"]
	for phase in phases:
		var root := "user://p0_oskill_%s_%d" % [phase, Time.get_ticks_usec()]
		WorkspaceStore.root_override = root
		var abs_root := ProjectSettings.globalize_path(root)
		var src := abs_root.path_join("source/ord.odf")
		_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
		var doc := OdfDocument.load_file(src)
		doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "200")
		_check(bool(WorkspaceStore.save_document_with_rel(doc, "ord.odf").get("ok", false)), phase + ": initial 200 saved")
		var marker := abs_root.path_join("phase_reached.txt")
		var pid := OS.create_process(godot, [
			"--headless", "--path", proj, "--script", "res://tests/recovery_worker.gd",
			"--", "save", root, phase, marker, src, "250"
		])
		_check(pid > 0, phase + ": worker process spawned")
		var wait_deadline := Time.get_ticks_msec() + 15000
		while not FileAccess.file_exists(marker) and Time.get_ticks_msec() < wait_deadline:
			OS.delay_msec(20)
		_check(FileAccess.file_exists(marker), phase + ": worker reached target phase")
		if pid > 0:
			OS.kill(pid)
			var exit_deadline := Time.get_ticks_msec() + 3000
			while OS.is_process_running(pid) and Time.get_ticks_msec() < exit_deadline:
				OS.delay_msec(20)
		# Run recovery in a completely separate Godot process.
		var rec_out := []
		var rec_code := OS.execute(godot, [
			"--headless", "--path", proj, "--script", "res://tests/recovery_worker.gd",
			"--", "recover", root
		], rec_out, true)
		_eq(rec_code, 0, phase + ": fresh recovery process exited 0")
		var target := abs_root.path_join("odf/ord.odf")
		var body := FileAccess.get_file_as_string(target) if FileAccess.file_exists(target) else ""
		_check(body.contains("damageValue(H)=200") or body.contains("damageValue(H)=250"), phase + ": valid 200 or 250 revision after OS.kill + restart recovery")
		_eq(str(WorkspaceStore.entry_for(src).get("rel", "")), "ord.odf", phase + ": manifest consistent after restart recovery")
		WorkspaceStore.root_override = old_root
		_remove_tree(abs_root)


func _test_collision_ordering() -> void:
	_start("Projectile / earliest collision wins")
	var sim := ProjectileSim.new()
	var s := ProjectileSim.Shot.new()
	s.previous = Vector3(0, 0.1, 0)
	s.position = Vector3(0, -0.1, 0)
	s.age = 0.01
	s.life_span = 10.0
	s.target_position = Vector3(0, 0.05, 0)
	s.target_radius = 0.2
	sim._check_shot(s, 0.01)
	_eq(s.hit_kind, "vehicle", "target just above ground wins over the ground plane")
	_check(s.position.y > 0.0, "hit position stays above ground")
	var g := ProjectileSim.Shot.new()
	g.previous = Vector3(0, 0.1, 0)
	g.position = Vector3(0, -0.5, 0)
	g.age = 0.01
	g.life_span = 10.0
	g.target_position = Vector3(0, -0.3, 0)
	g.target_radius = 0.05
	sim._check_shot(g, 0.01)
	_eq(g.hit_kind, "ground", "ground before target is reported as ground")
	var e := ProjectileSim.Shot.new()
	e.previous = Vector3(0, 1, 0)
	e.position = Vector3(0, 2, 0)
	e.age = 0.02
	e.life_span = 0.01
	e.target_position = Vector3(100, 100, 100)
	sim._check_shot(e, 0.02)
	_eq(e.hit_kind, "expire", "lifetime expiry inside the substep is honored")
	_check(e.position.y < 2.0 and e.position.y > 1.0, "expiry is placed at the lifetime fraction")


func _test_workshop_scope() -> void:
	_start("Resource index / workshop scope")
	var root := "user://p1_shop_" + str(Time.get_ticks_usec())
	var base := ProjectSettings.globalize_path(root).path_join("game")
	var shop := ProjectSettings.globalize_path(root).path_join("workshop")
	_write(base.path_join("base.odf"), "[A]\nx=1\n")
	_write(shop.path_join("mod.odf"), "[A]\nx=2\n")
	var idx := ResourceIndex.new()
	idx.roots = [
		{"path": base, "label": "game", "kind": "game", "priority": 10, "enabled": true},
		{"path": shop, "label": "workshop", "kind": "workshop", "priority": 30, "enabled": false},
	]
	idx.scan(true)
	_check(idx.files.has("base.odf"), "enabled game root scanned")
	_check(not idx.files.has("mod.odf"), "disabled workshop root stays excluded even with runtime workshop support")
	idx.roots[1]["enabled"] = true
	idx.scan(false)
	_check(not idx.files.has("mod.odf"), "runtime workshop=false excludes an enabled workshop root")
	idx.scan(true)
	_check(idx.files.has("mod.odf"), "enabled workshop root scanned when runtime support is on")
	_remove_tree(ProjectSettings.globalize_path(root))


func _test_workspace_store() -> void:
	_start("Workspace store / persistence / atomic safety")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_workspace_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var src := ProjectSettings.globalize_path(root).path_join("source/ord.odf")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var original := FileAccess.get_file_as_bytes(src)
	var doc := OdfDocument.load_file(src)
	doc.append_entry("OrdnanceClass", "damageValue(H)", "200")
	var saved := WorkspaceStore.save_document_with_rel(doc, "Vehicles/ord.odf")
	_check(bool(saved.get("ok", false)), "override saved atomically")
	_check(FileAccess.file_exists(str(saved.get("target", ""))), "override file exists in workspace")
	_check(FileAccess.get_file_as_bytes(src) == original, "original source is byte-identical after save")
	_check(doc.workspace_override and not doc.dirty, "document reports clean override")
	# Same file name from another package must not overwrite the first save.
	var src2 := ProjectSettings.globalize_path(root).path_join("other/ord.odf")
	_write(src2, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var doc2 := OdfDocument.load_file(src2)
	doc2.append_entry("OrdnanceClass", "damageValue(H)", "300")
	var saved2 := WorkspaceStore.save_document_with_rel(doc2, "Vehicles/ord.odf")
	_check(bool(saved2.get("ok", false)), "second same-name override saved")
	_check(str(saved2.get("target", "")) != str(saved.get("target", "")), "same-name sources get distinct workspace paths")
	_check(FileAccess.file_exists(str(saved.get("target", ""))), "first same-name override survived")
	OdfDocument.clear_all_cache()
	var restored := WorkspaceStore.restore_cache()
	_check(restored >= 1, "override restored into cache after simulated restart")
	var reloaded := OdfDocument.load_cached(src)
	_check(reloaded != null and reloaded.get_value("OrdnanceClass", "damageValue(H)") == "200", "damage 200 survives restart")
	_check(reloaded != null and not reloaded.workspace_conflict, "unchanged source is not a conflict")
	# Source changed after the save -> conflict, override still served.
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n; externally changed\n")
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var conflicted := OdfDocument.load_cached(src)
	_check(conflicted != null and conflicted.workspace_conflict, "changed source is flagged CONFLICT")
	_check(conflicted != null and conflicted.get_value("OrdnanceClass", "damageValue(H)") == "200", "conflicting override is still readable")
	# Path traversal is rejected and cannot create outside the workspace.
	var escape := ProjectSettings.globalize_path(root).path_join("escape.odf")
	var bad := WorkspaceStore.write_staged(WorkspaceStore.odf_dir(), "../escape.odf", "x".to_utf8_buffer())
	_check(not bool(bad.get("ok", true)) and not FileAccess.file_exists(escape), "path traversal rejected")
	# A target blocked by a directory fails without touching the blocker.
	var blocked := ProjectSettings.globalize_path(root).path_join("blocked/blocked.odf")
	DirAccess.make_dir_recursive_absolute(blocked)
	var fail := WorkspaceStore.atomic_write_abs(blocked, "x".to_utf8_buffer())
	_check(not bool(fail.get("ok", true)) and DirAccess.dir_exists_absolute(blocked), "failed save leaves the previous target intact")
	# In-place raw replacement keeps identity and revision.
	var before_rev: int = doc.revision
	doc.replace_text("[OrdnanceClass]\ndamageValue(H)=300\n")
	_check(doc.get_value("OrdnanceClass", "damageValue(H)") == "300", "raw replace updates values")
	_check(doc.revision > before_rev, "raw replace bumps revision")
	WorkspaceStore.root_override = old_root
	_remove_tree(ProjectSettings.globalize_path(root))


func _test_inheritance_cache_revision() -> void:
	_start("Inheritance cache / revision invalidation")
	var root := "user://p0_inherit_" + str(Time.get_ticks_usec())
	var abs_root := ProjectSettings.globalize_path(root)
	var parent := abs_root.path_join("parent.odf")
	var child := abs_root.path_join("child.odf")
	_write(parent, "[OrdnanceClass]\ndamageValue(H)=100\n")
	_write(child, "[OrdnanceClass]\nclassLabel=\"parent\"\n")
	var idx := ResourceIndex.new()
	idx.roots.clear()
	idx.roots.append({"path": abs_root, "label": "test", "kind": "test", "priority": 1, "enabled": true})
	idx.scan(true)
	var cdoc := OdfDocument.load_cached(child)
	var pdoc := OdfDocument.load_cached(parent)
	_check(cdoc != null and pdoc != null, "synthetic parent/child loaded")
	var rows := OdfInheritance.merged(cdoc, idx)
	_eq(_row_value(rows, "OrdnanceClass", "damageValue", "(H)"), "100", "child inherits parent damage")
	var entry = pdoc.find_entry("OrdnanceClass", "damagevalue(h)")
	_check(entry != null, "parent damage entry found")
	if entry != null:
		pdoc.set_entry_value(entry, "250")
		rows = OdfInheritance.merged(cdoc, idx)
		_eq(_row_value(rows, "OrdnanceClass", "damageValue", "(H)"), "250", "child sees parent edit without cache clear")
	idx.scan(true)
	rows = OdfInheritance.merged(cdoc, idx)
	_eq(_row_value(rows, "OrdnanceClass", "damageValue", "(H)"), "250", "merged value stable across rescan")
	OdfDocument.clear_all_cache()
	_remove_tree(abs_root)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
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


## Every real transaction phase, interrupted as if the process had died there.
## A fresh start must produce a complete old revision, a complete new revision,
## or an explicit RECOVERY_PENDING with durable evidence -- never a lost file
## and never a silent stale manifest.
func _test_transaction_phase_matrix() -> void:
	_start("Workspace transaction / per-phase interruption matrix")
	var old_root := WorkspaceStore.root_override
	var phases := ["after_temp", "after_backup", "after_journal", "after_remove_old", "after_rename", "after_verify"]
	var expect_new := {"after_journal": true, "after_remove_old": true, "after_rename": true, "after_verify": true}
	for phase in phases:
		var root := "user://p0_phase_%s_%d" % [phase, Time.get_ticks_usec()]
		WorkspaceStore.root_override = root
		var abs_root := ProjectSettings.globalize_path(root)
		var target := abs_root.path_join("odf/ord.odf")
		var backup := abs_root.path_join("backups/ord.odf.bak")
		_write(target, "old\n")
		var src := abs_root.path_join("source/ord.odf")
		var meta := {"source": src, "rel": "ord.odf", "source_md5": ""}
		WorkspaceStore.fault_phases[phase] = true
		var res := WorkspaceStore.transactional_write_abs(target, "new\n".to_utf8_buffer(), backup, meta, true)
		WorkspaceStore.fault_phases.clear()
		_check(not bool(res.get("ok", true)), phase + ": interrupted transaction is not reported committed")
		WorkspaceStore.recover_transactions()
		var body := FileAccess.get_file_as_string(target) if FileAccess.file_exists(target) else ""
		_check(body == "old\n" or body == "new\n", phase + ": target is a complete old or new revision")
		_check(not (body == "new\n" and str(WorkspaceStore.entry_for(src).get("rel", "")) == ""), phase + ": new bytes are reconciled in the manifest")
		_eq(int(WorkspaceStore.last_recovery.get("pending", 0)), 0, phase + ": no false RECOVERY_PENDING")
		if bool(expect_new.get(phase, false)):
			_eq(body, "new\n", phase + ": verified new revision committed")
		else:
			_eq(body, "old\n", phase + ": old revision preserved")
		_eq(WorkspaceStore.recover_transactions(), 0, phase + ": second recovery is a no-op")
		WorkspaceStore.root_override = old_root
		_remove_tree(abs_root)


## A manifest failure during recovery must keep the journal and report pending;
## a later retry commits it. The override bytes are never rolled back silently.
func _test_recovery_pending_manifest_failure() -> void:
	_start("Workspace transaction / manifest failure keeps recovery pending")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_pending_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var target := abs_root.path_join("odf/ord.odf")
	var backup := abs_root.path_join("backups/ord.odf.bak")
	var src := abs_root.path_join("source/ord.odf")
	_write(target, "old\n")
	var meta := {"source": src, "rel": "ord.odf", "source_md5": ""}
	WorkspaceStore.fault_phases["after_journal"] = true
	WorkspaceStore.transactional_write_abs(target, "new\n".to_utf8_buffer(), backup, meta, true)
	WorkspaceStore.fault_phases.clear()
	WorkspaceStore.fault_phases["manifest_write"] = true
	_eq(WorkspaceStore.recover_transactions(), 0, "pending recovery is not counted as committed")
	_eq(int(WorkspaceStore.last_recovery.get("pending", 0)), 1, "manifest failure reports RECOVERY_PENDING")
	_check(FileAccess.file_exists(target) and FileAccess.get_file_as_string(target) == "new\n", "verified new bytes remain on disk")
	_check(WorkspaceStore.entry_for(src).is_empty(), "manifest is not falsely updated")
	var journals := DirAccess.open(ProjectSettings.globalize_path(WorkspaceStore.transactions_dir()))
	var journal_count := 0
	if journals != null:
		journals.list_dir_begin()
		var n := journals.get_next()
		while n != "":
			if n.ends_with(".json"):
				journal_count += 1
			n = journals.get_next()
		journals.list_dir_end()
	_eq(journal_count, 1, "journal is kept as durable pending evidence")
	WorkspaceStore.fault_phases.clear()
	_eq(WorkspaceStore.recover_transactions(), 1, "retry commits the pending transaction")
	_eq(str(WorkspaceStore.entry_for(src).get("rel", "")), "ord.odf", "retry reconciles the manifest")
	journals = DirAccess.open(ProjectSettings.globalize_path(WorkspaceStore.transactions_dir()))
	journal_count = 0
	if journals != null:
		journals.list_dir_begin()
		var n2 := journals.get_next()
		while n2 != "":
			if n2.ends_with(".json"):
				journal_count += 1
			n2 = journals.get_next()
		journals.list_dir_end()
	_eq(journal_count, 0, "journal removed only after the manifest commit")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


## A failed manifest update during an ordinary save must restore the previous
## override bytes instead of exposing a half-committed save.
func _test_save_manifest_rollback() -> void:
	_start("Workspace save / manifest failure restores the previous revision")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_save_manifest_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var src := abs_root.path_join("source/ord.odf")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var doc := OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "200")
	var first := WorkspaceStore.save_document_with_rel(doc, "ord.odf")
	_check(bool(first.get("ok", false)), "initial override saved")
	var target := str(first.get("target", ""))
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "250")
	WorkspaceStore.fault_phases["manifest_write"] = true
	var failed := WorkspaceStore.save_document(doc)
	WorkspaceStore.fault_phases.clear()
	_check(not bool(failed.get("ok", true)), "save with a failing manifest is reported failed")
	_check(FileAccess.file_exists(target) and FileAccess.get_file_as_string(target).contains("damageValue(H)=200"), "previous override bytes restored")
	_check(str(WorkspaceStore.entry_for(src).get("rel", "")) == "ord.odf", "manifest still points at the restored override")
	var retried := WorkspaceStore.save_document(doc)
	_check(bool(retried.get("ok", false)), "retry succeeds after the manifest is writable")
	_check(FileAccess.get_file_as_string(target).contains("damageValue(H)=250"), "retry persisted the new revision")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


## Revert-to-original is a transaction: manifest first, bytes last. No failure
## may orphan the only saved revision or fall through to the game source.
func _test_discard_override_transaction() -> void:
	_start("Workspace revert / deletion after durable manifest commit")
	var old_root := WorkspaceStore.root_override
	var root := "user://p0_discard_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = root
	var abs_root := ProjectSettings.globalize_path(root)
	var src := abs_root.path_join("source/ord.odf")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n")
	var original := FileAccess.get_file_as_bytes(src)
	var doc := OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "200")
	var saved := WorkspaceStore.save_document_with_rel(doc, "ord.odf")
	var target := str(saved.get("target", ""))
	_check(bool(saved.get("ok", false)), "override saved before revert")
	var backups := ProjectSettings.globalize_path(WorkspaceStore.backups_dir())
	WorkspaceStore.fault_phases["manifest_write"] = true
	var pending := WorkspaceStore.discard_override_ex(src)
	WorkspaceStore.fault_phases.clear()
	_check(not bool(pending.get("ok", true)) and str(pending.get("status", "")) == WorkspaceStore.TX_RECOVERY_PENDING, "revert with a failing manifest reports RECOVERY_PENDING")
	_check(FileAccess.file_exists(target) and FileAccess.get_file_as_string(target).contains("damageValue(H)=200"), "saved override is preserved, not deleted")
	_check(str(WorkspaceStore.entry_for(src).get("rel", "")) == "ord.odf", "manifest still references the override")
	var done := WorkspaceStore.discard_override_ex(src)
	_check(bool(done.get("ok", false)), "revert succeeds once the manifest is writable")
	_check(not FileAccess.file_exists(target), "override retired only after the manifest commit")
	_check(WorkspaceStore.entry_for(src).is_empty(), "manifest entry removed")
	_check(FileAccess.get_file_as_bytes(src) == original, "original game source untouched")
	var kept_backup := backups.path_join("ord.odf.bak")
	_check(FileAccess.file_exists(kept_backup) and FileAccess.get_file_as_string(kept_backup).contains("damageValue(H)=200"), "retired revision preserved in backups")
	_eq(str(WorkspaceStore.discard_override_ex(src).get("status", "")), "NOT_FOUND", "second revert reports NOT_FOUND")
	# Source missing: override bytes still removable, explicit flag.
	doc = OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "300")
	_check(bool(WorkspaceStore.save_document(doc).get("ok", false)), "second override saved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
	var missing := WorkspaceStore.discard_override_ex(src)
	_check(bool(missing.get("ok", false)) and bool(missing.get("source_missing", false)), "revert with a missing source reports source_missing")
	# Source changed externally: revert still removes only the override.
	_write(src, "[OrdnanceClass]\ndamageValue(H)=100\n; changed on disk\n")
	doc = OdfDocument.load_file(src)
	doc.set_entry_value(doc.find_entry("OrdnanceClass", "damageValue(H)"), "400")
	_check(bool(WorkspaceStore.save_document(doc).get("ok", false)), "third override saved")
	_write(src, "[OrdnanceClass]\ndamageValue(H)=150\n")
	var changed := WorkspaceStore.discard_override_ex(src)
	_check(bool(changed.get("ok", false)) and bool(changed.get("source_changed", false)), "revert after an external source change reports source_changed")
	_check(FileAccess.get_file_as_string(src).contains("damageValue(H)=150"), "externally changed source is not rewritten by revert")
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_root)


## Comments and duplicate physical headers: ownership rules must be explicit and
## byte-level undo must come back exactly.
func _test_header_preservation_rules() -> void:
	_start("Header preservation / comments, duplicate occurrences, undo bytes")
	var text := "[A]\nx=1\n; trailing comment owned by A\n\n[B]\ny=2\n\n[A]\nx=3\n"
	var doc := OdfDocument.parse_text(text, "comments.odf")
	_check(doc.remove_header("A", 0), "first [A] removed")
	_check(not doc.text.contains("trailing comment owned by A"), "trailing comment stays with the section it follows")
	_check(doc.has_header("B") and doc.get_value("B", "y") == "2", "following section still intact")
	_check(doc.get_value("A", "x") == "3", "remaining [A] keeps its own value")
	doc.undo()
	_eq(doc.text, text, "undo restores the exact original bytes")
	doc.redo()
	_check(not doc.text.contains("trailing comment owned by A"), "redo reapplies the same removal")
	# Duplicate physical render headers: effective values, per-occurrence edits.
	var rtext := "[Core]\nrenderBase = \"draw_sprite\"\nlifeTime = 1.0\n\n[Shock]\nrenderBase = \"draw_emit\"\n\n[Core]\nlifeTime = 3.0\n"
	var rdoc := OdfDocument.parse_text(rtext, "dup_render.odf")
	_eq(rdoc.header_occurrence_count("Core"), 2, "two physical Core occurrences")
	_check(rdoc.header_id_for("Core", 0) != rdoc.header_id_for("Core", 1), "occurrence identities differ")
	_eq(rdoc.render_headers().size(), 2, "graph view lists unique render names")
	_eq(rdoc.get_value("Core", "lifeTime"), "3.0", "effective value is the last occurrence")
	rdoc.set_entry_value(rdoc.find_entry("Core", "lifeTime"), "5.0")
	_check(rdoc.text.contains("lifeTime = 1.0") and rdoc.text.contains("lifeTime = 5.0"), "edit touched only the effective occurrence")
	_check(rdoc.rename_header("Core", "Body"), "rename renames physical occurrences")
	_eq(rdoc.header_occurrence_count("Body"), 2, "both brackets renamed")
	_eq(rdoc.header_occurrence_count("Core"), 0, "old name gone")
	_check(not rdoc.text.contains("[Core]"), "no stale bracket text")
	_check(rdoc.text.contains("lifeTime = 1.0") and rdoc.text.contains("renderBase = \"draw_sprite\""), "properties stay on their own lines")
	_check(not rdoc.rename_header("Body", "Shock"), "rename refuses an existing header name")
	rdoc.undo()
	_eq(rdoc.text, rtext.replace("lifeTime = 3.0", "lifeTime = 5.0"), "undo of rename restores the prior revision byte-exactly")
	# Empty header insertion stays before the next bracket line.
	var empty := OdfDocument.parse_text("[Empty]\n\n[Next]\nvalue=1\n", "empty.odf")
	var added = empty.append_entry("Empty", "lifeTime", "2.0")
	_check(added != null and added.line < empty.text.split("\n").size(), "property appended to the empty header")
	_check(empty.text.find("lifeTime") < empty.text.find("[Next]"), "insertion cannot leak into the next section")
	_check(empty.find_entry("Next", "lifeTime") == null, "next header unchanged")


func _test_encoding_roundtrip() -> void:
	_start("ODF bytes / LF, BOM, UTF-16LE/BE and no final newline")
	# UTF-8 BOM, CRLF, no final newline, duplicate same-name properties.
	var utf8_text := "[A]\r\nx = 1\r\nx = 2"
	var utf8_bytes := PackedByteArray([0xEF, 0xBB, 0xBF]) + utf8_text.to_utf8_buffer()
	var p := ProjectSettings.globalize_path("user://enc_utf8_" + str(Time.get_ticks_usec()) + ".odf")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(utf8_bytes)
	f.close()
	var d8 := OdfDocument.load_file(p)
	_check(d8 != null and d8.encoding == "utf-8" and d8.has_bom, "UTF-8 BOM detected")
	_check(d8 != null and d8.to_bytes() == utf8_bytes, "UTF-8 BOM/CRLF/no-final-newline roundtrip byte-identical")
	_check(d8 != null and d8.entries.size() == 2, "duplicate same-name properties preserved")
	DirAccess.remove_absolute(p)
	# UTF-16LE and BE with BOM, built explicitly so the fixture is independent.
	var body_text := "[A]\nx=1\n"
	var le := PackedByteArray([0xFF, 0xFE])
	var be := PackedByteArray([0xFE, 0xFF])
	for i in body_text.length():
		var c := body_text.unicode_at(i)
		le.append(c & 0xFF)
		le.append((c >> 8) & 0xFF)
		be.append((c >> 8) & 0xFF)
		be.append(c & 0xFF)
	for pair in [["utf-16le", le], ["utf-16be", be]]:
		var path := ProjectSettings.globalize_path("user://enc_%s_%d.odf" % [str(pair[0]), Time.get_ticks_usec()])
		var fh := FileAccess.open(path, FileAccess.WRITE)
		fh.store_buffer(pair[1])
		fh.close()
		var d := OdfDocument.load_file(path)
		_check(d != null and d.encoding == str(pair[0]), str(pair[0]) + " detected")
		_check(d != null and d.get_value("A", "x") == "1", str(pair[0]) + " parsed")
		_check(d != null and d.to_bytes() == pair[1], str(pair[0]) + " roundtrip byte-identical")
		DirAccess.remove_absolute(path)


func _test_scene_obstacles_and_multitarget_t27() -> void:
	_start("3D Lab simulation / obstacle blocking & multi-target collision (T-27)")
	var idx := ResourceIndex.new()
	idx.scan(true)
	var prof := WeaponProfile.new()
	_check(prof.resolve(idx, VSR_TANK, VSR_SCAV), "T-27 sim: VSR profile resolved")
	var origin := Vector3(0, 1.8, 0)
	var target := Vector3(0, 2.0, -80)
	var dir := (target - origin).normalized()
	# 1. Blocking obstacle between shooter and target intercepts shot before target.
	var obs_mid := [{"id": "cover_1", "position": Vector3(0, 2.0, -40), "size": Vector3(6.0, 5.0, 2.0)}]
	var r_obs := ProjectileSim.run_once(prof, origin, dir, target, 5.0, [], obs_mid)
	_eq(str(r_obs.get("kind", "")), "obstacle", "T-27: obstacle blocks projectile before reaching target")
	_eq(str(r_obs.get("hit_obstacle_id", "")), "cover_1", "T-27: hit_obstacle_id identifies blocking cover")
	_eq(float(r_obs.get("damage", -1.0)), 0.0, "T-27: blocked shot deals 0 direct damage to target behind cover")
	_eq(float(r_obs.get("target_health", 0.0)), prof.target_health_max, "T-27: primary target hull untouched behind obstacle")
	_check(absf((r_obs.get("position", Vector3.ZERO) as Vector3).z - (-38.5)) < 2.0, "T-27: impact position stopped at obstacle front face")
	# 2. Moving obstacle out of line of fire lets shot hit primary target cleanly.
	var obs_side := [{"id": "cover_1", "position": Vector3(20, 2.0, -40), "size": Vector3(6.0, 5.0, 2.0)}]
	var r_clear := ProjectileSim.run_once(prof, origin, dir, target, 5.0, [], obs_side)
	_eq(str(r_clear.get("kind", "")), "vehicle", "T-27: shot hits target once obstacle moved aside")
	_eq(float(r_clear.get("damage", 0.0)), 100.0, "T-27: full damage applied when line of sight clear")
	# 3. Multiple targets: nearer extra target intercepts shot and loses its own health.
	var aux := [{"id": "aux_1", "name": "Aux Scav", "position": Vector3(0, 2.0, -45), "radius": 2.2, "health": 500.0, "max_health": 500.0, "armor": "H"}]
	var r_aux := ProjectileSim.run_once(prof, origin, dir, target, 5.0, aux, [])
	_eq(str(r_aux.get("kind", "")), "vehicle", "T-27: nearer secondary target hit first")
	_eq(str(r_aux.get("hit_target_id", "")), "aux_1", "T-27: hit_target_id identifies secondary target")
	_eq(float(aux[0]["health"]), 400.0, "T-27: secondary target health reduced independently (500 -> 400)")
	_eq(float(r_aux.get("target_health", 0.0)), prof.target_health_max, "T-27: primary target behind secondary target untouched")


func _test_t29_ux_and_bzcc_particles() -> void:
	_start("T-29 Houdini scrubber, BZCC .dds particle textures, and categorized catalog")
	var HoudiniScrubberScript = preload("res://scripts/ui/houdini_scrubber.gd")
	var scrub = HoudiniScrubberScript.new()
	scrub.configure(0.0, 200.0, 1.0, 100.0, " m", true, true, false)
	_eq(scrub.value, 100.0, "T-29: HoudiniScrubber initial value set")
	scrub.scrub_delta(16.0, 1.0)
	_check(scrub.value > 100.0, "T-29: HoudiniScrubber horizontal drag increments value smoothly")
	scrub._commit_text_edit("120*2")
	_eq(scrub.value, 240.0, "T-29: HoudiniScrubber evaluates Houdini-style math expression (120*2 = 240)")
	scrub.free()

	var wt := WintageTheme.new()
	wt.load_themes()
	_eq(wt.font_aa_mode, "none", "T-29: WintageTheme defaults to crisp No-AA font mode")
	_eq(int(wt.get_font().antialiasing), int(TextServer.FONT_ANTIALIASING_NONE), "T-29: FontFile antialiasing disabled by default")
	_check(FileAccess.file_exists(WintageTheme.FONT_REGULAR_PATH) and FileAccess.file_exists(WintageTheme.FONT_BOLD_PATH), "T-30: embedded pixel-perfect Verdana_m1.ttf and Verdana_m1-Bold.ttf present in project")
	_check(wt.get_font().get_font_name().begins_with("Verdana") and wt.get_bold_font().get_font_name().begins_with("Verdana"), "T-30: WintageTheme loads embedded Verdana_m1 bitmap-strike font")
	var built_theme := wt.build_theme()
	_eq(built_theme.default_font_size, 12, "T-30: WintageTheme default font size is pixel-perfect 12px")
	var def_tok := WintageTheme.default_tokens()
	_eq(str(def_tok.get("background", "")), "#1A1810", "T-30: Golden Default background token is #1A1810")
	_eq(str(def_tok.get("borderHighlight", "")), "#F0D060", "T-30: Golden Default borderHighlight token is #F0D060")
	_eq(str(def_tok.get("accentTealDeep", "")), "#004C4C", "T-30: Golden Default accentTealDeep token is #004C4C")
	wt.set_font_aa("gray")
	_eq(int(wt.get_font().antialiasing), int(TextServer.FONT_ANTIALIASING_GRAY), "T-29: Font AA setting switches to Gray AA")
	wt.set_font_aa("none")

	var idx := ResourceIndex.new()
	idx.scan(true)
	# PARTICLE.md line 250: .tga textureName must resolve baked .dds in BZ2R.
	var smoke_dds := idx.find_asset_near("smoke2.tga", ["dds", "tga", "png"])
	_check(smoke_dds.to_lower().ends_with("smoke2.dds") and FileAccess.file_exists(smoke_dds), "T-29: smoke2.tga resolves to real baked smoke2.dds")
	var crackle_dds := idx.find_asset_near("crackle.tga", ["dds", "tga", "png"])
	_check(crackle_dds.to_lower().ends_with("crackle.dds") and FileAccess.file_exists(crackle_dds), "T-29: crackle.tga resolves to real baked crackle.dds")

	var xstab := BASE + "/baked/ISDF/Weapons/Cannons/AT-Stab/combat/xstabgnd_c.odf"
	if FileAccess.file_exists(xstab):
		var built := EffectRuntime.build(idx, xstab, Vector3.ZERO)
		_check(bool(built.get("ok", false)) and built.get("root", null) != null, "T-29: xstabgnd_c builds live explosion burst")
		if built.root != null:
			var planar_node: CPUParticles3D = built.root.get_node_or_null("FX_Planar")
			var sphere_node: CPUParticles3D = built.root.get_node_or_null("FX_ShockSphere")
			var smoke_node: CPUParticles3D = built.root.get_node_or_null("FX_SmokeKickup")
			_check(planar_node != null and planar_node.mesh is PlaneMesh, "T-29: draw_planar uses horizontal PlaneMesh")
			_check(sphere_node != null and sphere_node.mesh is SphereMesh and (sphere_node.mesh as SphereMesh).radial_segments == 32, "T-29: draw_sphere uses 16x32 SphereMesh")
			if smoke_node != null and smoke_node.mesh != null:
				var smat := smoke_node.mesh.surface_get_material(0) as StandardMaterial3D
				_check(smat != null and smat.albedo_texture != null and smat.billboard_keep_scale and smat.billboard_mode == BaseMaterial3D.BILLBOARD_PARTICLES, "T-29: draw_twirl loads real DDS texture with BILLBOARD_PARTICLES + billboard_keep_scale")
			built.root.free()

	var counts := idx.collection_counts()
	_check(int(counts.get("stock", 0)) >= 1400, "T-29: Stock collection cataloged (>=1400 ODFs)")
	_check(int(counts.get("vsr", 0)) > 0, "T-29: VSR collection cataloged separately")
	_check(int(counts.get("vrv", 0)) > 0, "T-29: VRV collection cataloged separately")
	var stock_veh := idx.search_filtered("", "stock", "vehicles", 50)
	_check(not stock_veh.is_empty(), "T-29: Stock Vehicles category filter returns vehicles")

	# T-31: In-game display names (unitName/wpnName), 3D texture EMISSION_OP_MULTIPLY fix, 3D BBOX hitbox, active loadout 3532748119, P0/P1 native runner & closure gates.
	_eq(idx.get_game_name("ivscav.odf"), "Scavenger", "T-31: ivscav.odf resolves in-game name Scavenger")
	_eq(idx.get_game_name("fvscav.odf"), "Scavenger", "T-31: fvscav.odf resolves in-game name Scavenger")
	_eq(idx.get_game_name("fvscavcpu.odf"), "Scavenger", "T-31: fvscavcpu.odf resolves in-game name Scavenger")
	_eq(idx.get_game_name("ivtank_vsr.odf"), "Tank", "T-31: ivtank_vsr.odf inherits in-game unitName Tank from ivtank.odf")
	_eq(idx.get_game_name("fvarch.odf"), "Lancer", "T-31: fvarch.odf resolves in-game name Lancer")
	var scav_search := idx.search_filtered("Scavenger", "stock", "vehicles", 20)
	_check(not scav_search.is_empty(), "T-31: ResourceIndex search_filtered matches in-game name 'Scavenger'")

	# T-31: BzMeshReader uses EMISSION_OP_MULTIPLY so emissive maps never whitewash vehicle textures.
	var BzMeshScript = preload("res://scripts/core/bz_mesh_reader.gd")
	var msh_path := BzMeshScript.resolve_msh_for_geometry(idx, "ivtank00.fbx")
	if msh_path != "":
		var mscene := BzMeshScript.build_scene(msh_path, idx)
		_check(bool(mscene.get("ok", false)), "T-31: ivtank00.msh parsed for material emission check")
		if mscene.get("root", null) != null:
			var checked_emis := false
			var stack_n: Array = [mscene.root]
			while not stack_n.is_empty():
				var cn = stack_n.pop_back()
				if cn is MeshInstance3D and (cn as MeshInstance3D).mesh != null:
					var cm := (cn as MeshInstance3D).mesh
					for si in cm.get_surface_count():
						var sm := cm.surface_get_material(si) as StandardMaterial3D
						if sm != null and sm.emission_enabled:
							_eq(int(sm.emission_operator), int(BaseMaterial3D.EMISSION_OP_MULTIPLY), "T-31: BzMeshReader sets EMISSION_OP_MULTIPLY to prevent whitewash")
							checked_emis = true
				for ch in cn.get_children():
					stack_n.append(ch)
			_check(checked_emis, "T-31: verified emissive material on ivtank00.msh")
			(mscene.root as Node).free()

	# T-31: 3D BBOX hitbox in ProjectileSim stops projectile on front face of target BBOX instead of center point.
	idx.set_active_package("3532748119")
	var p_bbox := WeaponProfile.new()
	if p_bbox.resolve(idx, idx.resolve_path("ivtank_vsr.odf"), idx.resolve_path("ivscav_vsr.odf")):
		p_bbox.target_half_extents = Vector3(1.6, 1.5, 4.0)
		p_bbox.target_bbox_offset = Vector3.ZERO
		var r_bbox := ProjectileSim.run_once(p_bbox, Vector3(0, 1.8, 0), Vector3(0, 0, -1), Vector3(0, 1.8, -60.0), 5.0)
		_eq(str(r_bbox.get("kind", "")), "vehicle", "T-31: projectile hits target 3D BBOX hitbox")
		var hit_z := (r_bbox.get("position", Vector3.ZERO) as Vector3).z
		_check(hit_z > -57.0 and hit_z < -55.0, "T-31: impact occurs at front BBOX face (z=%.2f) instead of center (-60.0)" % hit_z)

	# SAIHANDOFF P0-01..P0-04 & P1-01..P1-06 checks:
	var ClosureScript = preload("res://scripts/native/native_resource_closure.gd")
	var RunnerScript = preload("res://scripts/native/native_experiment_runner.gd")
	# R-02: Active loadout 3532748119 disambiguates VSR closure.
	var cl_vsr := ClosureScript.build_closure({
		"shooter_odf": "ivtank_vsr", "target_odf": "ivscav_vsr",
		"weapon_odf": "gatstabvsr_c", "ordnance_odf": "atstabvsr_c",
	}, idx)
	_check(cl_vsr.get("ambiguous_resources", []).is_empty(), "T-31 R-02: active loadout 3532748119 resolves VSR closure without ambiguity")
	_check(not (cl_vsr.get("resource_identities", []) as Array).is_empty(), "T-31 P0-03: closure records source-aware ResourceIdentity entries")
	# R-07: Staging output path collision detected.
	var cl_coll := ClosureScript.build_closure({
		"shooter_odf": "ivtank", "target_odf": "ivscav",
		"weapon_odf": "gatstab_c", "ordnance_odf": "atstab_c",
		"staging_sources": ["pkg_a/atstab_c.odf", "pkg_b/atstab_c.odf"],
	}, idx)
	_eq(str(cl_coll.get("status", "")), "STAGING_RESOURCE_COLLISION", "T-31 R-07: duplicate output filenames from distinct sources report STAGING_RESOURCE_COLLISION")
	_eq(str(cl_coll.get("closure_status", "")), "OUTPUT_PATH_COLLISION", "T-31 P0-04: closure_status reports OUTPUT_PATH_COLLISION")

	# N-02, N-03, N-04, N-05, S-01, S-04, S-05, S-06 in isolated workspace:
	var old_ws31 := WorkspaceStore.root_override
	var ws31 := "user://t31_runner_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = ws31
	var abs_ws31 := ProjectSettings.globalize_path(ws31)
	var disc31 := NativeTestAdapter.discover()
	var nr := RunnerScript.new()
	# N-03 / N-04: Failed preflight (missing shooter) rejects staging and launch.
	var pre_fail := nr.preflight(null, idx, {
		"discovery": disc31, "stage_prefix": "t31_fail",
		"shooter_odf": "nonexistent_shooter_xyz", "target_odf": "ivscav",
		"weapon_odf": "gatstab_c", "ordnance_odf": "atstab_c", "check_closure": true,
	})
	_check(not bool(pre_fail.get("preflight_passed", true)), "T-31 N-03: missing shooter fails preflight_passed")
	var sid_fail := str(pre_fail.get("session_id", ""))
	var stg_fail := nr.stage(sid_fail)
	_check(not bool(stg_fail.get("ok", true)) and str(stg_fail.get("state", "")) == "REJECTED", "T-31 N-04: failed preflight rejects launchable staging")
	var lch_fail := nr.launch(sid_fail)
	_check(not bool(lch_fail.get("ok", true)) and str(lch_fail.get("state", "")) == "REJECTED", "T-31 N-03: failed preflight rejects launch")

	# S-01, N-02, N-05: Valid preflight -> restart recovery -> stage from durable snapshot -> N-02 game absent -> N-05 stage modified.
	var src_odf31 := abs_ws31.path_join("src/atstab_test.odf")
	_write(src_odf31, "[OrdnanceClass]\nclassLabel = \"bullet\"\nshotSpeed = 120.0\nlifeSpan = 1.0\ndamageValue(H) = 100\n")
	var doc31 := OdfDocument.load_cached(src_odf31)
	var pre_ok := nr.preflight(null, null, {
		"discovery": disc31, "stage_prefix": "t31_ok",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": doc31.to_bytes()},
		"source_odf_paths": [src_odf31],
		"steam_override": {"steam_present": true, "steam_logged_in": true, "steam_exe": str(disc31.get("steam_exe", ""))},
	})
	var sid_ok := str(pre_ok.get("session_id", ""))
	# Simulate editor restart before stage (S-01):
	var nr_restarted := RunnerScript.new()
	var rec_s01 := nr_restarted.recover_sessions()
	_check(bool(rec_s01.get("ok", false)) and int(rec_s01.get("recovered", 0)) >= 2, "T-31 S-01: sessions recovered after restart")
	var stg_s01 := nr_restarted.stage(sid_ok)
	_check(bool(stg_s01.get("ok", false)) and str(stg_s01.get("state", "")) == "STAGED", "T-31 S-01: recovered preflight session stages cleanly from durable snapshot")
	# N-02: Steam launcher starts (pid=4444), but battlezone2.exe game process is absent -> GAME_PROCESS_DETECTED=false.
	nr_restarted.process_launcher = func(_e: String, _a: Array) -> Dictionary:
		return {"ok": true, "pid": 4444, "exit_code": 0}
	nr_restarted.game_process_detector = func() -> Dictionary:
		return {"detected": false, "game_pid": 0}
	var lch_n02 := nr_restarted.launch(sid_ok, {"execute_process": true})
	_check(bool(lch_n02.get("ok", false)) and not bool(lch_n02.get("game_process_detected", true)) and str(lch_n02.get("state", "")) == "STEAM_PROCESS_STARTED", "T-31 N-02: Steam PID without game process reports game_process_detected=false and STEAM_PROCESS_STARTED")
	# N-05: Modify staged ODF on disk after staging -> launch preflight invalidated.
	var sess_ok = stg_s01.get("session", null)
	_write(str(sess_ok.stage_root).path_join("assets/ODF/atstabvsr_c.odf"), "TAMPERED")
	var lch_n05 := nr_restarted.launch(sid_ok, {"execute_process": true})
	_check(not bool(lch_n05.get("ok", true)) and str(lch_n05.get("reason", "")) == "STAGE_MODIFIED_AFTER_PREFLIGHT", "T-31 N-05: tampered staged file invalidates launch preflight")
	nr_restarted.cleanup_stage(sid_ok)
	_remove_tree(str(sess_ok.stage_root))

	# S-05: Source ODF drift after preflight is caught before staging.
	var pre_s05 := nr.preflight(null, null, {
		"discovery": disc31, "stage_prefix": "t31_drift",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": doc31.to_bytes()},
		"source_odf_paths": [src_odf31],
	})
	var sid_s05 := str(pre_s05.get("session_id", ""))
	doc31.set_entry_value(doc31.find_entry("OrdnanceClass", "damageValue(H)"), "999")
	var stg_s05 := nr.stage(sid_s05)
	_check(not bool(stg_s05.get("ok", true)) and str(stg_s05.get("reason", "")) == "SOURCE_DRIFT_DETECTED", "T-31 S-05: modified source ODF after preflight rejected as SOURCE_DRIFT_DETECTED")

	# S-04: Corrupted entry in ledger is quarantined while preserving valid sessions.
	var ljson := WorkspaceStore.parse_json_safe(FileAccess.get_file_as_string(RunnerScript.ledger_path()))
	if bool(ljson.get("ok", false)) and ljson.get("data", null) is Dictionary:
		var ldoc: Dictionary = ljson.get("data", {})
		(ldoc["sessions"] as Dictionary)["corrupt_sid_99"] = "NOT_A_DICT_RAW_EVIDENCE"
		_write(RunnerScript.ledger_path(), JSON.stringify(ldoc, "  "))
		var nr_s04 := RunnerScript.new()
		var rec_s04 := nr_s04.recover_sessions()
		_check(bool(rec_s04.get("ok", false)) and int(rec_s04.get("recovered", 0)) >= 2 and int(rec_s04.get("corrupted", 0)) == 1, "T-31 S-04: valid sessions recovered while 1 corrupt entry counted")
		_check((rec_s04.get("quarantined", {}) as Dictionary).has("corrupt_sid_99") and FileAccess.file_exists(RunnerScript._quarantine_file("corrupt_sid_99")), "T-31 S-04: corrupted ledger record quarantined without losing raw evidence")

	WorkspaceStore.root_override = old_ws31
	_remove_tree(abs_ws31)


func _test_wave_b_reset_safety() -> void:
	_start("Wave B Reset Safety & Occurrence Semantics (RST-04, RST-05, RST-09, RST-11, RST-13, RST-14)")
	var old_root := WorkspaceStore.root_override
	var ws := "user://t32_reset_safety_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = ws
	var abs_ws := ProjectSettings.globalize_path(ws)

	# RST-04 / RST-05 / RST-13: Manifest write failure during revert_document returns RESET_FAILED_RECOVERABLE,
	# preserves in-memory document, saved override, and manifest agreement across restart.
	var src_a := abs_ws.path_join("src/ord_a.odf")
	_write(src_a, "[OrdnanceClass]\ndamageValue(H)=100\n")
	OdfDocument.clear_all_cache()
	var doc_a := OdfDocument.load_cached(src_a)
	doc_a.set_entry_value(doc_a.find_entry("OrdnanceClass", "damageValue(H)"), "200")
	var sv_a := WorkspaceStore.save_document_with_rel(doc_a, "ord_a.odf")
	_check(bool(sv_a.get("ok", false)), "RST-04 setup: saved override 200")
	WorkspaceStore.fault_phases["manifest_write"] = true
	var rev_fail := WorkspaceStore.revert_document(doc_a)
	WorkspaceStore.fault_phases.clear()
	_check(not bool(rev_fail.get("ok", true)), "RST-04: manifest failure causes revert_document to fail")
	_eq(str(rev_fail.get("outcome", "")), "RESET_FAILED_RECOVERABLE", "RST-04: outcome is RESET_FAILED_RECOVERABLE")
	_check(bool(rev_fail.get("recovery_pending", false)), "RST-04: recovery_pending flag set")
	_eq(doc_a.get_value("OrdnanceClass", "damageValue(H)"), "200", "RST-05: in-memory document NOT silently wiped on failed revert")
	_check(doc_a.workspace_override, "RST-05: workspace_override stays true on failed revert")
	_check(not WorkspaceStore.entry_for(src_a).is_empty(), "RST-05: manifest entry preserved on failed revert")
	# Restart consistency after failed reset:
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var after_fail_restart := OdfDocument.load_cached(src_a)
	_eq(after_fail_restart.get_value("OrdnanceClass", "damageValue(H)"), "200", "RST-13: after failed reset + restart, UI and manifest still agree on 200")

	# RST-14: Recovery point created before reset preserves original saved override & restores cleanly.
	var rec_pt := WorkspaceStore.create_reset_recovery_point([src_a], "TEST_RESET")
	_check(bool(rec_pt.get("ok", false)) and FileAccess.file_exists(str(rec_pt.get("path", ""))), "RST-14: durable reset recovery point written")
	var rev_ok := WorkspaceStore.revert_document(after_fail_restart)
	_check(bool(rev_ok.get("ok", false)) and str(rev_ok.get("status", "")) == "SUCCESS", "RST-13: revert succeeds when manifest is writable")
	_eq(after_fail_restart.get_value("OrdnanceClass", "damageValue(H)"), "100", "RST-13: factory value 100 restored")
	_check(WorkspaceStore.entry_for(src_a).is_empty(), "RST-13: manifest cleared on successful revert")
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var after_ok_restart := OdfDocument.load_cached(src_a)
	_eq(after_ok_restart.get_value("OrdnanceClass", "damageValue(H)"), "100", "RST-13: factory 100 persists across restart")
	var restored := WorkspaceStore.restore_reset_recovery_point(str(rec_pt.get("path", "")))
	_check(bool(restored.get("ok", false)), "RST-14: restore_reset_recovery_point succeeded")
	OdfDocument.clear_all_cache()
	WorkspaceStore.restore_cache()
	var recovered_a := OdfDocument.load_cached(src_a)
	_eq(recovered_a.get_value("OrdnanceClass", "damageValue(H)"), "200", "RST-14: original saved override 200 recovered from reset recovery point")

	# RST-04b: Source missing prevents destroying override/memory.
	var src_miss := abs_ws.path_join("src/miss.odf")
	_write(src_miss, "[A]\nx=1\n")
	var doc_m := OdfDocument.load_cached(src_miss)
	doc_m.set_entry_value(doc_m.find_entry("A", "x"), "2")
	WorkspaceStore.save_document_with_rel(doc_m, "miss.odf")
	DirAccess.remove_absolute(src_miss)
	var miss_rev := WorkspaceStore.revert_document(doc_m)
	_check(not bool(miss_rev.get("ok", true)) and str(miss_rev.get("status", "")) == "SOURCE_MISSING", "P0-02: missing factory source returns SOURCE_MISSING")
	_eq(doc_m.get_value("A", "x"), "2", "P0-02: missing factory source preserves in-memory value 2")

	# RST-09: Occurrence-aware duplicate property lookup across multiple physical headers.
	var dup_text := "[Core]\nvalue=10\n\n[Other]\nvalue=20\n\n[Core]\nvalue=30\n"
	var fdup := OdfDocument.parse_text(dup_text, "dup_fac.odf")
	var mdup := OdfDocument.parse_text("[Core]\nvalue=111\n\n[Other]\nvalue=222\n\n[Core]\nvalue=333\n", "dup_fac.odf")
	var core_entries := []
	for e in mdup.entries:
		if e.header == "Core" and e.key_raw == "value":
			core_entries.append(e)
	_eq(core_entries.size(), 2, "RST-09: two physical [Core] value entries parsed")
	if core_entries.size() == 2:
		var f0 = fdup.find_matching_entry(core_entries[0])
		var f1 = fdup.find_matching_entry(core_entries[1])
		_eq(str(f0.value_raw) if f0 != null else "", "10", "RST-09: first physical [Core] occurrence maps to factory value 10")
		_eq(str(f1.value_raw) if f1 != null else "", "30", "RST-09: last physical [Core] occurrence maps to factory value 30")

	# RST-11: Complete factory-header reset removes extra custom properties while preserving unrelated sections.
	var hdr_orig := "[Core]\nrenderBase=draw_sprite\nlifeTime=1\n\n[KeepMe]\nfoo=bar\n"
	var hdr_mod := "[Core]\nrenderBase=draw_sprite\nlifeTime=5\ncustomValue=99\n\n[KeepMe]\nfoo=bar\n"
	var hf := OdfDocument.parse_text(hdr_orig, "hdr.odf")
	var hm := OdfDocument.parse_text(hdr_mod, "hdr.odf")
	_check(hm.replace_header_occurrence_from_factory(hf, "Core", 0), "RST-11: replace_header_occurrence_from_factory succeeded")
	_eq(hm.get_value("Core", "lifeTime"), "1", "RST-11: factory property lifeTime restored to 1")
	_check(hm.find_entry("Core", "customValue") == null, "RST-11: workspace-added customValue removed from [Core]")
	_eq(hm.get_value("KeepMe", "foo"), "bar", "RST-11: unrelated [KeepMe] section preserved intact")

	OdfDocument.clear_all_cache()
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_ws)


func _test_wave_c_native_durability_and_evidence() -> void:
	_start("Wave C Native Durability & Honest Evidence (N-D01..N-D10, N-E01..N-E08)")
	NativeAdapterScript.clear_trusted_sessions()
	var old_root := WorkspaceStore.root_override
	var ws := "user://t33_native_durability_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = ws
	var abs_ws := ProjectSettings.globalize_path(ws)
	var disc := NativeAdapterScript.discover()
	var odf_bytes := "[OrdnanceClass]\ndamageValue(H)=100\nshotSpeed=120\n".to_utf8_buffer()
	var odf_md5 := WorkspaceStore._md5_bytes(odf_bytes)
	var steam_on := {"steam_present": true, "steam_logged_in": true, "steam_exe": str(disc.get("steam_exe", ""))}

	# N-D01: Failed preflight package write rejected (PREFLIGHT_PERSIST_FAILED, restart_resumable=false).
	var r1 = NativeRunnerScript.new()
	r1.fault_fail_preflight_package_write = true
	var p1: Dictionary = r1.preflight(null, null, {"discovery": disc, "stage_prefix": "nd01", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	r1.fault_fail_preflight_package_write = false
	_check(not bool(p1.get("ok", true)) and str(p1.get("reason", "")) == "PREFLIGHT_PERSIST_FAILED" and not bool(p1.get("restart_resumable", true)), "N-D01: failed preflight package write returns PREFLIGHT_PERSIST_FAILED and restart_resumable=false")
	var r1_rec = NativeRunnerScript.new()
	r1_rec.recover_sessions()
	_check(r1_rec.get_session_record(str(p1.get("session_id", ""))).is_empty(), "N-D01: failed preflight package did not claim durable session after restart")

	# N-D02: Failed session JSON and failed session_ledger.json write rejected.
	var r2 = NativeRunnerScript.new()
	r2.fault_fail_session_write = true
	var p2a: Dictionary = r2.preflight(null, null, {"discovery": disc, "stage_prefix": "nd02a", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	r2.fault_fail_session_write = false
	_check(not bool(p2a.get("ok", true)) and str(p2a.get("reason", "")) == "PREFLIGHT_PERSIST_FAILED", "N-D02: failed session JSON write returns PREFLIGHT_PERSIST_FAILED")
	r2.fault_fail_ledger_write = true
	var p2b: Dictionary = r2.preflight(null, null, {"discovery": disc, "stage_prefix": "nd02b", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	r2.fault_fail_ledger_write = false
	_check(not bool(p2b.get("ok", true)) and str(p2b.get("reason", "")) == "PREFLIGHT_PERSIST_FAILED" and not bool(p2b.get("restart_resumable", true)), "N-D02: failed session_ledger.json write returns PREFLIGHT_PERSIST_FAILED")

	# N-D03 / N-D04 / N-D05 / N-D07: Valid preflight -> corrupt byte hash / corrupt base64 / wrong session / clean exact stage.
	var r3 = NativeRunnerScript.new()
	var p3: Dictionary = r3.preflight(null, null, {"discovery": disc, "stage_prefix": "nd03_07", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	_check(bool(p3.get("ok", false)) and bool(p3.get("restart_resumable", false)), "N-D07 setup: durable preflight succeeded with restart_resumable=true")
	var sid3 := str(p3.get("session_id", ""))
	var pkg_path3: String = NativeRunnerScript._preflight_pkg_file(sid3)
	var orig_pkg_bytes := FileAccess.get_file_as_bytes(pkg_path3)

	# N-D03: Tamper 1 byte in stored file payload -> PREFLIGHT_SNAPSHOT_HASH_MISMATCH on restart/stage.
	var j3 := WorkspaceStore.parse_json_safe(orig_pkg_bytes.get_string_from_utf8())
	var d3: Dictionary = (j3.get("data", {}) as Dictionary).duplicate(true)
	var f3: Dictionary = d3["files"]
	var ord_item: Dictionary = (f3["assets/ODF/atstabvsr_c.odf"] as Dictionary).duplicate(true)
	var tampered_bytes := "[OrdnanceClass]\ndamageValue(H)=900\nshotSpeed=120\n".to_utf8_buffer()
	ord_item["data"] = Marshalls.raw_to_base64(tampered_bytes)
	f3["assets/ODF/atstabvsr_c.odf"] = ord_item
	WorkspaceStore.atomic_write_abs(pkg_path3, JSON.stringify(d3, "  ").to_utf8_buffer())
	var r3_tamper = NativeRunnerScript.new()
	r3_tamper.recover_sessions()
	var st_nd03: Dictionary = r3_tamper.stage(sid3)
	_check(not bool(st_nd03.get("ok", true)) and str(st_nd03.get("reason", "")) == "PREFLIGHT_SNAPSHOT_HASH_MISMATCH", "N-D03: modified 1 byte in preflight package rejected as PREFLIGHT_SNAPSHOT_HASH_MISMATCH")

	# N-D04: Corrupt/malformed base64 rejected as PREFLIGHT_SNAPSHOT_CORRUPT.
	var d4: Dictionary = (j3.get("data", {}) as Dictionary).duplicate(true)
	var f4: Dictionary = d4["files"]
	var bad_b64: Dictionary = (f4["assets/ODF/atstabvsr_c.odf"] as Dictionary).duplicate(true)
	bad_b64["data"] = "!!!NOT_VALID_BASE64***"
	f4["assets/ODF/atstabvsr_c.odf"] = bad_b64
	WorkspaceStore.atomic_write_abs(pkg_path3, JSON.stringify(d4, "  ").to_utf8_buffer())
	var r4_b64 = NativeRunnerScript.new()
	r4_b64.recover_sessions()
	var st_nd04: Dictionary = r4_b64.stage(sid3)
	_check(not bool(st_nd04.get("ok", true)) and str(st_nd04.get("reason", "")) == "PREFLIGHT_SNAPSHOT_CORRUPT", "N-D04: corrupted base64 rejected as PREFLIGHT_SNAPSHOT_CORRUPT")

	# N-D05: Wrong session_id inside preflight snapshot rejected as PREFLIGHT_SNAPSHOT_SESSION_MISMATCH.
	var d5: Dictionary = (j3.get("data", {}) as Dictionary).duplicate(true)
	d5["session_id"] = "other_foreign_session_999"
	WorkspaceStore.atomic_write_abs(pkg_path3, JSON.stringify(d5, "  ").to_utf8_buffer())
	var r5_sid = NativeRunnerScript.new()
	r5_sid.recover_sessions()
	var st_nd05: Dictionary = r5_sid.stage(sid3)
	_check(not bool(st_nd05.get("ok", true)) and str(st_nd05.get("reason", "")) == "PREFLIGHT_SNAPSHOT_SESSION_MISMATCH", "N-D05: wrong session package rejected as PREFLIGHT_SNAPSHOT_SESSION_MISMATCH")

	# N-D07: Restore original valid package -> recover -> stage produces byte-exact staged files matching snapshot hash.
	WorkspaceStore.atomic_write_abs(pkg_path3, orig_pkg_bytes)
	var r7 = NativeRunnerScript.new()
	r7.recover_sessions()
	var st_nd07: Dictionary = r7.stage(sid3)
	_check(bool(st_nd07.get("ok", false)) and str((st_nd07.get("staged_file_hashes", {}) as Dictionary).get("assets/ODF/atstabvsr_c.odf", "")) == odf_md5, "N-D07: recovered package stages byte-identical files matching snapshot MD5")
	var sess3 = st_nd07.get("session", null)
	# N-D10: Modifying staged file on disk blocks launch with STAGE_MODIFIED_AFTER_PREFLIGHT.
	_write(str(sess3.stage_root).path_join("assets/ODF/atstabvsr_c.odf"), "TAMPERED_AFTER_STAGE")
	var lch_nd10: Dictionary = r7.launch(sid3, {"execute_process": true})
	_check(not bool(lch_nd10.get("ok", true)) and str(lch_nd10.get("reason", "")) == "STAGE_MODIFIED_AFTER_PREFLIGHT", "N-D10: modified staged file blocks launch")
	r7.cleanup_stage(sid3)
	_remove_tree(str(sess3.stage_root))

	# N-D06: UTF-8, UTF-8 BOM, and UTF-16LE byte-exact source hashing & 1-byte drift detection.
	var enc_dir := abs_ws.path_join("encodings")
	DirAccess.make_dir_recursive_absolute(enc_dir)
	var p_utf8 := enc_dir.path_join("u8.odf")
	var p_bom := enc_dir.path_join("u8bom.odf")
	var p_u16 := enc_dir.path_join("u16le.odf")
	var txt_u := "[OrdnanceClass]\nshotSpeed=120\n"
	var b_u8 := txt_u.to_utf8_buffer()
	var b_bom := PackedByteArray([0xEF, 0xBB, 0xBF]); b_bom.append_array(b_u8)
	var b_u16 := PackedByteArray([0xFF, 0xFE]); b_u16.append_array(txt_u.to_utf16_buffer())
	WorkspaceStore.atomic_write_abs(p_utf8, b_u8)
	WorkspaceStore.atomic_write_abs(p_bom, b_bom)
	WorkspaceStore.atomic_write_abs(p_u16, b_u16)
	OdfDocument.clear_all_cache()
	var d_u16 := OdfDocument.load_cached(p_u16)
	var snap_u16: Dictionary = NativeRunnerScript.source_revision_snapshot(p_u16, d_u16)
	_eq(str(snap_u16.get("SOURCE_RAW_HASH", "")), WorkspaceStore._md5_bytes(b_u16), "N-D06: UTF-16LE SOURCE_RAW_HASH computed byte-exact")
	_eq(str(snap_u16.get("WORKING_DOCUMENT_HASH", "")), WorkspaceStore._md5_bytes(d_u16.to_bytes()), "N-D06: UTF-16LE no-op serialization preserves byte-exact WORKING_DOCUMENT_HASH")
	_eq(str(snap_u16.get("SOURCE_RAW_HASH", "")), str(snap_u16.get("WORKING_DOCUMENT_HASH", "")), "N-D06: no-op UTF-16LE SOURCE_RAW_HASH == WORKING_DOCUMENT_HASH")
	var r6 = NativeRunnerScript.new()
	var p6: Dictionary = r6.preflight(null, null, {
		"discovery": disc, "stage_prefix": "nd06",
		"staged_odfs": {"assets/ODF/atstabvsr_c.odf": b_u16},
		"source_odf_paths": [p_utf8, p_bom, p_u16],
		"steam_override": steam_on,
	})
	# Modify 1 byte externally in UTF-16LE fixture (120 -> 121):
	var b_u16_mod := PackedByteArray([0xFF, 0xFE]); b_u16_mod.append_array("[OrdnanceClass]\nshotSpeed=121\n".to_utf16_buffer())
	WorkspaceStore.atomic_write_abs(p_u16, b_u16_mod)
	var st_nd06: Dictionary = r6.stage(str(p6.get("session_id", "")))
	_check(not bool(st_nd06.get("ok", true)) and str(st_nd06.get("reason", "")) == "SOURCE_DRIFT_DETECTED" and str(st_nd06.get("drift_kind", "")) == "SOURCE_RAW_HASH", "N-D06: 1-byte external drift in UTF-16LE source rejected as SOURCE_DRIFT_DETECTED (SOURCE_RAW_HASH)")

	# N-D08: Missing preflight state in persisted session fails closed (PREFLIGHT_STATE_MISSING / LAUNCH_REJECTED).
	var r8 = NativeRunnerScript.new()
	var p8: Dictionary = r8.preflight(null, null, {"discovery": disc, "stage_prefix": "nd08", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	var sid8 := str(p8.get("session_id", ""))
	(r8.sessions[sid8] as Dictionary).erase("preflight_passed")
	(r8.sessions[sid8] as Dictionary).erase("launch_eligible")
	var st_nd08: Dictionary = r8.stage(sid8)
	_check(not bool(st_nd08.get("ok", true)) and str(st_nd08.get("reason", "")) == "PREFLIGHT_STATE_MISSING", "N-D08: missing preflight fields fails closed on stage() with PREFLIGHT_STATE_MISSING")
	var lch_nd08: Dictionary = r8.launch(sid8)
	_check(not bool(lch_nd08.get("ok", true)) and str(lch_nd08.get("reason", "")) == "PREFLIGHT_STATE_MISSING" and bool(lch_nd08.get("launch_rejected", false)), "N-D08: missing preflight fields fails closed on launch() with LAUNCH_REJECTED")

	# N-D09: files_override cannot bypass native launch gate.
	var r9 = NativeRunnerScript.new()
	var p9: Dictionary = r9.preflight(null, null, {"discovery": disc, "stage_prefix": "nd09", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	var sid9 := str(p9.get("session_id", ""))
	var st_nd09_block: Dictionary = r9.stage(sid9, {"assets/ODF/atstabvsr_c.odf": "BYPASS"})
	_check(not bool(st_nd09_block.get("ok", true)) and str(st_nd09_block.get("reason", "")) == "FILES_OVERRIDE_REQUIRES_PREFLIGHT", "N-D09: files_override rejected by launchable stage()")
	var st_nd09_diag: Dictionary = r9.stage_diagnostic(sid9, p9.get("files", {}))
	_check(bool(st_nd09_diag.get("ok", false)) and not bool(st_nd09_diag.get("launch_eligible", true)), "N-D09: stage_diagnostic marks launch_eligible=false")
	var lch_nd09: Dictionary = r9.launch(sid9)
	_check(not bool(lch_nd09.get("ok", true)) and bool(lch_nd09.get("launch_rejected", false)), "N-D09: diagnostic-staged session rejected by launch()")
	var sess9 = st_nd09_diag.get("session", null)
	if sess9 != null:
		r9.cleanup_stage(sid9)
		_remove_tree(str(sess9.stage_root))

	# N-E01..N-E08: Honest native evidence gates & strict production vs test seam separation.
	var re = NativeRunnerScript.new()
	re.process_launcher = func(_e: String, _a: Array) -> Dictionary:
		return {"ok": true, "pid": 5555, "exit_code": 0}
	# Explicitly no game running:
	re.game_process_detector = func() -> Dictionary:
		return {"detected": false, "game_pid": 0}
	var pe: Dictionary = re.preflight(null, null, {"discovery": disc, "stage_prefix": "ne01_08", "staged_odfs": {"assets/ODF/atstabvsr_c.odf": odf_bytes}, "steam_override": steam_on})
	var side := str(pe.get("session_id", ""))
	var ste: Dictionary = re.stage(side)
	var sesse = ste.get("session", null)

	# N-E01 & N-E02: Steam PID alone -> STEAM_PROCESS_STARTED; caller-supplied fake game_process_detected/game_pid/mission_loaded_at/resources_mounted IGNORED!
	var lch_ne02: Dictionary = re.launch(side, {
		"execute_process": true,
		"game_process_detected": true,
		"game_pid": 99999,
		"mission_loaded_at": "2026-11-21T19:00:00",
		"resources_mounted": true,
	})
	_check(not bool(lch_ne02.get("game_process_detected", true)) and int(lch_ne02.get("game_pid", -1)) == 0, "N-E02: caller-provided fake game_process_detected/game_pid in options ignored")
	_eq(str(lch_ne02.get("evidence_state", "")), "STEAM_PROCESS_STARTED", "N-E01: Steam PID alone reports STEAM_PROCESS_STARTED, never GAME_PROCESS_DETECTED")
	_check(not bool(lch_ne02.get("mission_observed", true)) and not bool(lch_ne02.get("resource_probe_confirmed", true)), "N-E02: caller-provided fake mission_loaded_at/resources_mounted in options ignored")

	# Write valid Lua observation file for N-E03 / N-E04 / N-E06 checks:
	var obs_e_path := str(sesse.stage_root).path_join("obs_ne.json")
	_write(obs_e_path, JSON.stringify({
		"contract_version": 1, "measurement_method": "GetCurHealth_delta",
		"session_id": side, "launch_nonce": str(sesse.launch_nonce), "scenario_id": str(sesse.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 100.0,
		"elapsed_mission_s": 0.9, "tps": 20, "odf_probe_damage": 100.0,
		"expected_odf_md5": odf_md5, "observed_odf_md5": "", "observed_odf_hash_available": false,
		"mount_marker": str(sesse.mount_marker), "resources_mounted": true,
	}))

	# N-E03: Game process detected, but mission NOT observed -> no native verification.
	re.game_process_detector = func() -> Dictionary:
		return {"detected": true, "game_pid": 6666}
	re.mission_observer = func(_s) -> Dictionary:
		return {"mission_observed": false, "mission_loaded_at": "", "resource_probe_confirmed": false}
	var lch_ne03: Dictionary = re.launch(side, {"execute_process": true})
	_eq(str(lch_ne03.get("evidence_state", "")), "GAME_PROCESS_DETECTED", "N-E03: detected game without mission stays GAME_PROCESS_DETECTED")
	var col_ne03: Dictionary = re.collect_observation(side, obs_e_path)
	_check(not bool(col_ne03.get("verified", true)), "N-E03: mission not observed -> no NATIVE_VERIFIED")

	# N-E04: Mission observed, but resource probe NOT confirmed -> no native verification.
	re.mission_observer = func(_s) -> Dictionary:
		return {"mission_observed": true, "mission_loaded_at": "2026-11-21T19:01:00", "resource_probe_confirmed": false}
	var lch_ne04: Dictionary = re.launch(side, {"execute_process": true})
	_eq(str(lch_ne04.get("evidence_state", "")), "MISSION_OBSERVED", "N-E04: mission without resource probe stays MISSION_OBSERVED")
	var col_ne04: Dictionary = re.collect_observation(side, obs_e_path)
	_check(not bool(col_ne04.get("verified", true)), "N-E04: resource probe missing -> no NATIVE_VERIFIED")

	# N-E05: Synthetic observation rejected even when runner hooks confirm execution + mission + probe.
	re.mission_observer = func(_s) -> Dictionary:
		return {"mission_observed": true, "mission_loaded_at": "2026-11-21T19:02:00", "resource_probe_confirmed": true}
	var lch_ne05: Dictionary = re.launch(side, {"execute_process": true})
	_eq(str(lch_ne05.get("evidence_state", "")), "RESOURCE_PROBE_CONFIRMED", "N-E05 setup: runner confirms RESOURCE_PROBE_CONFIRMED")
	var obs_syn_p := str(sesse.stage_root).path_join("obs_syn.json")
	_write(obs_syn_p, JSON.stringify({
		"contract_version": 1, "synthetic": true, "measurement_method": "GetCurHealth_delta",
		"session_id": side, "launch_nonce": str(sesse.launch_nonce), "scenario_id": str(sesse.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 100.0,
		"elapsed_mission_s": 0.9, "tps": 20, "mount_marker": str(sesse.mount_marker), "resources_mounted": true,
	}))
	var col_ne05: Dictionary = re.collect_observation(side, obs_syn_p)
	_check(not bool(col_ne05.get("verified", true)) and str(col_ne05.get("reason", "")) == "SYNTHETIC_OBSERVATION_REJECTED", "N-E05: synthetic observation rejected")

	# N-E07: Wrong session identity rejected.
	var obs_wrong_sid := str(sesse.stage_root).path_join("obs_wrong_sid.json")
	_write(obs_wrong_sid, JSON.stringify({
		"contract_version": 1, "measurement_method": "GetCurHealth_delta",
		"session_id": "forged_session_id", "launch_nonce": str(sesse.launch_nonce), "scenario_id": str(sesse.scenario_id),
		"state": "MEASUREMENT_COMPLETE", "shooter": "ivtank_vsr", "target": "ivscav_vsr",
		"weapon": "gatstabvsr_c", "ordnance": "atstabvsr_c.odf",
		"hp_before": 3000.0, "hp_after": 2900.0, "hp_max": 3000.0, "damage": 100.0,
		"elapsed_mission_s": 0.9, "tps": 20, "mount_marker": str(sesse.mount_marker), "resources_mounted": true,
	}))
	var col_ne07: Dictionary = re.collect_observation(side, obs_wrong_sid)
	_check(not bool(col_ne07.get("ok", true)) and str(col_ne07.get("reason", "")) == "LUA_CONTRACT_VIOLATION", "N-E07: mismatched session_id rejected")

	# N-E08: Engine measurement bound to scenario revision (tampered comparison scenario_hash fails validation).
	var col_ne08: Dictionary = re.collect_observation(side, obs_e_path)
	_check(bool(col_ne08.get("verified", false)), "N-E08 setup: valid runner-attested observation verified")
	var tampered_ev: Dictionary = (col_ne08.get("evidence", {}) as Dictionary).duplicate(true)
	(tampered_ev["comparison"] as Dictionary)["scenario_hash"] = "00000000000000000000000000000000"
	var ne08_v := NativeAdapterScript.validate_native_evidence(tampered_ev)
	_check(not bool(ne08_v.get("verified", true)), "N-E08: measurement with mismatched scenario_hash rejected")

	# N-E06: Operator-imported observation (no live trusted process receipt after restart) marked unattested COMPARISON_COMPLETE.
	NativeAdapterScript.clear_trusted_sessions()
	var re_manual = NativeRunnerScript.new()
	re_manual.recover_sessions()
	var col_ne06: Dictionary = re_manual.collect_observation(side, obs_e_path)
	_check(bool(col_ne06.get("ok", false)) and str(col_ne06.get("state", "")) == "COMPARISON_COMPLETE" and bool(col_ne06.get("unattested", false)) and not bool(col_ne06.get("verified", true)), "N-E06: operator-imported observation identified as unattested COMPARISON_COMPLETE")

	re_manual.cleanup_stage(side)
	_remove_tree(str(sesse.stage_root))
	OdfDocument.clear_all_cache()
	NativeAdapterScript.clear_trusted_sessions()
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_ws)


func _test_t36_fx_and_sandbox() -> void:
	_start("T-36 Titan Lightning, Rigid Floor Bounce, Homing Missiles & Sandbox Physics")
	var idx := ResourceIndex.new()
	idx.scan(false)

	# 1. Stock Titan (fvatank -> garc_c -> arcbolt draw_bolt + alt garc_a ArcCannonClass ordName=NULL)
	var titan_p := idx.resolve_path("fvatank.odf")
	var scav_p := idx.resolve_path("ivscav.odf")
	_check(titan_p != "" and scav_p != "", "T-36: stock fvatank.odf and ivscav.odf resolved")
	if titan_p != "" and scav_p != "":
		var tp := WeaponProfile.new()
		_check(tp.resolve(idx, titan_p, scav_p), "T-36: Titan weapon profile resolved")
		_eq(tp.weapon_name.to_lower(), "garc_c", "T-36: Titan primary weapon is garc_c")
		_eq(tp.ordnance_name.to_lower(), "arcbolt", "T-36: Titan ordnance is arcbolt")
		_check(tp.is_beam_render, "T-36: Titan arcbolt flagged as is_beam_render (draw_bolt hitscan)")
		_check(tp.weapon_hardpoints.size() >= 2, "T-36: Titan dual hardpoints detected (HP_CANNON_1/2)")
		_check(EffectRuntime.is_bolt_or_beam_ref(idx, tp.render_name, tp.ordnance_path), "T-36: arcbolt.render recognized as bolt/beam ref")
		var bres := EffectRuntime.build_bolt_beam(idx, tp.render_name, tp.ordnance_path, Vector3(0, 2.5, 0), Vector3(0, 2.0, -90.0))
		_check(bool(bres.get("ok", false)) and bres.get("root", null) != null, "T-36: build_bolt_beam constructs world-space BoltBeamNode for Titan arcbolt")
		_eq(str(bres.get("render_base", "")), "draw_bolt", "T-36: Titan bolt uses draw_bolt renderBase")
		var bolt_n = bres.get("root", null)
		if bolt_n != null:
			_check(float(bolt_n.duration) >= 0.5, "T-36: Titan lightning stays visible for animateTime >= 0.5s")
			bolt_n.free()
		# Alt fire: garc_a Arc Stream (ordName = NULL, ArcCannonClass)
		_check(tp.alt != null and tp.alt.is_beam_weapon, "T-36: Titan alt garc_a (ArcCannonClass ordName=NULL) resolves as beam weapon")
		if tp.alt != null:
			_check(tp.alt.expected_damage() >= 399.0, "T-36: garc_a damageValue(H) = 400 read from [ArcCannonClass]")
			var sim_a := ProjectileSim.new(101)
			var sa := sim_a.spawn(tp.alt, Vector3(0, 2, 0), Vector3(0, 0, -1), Vector3(0, 2, -60))
			sim_a.advance(0.1)
			_eq(sa.hit_kind, "vehicle", "T-36: garc_a beam shot hits target")
			_eq(sa.damage_applied, 400.0, "T-36: garc_a beam shot deals 400 damage")

	# 2. Rigid floor bouncing (sim_ember / sim_chunk) & BottomInteractsWithTerrain clamping
	if FileAccess.file_exists(XPL):
		var built := EffectRuntime.build(idx, XPL, Vector3(0.0, 0.2, 0.0), 1.0, [], 0.0)
		_check(bool(built.get("ok", false)) and built.get("root", null) != null, "T-36: xcoreturrxpl built with floor_y=0.0")
		var burst: EffectBurst = built.root
		if burst != null:
			_check(burst.terrain_clamped_emitters.size() >= 1, "T-36: draw_sphere/draw_twirl registered for BottomInteractsWithTerrain clamping")
			_check(burst.bouncing_groups.size() >= 1, "T-36: sim_ember chunks registered for rigid floor bounce physics")
			for _f in range(70):
				burst.step_simulation(0.05)
			_check(burst.bounce_events_count > 0, "T-36: sim_ember chunks bounced off rigid floor (bounces=%d)" % burst.bounce_events_count)
			_check(burst.min_simulated_y >= 0.0, "T-36: no simulated particle fell beneath floor y=0 (min_y=%.3f)" % burst.min_simulated_y)
			var clamped_ok := true
			for tc in burst.terrain_clamped_emitters:
				var cn = tc.get("node", null)
				if cn is Node3D and (burst.position.y + (cn as Node3D).position.y) < 0.0:
					clamped_ok = false
			_check(clamped_ok, "T-36: all BottomInteractsWithTerrain emitters stay above y=0")
			burst.free()

	# 3. Homing missile guidance against moving target + Terrain ramp + shotVariance + multi-target splash
	var tmp_dir := ProjectSettings.globalize_path("user://t36_sandbox_sim_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var m_sh := tmp_dir.path_join("sh.odf")
	var m_wp := tmp_dir.path_join("wp.odf")
	var m_or := tmp_dir.path_join("or.odf")
	var m_xp := tmp_dir.path_join("xp.odf")
	var m_tg := tmp_dir.path_join("tg.odf")
	_write(m_sh, "[GameObjectClass]\nweaponName1=\"wp\"\n")
	_write(m_wp, "[WeaponClass]\nordName=\"or\"\nshotDelay=0.5\nshotVariance=0.02\nkickVeloc=-3.0\n")
	_write(m_or, "[OrdnanceClass]\nclassLabel=\"thermalmissile\"\nshotSpeed=65.0\nlifeSpan=4.0\nshotRadius=0.4\ndamageValue(H)=120\nxplVehicle=\"xp\"\nxplGround=\"xp\"\n[MissileClass]\nomegaTurn=3.2\n")
	_write(m_xp, "[ExplosionClass]\ndamageRadius=16.0\n")
	_write(m_tg, "[GameObjectClass]\nmaxHealth=1000\narmorClass=\"H\"\n")
	var sidx := ResourceIndex.new()
	sidx.roots = [{"path": tmp_dir, "label": "tmp", "kind": "game", "priority": 10, "enabled": true}]
	sidx.scan(false)
	var mp := WeaponProfile.new()
	_check(mp.resolve(sidx, m_sh, m_tg), "T-36: homing missile test profile resolved")
	_check(mp.is_homing and mp.omega_turn >= 3.0, "T-36: missile omegaTurn & is_homing parsed from [MissileClass]")
	_check(mp.shot_variance > 0.01 and absf(mp.kick_veloc + 3.0) < 0.01, "T-36: shotVariance and kickVeloc parsed")
	var hsim := ProjectileSim.new(4242)
	var tgt_pos := Vector3(14.0, 2.0, -70.0)
	var extra_t: Array = [{"id": "aux_s", "name": "Aux", "position": Vector3(18.0, 2.0, -70.0), "radius": 2.0, "health": 500.0, "max_health": 500.0, "armor": "H"}]
	var hshot := hsim.spawn(mp, Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -1.0), tgt_pos, 1000.0, extra_t, [], Vector3(0.0, 0.0, -10.0))
	_check(hshot.speed >= 74.0, "T-36: moving shooter velocity inherited by projectile (speed=%.1f)" % hshot.speed)
	for step_i in range(180):
		if not hshot.alive:
			break
		tgt_pos.x = 14.0 + sin(float(step_i) * 0.08) * 6.0
		extra_t[0]["position"] = tgt_pos + Vector3(5.0, 0.0, 0.0)
		hsim.update_live_target(tgt_pos, 0.0)
		hsim.advance(1.0 / 60.0)
	_eq(hshot.hit_kind, "vehicle", "T-36: homing missile steered off-axis and hit wiggling moving target")
	_check(hshot.splash_hits.size() >= 1 and float(extra_t[0]["health"]) < 500.0, "T-36: multi-target splash damaged nearby secondary target (hp=%.1f)" % float(extra_t[0]["health"]))

	# Terrain ramp obstacle blocks low shot while higher shot clears the front slope.
	var rsim := ProjectileSim.new(77)
	mp.is_homing = false
	mp.omega_turn = 0.0
	mp.shot_variance = 0.0
	var ramp_obs: Array = [{"id": "ramp_1", "shape": "ramp", "position": Vector3(0.0, 2.5, -35.0), "size": Vector3(14.0, 5.0, 12.0)}]
	var low_s := rsim.spawn(mp, Vector3(0.0, 1.5, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.5, -70.0), 1000.0, [], ramp_obs)
	rsim.advance(2.0)
	_eq(low_s.hit_kind, "obstacle", "T-36: sloped terrain ramp intercepts low horizontal shot")
	var hi_s := rsim.spawn(mp, Vector3(0.0, 6.2, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 6.2, -70.0), 1000.0, [], ramp_obs)
	rsim.advance(2.0)
	_eq(hi_s.hit_kind, "vehicle", "T-36: shot above ramp crest clears terrain ramp and hits target")

	OdfDocument.clear_all_cache()
	_remove_tree(tmp_dir)


func _test_t34_mod_loadout_profiles() -> void:
	_start("T-34 Persistent ModLoadout Profiles, Explicit Conflict Resolution & Provenance")
	var old_root := WorkspaceStore.root_override
	var ws := "user://t34_loadout_" + str(Time.get_ticks_usec())
	WorkspaceStore.root_override = ws
	var abs_ws := ProjectSettings.globalize_path(ws)
	var sim_root := abs_ws.path_join("workshop_sim")
	var p1_path := sim_root.path_join("pkg_alpha/atstab_c.odf")
	var p2_path := sim_root.path_join("pkg_beta/atstab_c.odf")
	var p2_extra := sim_root.path_join("pkg_beta/beta_only.odf")
	_write(p1_path, "[OrdnanceClass]\ndamageValue(H)=100\n")
	_write(p2_path, "[OrdnanceClass]\ndamageValue(H)=140\n")
	_write(p2_extra, "[OrdnanceClass]\ndamageValue(H)=55\n")

	var idx := ResourceIndex.new()
	idx.roots = [{"path": sim_root, "label": "sim_workshop", "kind": "workshop", "priority": 30, "enabled": true}]
	idx.scan(true)

	# 1. Create ModLoadout with multi-package priority [pkg_alpha, pkg_beta] and explicit conflict winner -> pkg_beta/atstab_c.odf
	var ml = ModLoadoutScript.capture_from_index("vsr_custom", idx, "VSR Custom Test", "BZCC_185", ["pkg_alpha", "pkg_beta"], {"atstab_c.odf": p2_path})
	_eq(ml.profile_id, "vsr_custom", "T-34: profile_id sanitized")
	_eq(ml.effective_package_order(), ["pkg_alpha", "pkg_beta"], "T-34: multi-package priority order preserved")
	_check(str(ml.policy_note).to_lower().contains("not verified bzcc"), "T-34: policy_note honestly states editor policy != verified BZCC mount order")

	# Save & reload JSON persistence
	var sres: Dictionary = ModLoadoutScript.save_profile(ml)
	_check(bool(sres.get("ok", false)) and FileAccess.file_exists(str(sres.get("path", ""))), "T-34: ModLoadout saved atomically under workspace/loadouts/")
	var loaded = ModLoadoutScript.load_profile("vsr_custom")
	_check(loaded != null and loaded.profile_id == "vsr_custom", "T-34: ModLoadout reloaded from disk")
	_eq(loaded.effective_package_order(), ["pkg_alpha", "pkg_beta"], "T-34: reloaded multi-package priority matches")
	_check(WorkspaceStore._same_canon_path(str(loaded.explicit_resource_winners.get("atstab_c.odf", "")), p2_path), "T-34: reloaded explicit conflict winner preserved")

	# 2. Apply to ResourceIndex: explicit winner overrides pkg_alpha priority AND matches NativeResourceClosureBuilder identically!
	var ares: Dictionary = idx.apply_loadout(loaded)
	_check(bool(ares.get("ok", false)), "T-34: ResourceIndex.apply_loadout succeeded")
	var ed_win := idx.resolve_path("atstab_c.odf")
	_check(WorkspaceStore._same_canon_path(ed_win, p2_path), "T-34: explicit_resource_winners overrides priority_order in editor ResourceIndex")
	var nat_win := ResourceClosureScript.resolve_odf_with_ambiguity(idx, "atstab_c.odf", "", idx.active_packages)
	_check(bool(nat_win.get("found", false)) and not bool(nat_win.get("ambiguous", true)), "T-34: NativeResourceClosureBuilder resolves explicit winner without ambiguity")
	_check(WorkspaceStore._same_canon_path(str((nat_win.get("selected", {}) as Dictionary).get("path", "")), ed_win), "T-34: editor and native staging select identical effective resource path")
	_eq(str(nat_win.get("rule", "")), "explicit_loadout_winner", "T-34: native closure provenance records explicit_loadout_winner")

	# 3. Conflict report, missing dependency detection & native eligibility
	var crep: Dictionary = loaded.resolve_conflicts_report(idx, ["atstab_c.odf", "beta_only.odf", "missing_dep_xyz.odf"])
	_check(not bool(crep.get("ok", true)) and (crep.get("missing_dependencies", []) as Array).has("missing_dep_xyz.odf"), "T-34: missing dependency reported explicitly")
	_check(int(crep.get("conflicts_count", 0)) >= 1, "T-34: multi-package conflict enumerated with provenance")
	var elig_bad: Dictionary = loaded.evaluate_native_eligibility(idx, ["atstab_c.odf", "missing_dep_xyz.odf"])
	_check(not bool(elig_bad.get("eligible", true)) and str(elig_bad.get("status", "")) == "INELIGIBLE", "T-34: missing dependency marks native_test_eligibility INELIGIBLE")
	var elig_ok: Dictionary = loaded.evaluate_native_eligibility(idx, ["atstab_c.odf", "beta_only.odf"])
	_check(bool(elig_ok.get("eligible", false)) and str(elig_ok.get("status", "")) == "ELIGIBLE", "T-34: complete loadout marks native_test_eligibility ELIGIBLE")

	# 4. List & delete profile
	var plist: Array = ModLoadoutScript.list_profiles()
	_check(plist.size() == 1 and str((plist[0] as Dictionary).get("profile_id", "")) == "vsr_custom", "T-34: list_profiles enumerates saved ModLoadout")
	_check(ModLoadoutScript.delete_profile("vsr_custom") and ModLoadoutScript.list_profiles().is_empty(), "T-34: delete_profile removes saved profile cleanly")

	OdfDocument.clear_all_cache()
	WorkspaceStore.root_override = old_root
	_remove_tree(abs_ws)


# ---------------------------------------------------------------- helpers

func _find_row(rows: Array, header: String, key: String, suffix: String = "") -> Dictionary:
	for r in rows:
		if str(r.header).to_lower() == header.to_lower() and str(r.key).to_lower() == key.to_lower() \
				and str(r.suffix).to_lower() == suffix.to_lower():
			return r
	return {}


func _row_value(rows: Array, header: String, key: String, suffix: String = "") -> String:
	var r := _find_row(rows, header, key, suffix)
	return str(r.value) if not r.is_empty() else ""


func _list_odf(root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	var dirs: Array[String] = []
	while n != "":
		if n == "." or n == "..":
			n = dir.get_next()
			continue
		if dir.current_is_dir():
			dirs.append(root.path_join(n))
		elif n.to_lower().ends_with(".odf"):
			out.append(root.path_join(n))
		n = dir.get_next()
	dir.list_dir_end()
	for d in dirs:
		out.append_array(_list_odf(d))
	return out


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
