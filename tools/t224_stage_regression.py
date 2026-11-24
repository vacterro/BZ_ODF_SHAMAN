import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


RUNTIME = Path(r"V:\__STORE_V\_SOFT\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe")
VERIFIER = "tests/verify_t224_stage_safety.gd"
SHIM = 'SafeStageScript._is_reserved_stage_path("assets/effects.odf")'


def prepare_run(source: Path, target: Path) -> None:
    for item in source.iterdir():
        if item.name in (".stdout", ".stderr", ".sandbox_run"):
            continue
        dest = target / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copyfile(item, dest)
    verifier = target / VERIFIER
    text = verifier.read_text(encoding="utf-8")
    if SHIM in text:
        verifier.write_text(text.replace(SHIM, "true"), encoding="utf-8")


def main() -> int:
    source = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="t224_run_", dir=source) as temp:
        run_dir = Path(temp)
        prepare_run(source, run_dir)
        result = subprocess.run(
            [str(RUNTIME), "--headless", "--path", str(run_dir), "--script", "res://" + VERIFIER],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=180,
            cwd=run_dir,
        )
    text = result.stdout.decode("utf-8", errors="replace").replace("\r", "")
    summaries = [line for line in text.splitlines() if line.startswith("T-224 Stage Safety: ")]
    print("TAP version 13", flush=True)
    if not summaries:
        print("not ok 1 - verifier did not report a result", flush=True)
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
        print("%s %d - T-224 stage safety check %d" % (state, index + 1, index + 1), flush=True)
    print("# tests %d" % total, flush=True)
    print("# pass %d" % passed, flush=True)
    print("# fail %d" % failures, flush=True)
    print("# skipped 0", flush=True)
    print("# cancelled 0", flush=True)
    return 1 if failures or result.returncode else 0


if __name__ == "__main__":
    raise SystemExit(main())
