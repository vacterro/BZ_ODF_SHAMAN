class_name ParameterSweep
extends RefCounted
## Batch parameter sweep over a resolved weapon chain. Each point is a real,
## deterministic simulation built from the same document cache; the varied
## value is a transient in-memory override, so no ODF is written and the shared
## document is unchanged afterwards.

const MIN_STEPS := 2
const MAX_STEPS := 64
const SEED := 1234

const PROPERTIES := [
	{"id": "shotSpeed", "label": "shotSpeed (m/s)"},
	{"id": "lifeSpan", "label": "lifeSpan (s)"},
	{"id": "shotRadius", "label": "shotRadius (m)"},
	{"id": "damageValue(H)", "label": "damageValue(H)"},
]


static func values_between(from_value: float, to_value: float, steps: int) -> Array[float]:
	var out: Array[float] = []
	var n := clampi(steps, MIN_STEPS, MAX_STEPS)
	if n <= 1:
		out.append(from_value)
		return out
	for i in n:
		var t := float(i) / float(n - 1)
		out.append(lerpf(from_value, to_value, t))
	return out


## Runs the baseline plus one shot per value. The returned dictionary contains
## baseline, rows (value, damage, damage_delta, kind, time, target_health,
## range) and notes. The profile is left with no overrides.
static func run(profile: WeaponProfile, property: String, from_value: float, to_value: float,
		steps: int, origin: Vector3, direction: Vector3, target: Vector3,
		target_health: float = -1.0) -> Dictionary:
	var result := {
		"property": property,
		"values": [],
		"rows": [],
		"baseline": {},
		"notes": [],
	}
	if profile == null:
		result.notes.append("No scenario is loaded.")
		return result
	profile.clear_overrides()
	profile.refresh()
	result.baseline = _sample(profile, origin, direction, target, target_health)
	var baseline_damage := float(result.baseline.get("damage", 0.0))
	for v in values_between(from_value, to_value, steps):
		profile.set_override(property, String.num(v, 6))
		profile.refresh()
		var row := _sample(profile, origin, direction, target, target_health)
		row["value"] = v
		row["damage_delta"] = float(row.damage) - baseline_damage
		result.values.append(v)
		result.rows.append(row)
	profile.clear_overrides()
	profile.refresh()
	result.notes.append("In-memory overrides only; no ODF file was written.")
	return result


## Deterministic CSV export of a sweep result. Baseline has value "baseline"
## and delta 0; no timestamp is embedded so the bytes are reproducible.
static func to_csv(result: Dictionary, scenario_label: String = "") -> String:
	var property := str(result.get("property", ""))
	var lines: Array[String] = []
	lines.append("# property=" + _csv_field(property))
	lines.append("# scenario=" + _csv_field(scenario_label))
	lines.append("# overrides=in-memory only; no ODF file was written")
	lines.append("value,damage,damage_delta,flight_s,target_health,hit_kind,range_m")
	var base: Dictionary = result.get("baseline", {})
	lines.append("baseline,%s,0.000000,%s,%s,%s,%s" % [
		_num(base.get("damage", 0.0)), _num(base.get("time", 0.0)),
		_num(base.get("target_health", 0.0)), _csv_field(str(base.get("kind", ""))),
		_num(base.get("range", 0.0)),
	])
	for row in result.get("rows", []):
		lines.append("%s,%s,%s,%s,%s,%s,%s" % [
			_num(row.get("value", 0.0)), _num(row.get("damage", 0.0)),
			_num(row.get("damage_delta", 0.0)), _num(row.get("time", 0.0)),
			_num(row.get("target_health", 0.0)), _csv_field(str(row.get("kind", ""))),
			_num(row.get("range", 0.0)),
		])
	return "\n".join(lines) + "\n"


static func _num(v) -> String:
	var f := float(v)
	if is_nan(f) or is_inf(f):
		return ""
	return "%.6f" % f


static func _csv_field(text: String) -> String:
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		return "\"" + text.replace("\"", "\"\"") + "\""
	return text


static func _sample(profile: WeaponProfile, origin: Vector3, direction: Vector3,
		target: Vector3, target_health: float) -> Dictionary:
	var range_value := profile.range_estimate()
	if profile.shot_speed <= 0.0:
		return {
			"kind": "no_shot",
			"damage": 0.0,
			"time": 0.0,
			"target_health": maxf(0.0, target_health),
			"range": range_value,
		}
	var sim := ProjectileSim.new(SEED)
	var shot := sim.spawn(profile, origin, direction, target, target_health)
	var guard := 0
	while shot.alive and sim.sim_time < 10.0 and guard < 200000:
		sim.advance(1.0 / 60.0)
		guard += 1
	return {
		"kind": shot.hit_kind if not shot.alive else "timeout",
		"damage": shot.damage_applied,
		"time": shot.age,
		"target_health": shot.target_health,
		"range": range_value,
	}
