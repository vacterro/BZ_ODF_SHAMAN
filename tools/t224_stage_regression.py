import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(r"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe")
VERIFIER = "res://tests/verify_t224_stage_safety.gd"
PROJECT_FILES = ("project.godot", "scripts/core/workspace_store.gd")
CORE_FILES = (
    "scripts/core/odf_document.gd",
    "scripts/core/odf_inheritance.gd",
    "scripts/core/resource_index.gd",
    "scripts/core/schema_registry.gd",
    "scripts/native/safe_stage_manager.gd",
)


def copy_file(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def copy_verifier(root: Path, stage: str) -> None:
    text = (ROOT / VERIFIER.removeprefix("res://")).read_text(encoding="utf-8")
    if stage == "before":
        text = text.replace('SafeStageScript._is_reserved_stage_path("assets/effects.odf")', 'true')
    target = root / VERIFIER.removeprefix("res://")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def prepare_project(root: Path, stage: str) -> None:
    before = ROOT / ".saipen/evidence/t224_regression/pre/safe_stage_manager.gd"
    for rel in PROJECT_FILES:
        copy_file(ROOT / rel, root / rel)
    for rel in CORE_FILES:
        source = before if stage == "before" and rel == "scripts/native/safe_stage_manager.gd" else ROOT / rel
        copy_file(source, root / rel)
    copy_verifier(root, stage)
    cache = ROOT / ".godot/global_script_class_cache.cfg"
    if cache.is_file():
        (root / ".godot").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(cache, root / ".godot/global_script_class_cache.cfg")


def run_stage(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(RUNTIME), "--headless", "--path", str(root), "--script", VERIFIER],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
        cwd=root,
    )


def emit_tap(result: subprocess.CompletedProcess, label: str) -> int:
    text = result.stdout.decode("utf-8", errors="replace").replace("\r", "")
    summaries = [line for line in text.splitlines() if line.startswith("T-224 Stage Safety: ")]
    print("TAP version 13", flush=True)
    if not summaries:
        print("not ok 1 - %s: verifier did not report a result" % label, flush=True)
        print(text, file=sys.stderr, flush=True)
        print("# tests 1", flush=True)
        print("# pass 0", flush=True)
        print("# fail 1", flush=True)
        print("# skipped 0", flush=True)
        print("# cancelled 0", flush=True)
        return 1
    left, right = summaries[-1][len("T-224 Stage Safety: "):].split(" checks, ")
    total = int(left)
    failures = int(right.split(" ", 1)[0])
    passed = total - failures
    print("1..%d" % total, flush=True)
    for index in range(total):
        state = "not ok" if index >= passed else "ok"
        print("%s %d - %s: T-224 stage safety check %d" % (state, index + 1, label, index + 1), flush=True)
    print("# tests %d" % total, flush=True)
    print("# pass %d" % passed, flush=True)
    print("# fail %d" % failures, flush=True)
    print("# skipped 0", flush=True)
    print("# cancelled 0", flush=True)
    return 1 if failures or result.returncode else 0


def main() -> int:
    before = ROOT / ".saipen/evidence/t224_regression/pre/safe_stage_manager.gd"
    if len(sys.argv) == 2:
        stage = sys.argv[1]
        if stage == "before":
            subject = before
        elif stage == "after":
            subject = ROOT
        else:
            raise ValueError("stage must be before or after")
        with tempfile.TemporaryDirectory(prefix="bz_shaman_t224_") as temp:
            root = Path(temp)
            prepare_project(root, stage)
            result = run_stage(root)
            return emit_tap(result, stage)
    if len(sys.argv) != 1:
        raise ValueError("usage: t224_stage_regression.py [before|after]")
    with tempfile.TemporaryDirectory(prefix="bz_shaman_t224_before_") as temp:
        before_root = Path(temp)
        prepare_project(before_root, "before")
        before_result = run_stage(before_root)
        before_status = emit_tap(before_result, "before")
    with tempfile.TemporaryDirectory(prefix="bz_shaman_t224_after_") as temp:
        after_root = Path(temp)
        prepare_project(after_root, "after")
        after_result = run_stage(after_root)
        after_status = emit_tap(after_result, "after")
    if before_status == 0:
        print("before source unexpectedly passed", file=sys.stderr)
        return 2
    return 0 if after_status == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
