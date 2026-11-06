#!/usr/bin/env python3
"""Visual regression check for refactors: renders a set of fixtures in the real app, in light and
dark, and compares them with a baseline taken earlier on this machine.

    scripts/visual-check.py baseline      # before the change
    scripts/visual-check.py               # after it; exits non-zero if a picture changed

Screenshots depend on the machine and fonts, so the baseline stays in build/ and is not committed.
Only fixtures are rendered. Needs a debug build (scripts/build-app.sh debug) and Pillow."""
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "build/app.noindex/Perlustra.app/Contents/MacOS/Perlustra"
BASELINE = ROOT / "build/visual-baseline"
FIXTURES = [
    "code/hello.py", "docs/README.md", "docs/page.html", "docs/outline.pdf", "data/config.json",
    "data/sales-utf8.csv", "office/report-styled.xlsx", "office/charts.xlsx", "images/photo.jpg",
    "archives/sample.zip", "edge/unknown.xyz",
]
APPEARANCES = ["light", "dark"]
# Antialiasing and the window's corners vary a little between runs of the same code.
MAX_CHANGED_PIXELS = 0.002


def render(out: Path) -> None:
    for appearance in APPEARANCES:
        folder = out / appearance
        folder.mkdir(parents=True, exist_ok=True)
        files = [ROOT / "fixtures" / f for f in FIXTURES if (ROOT / "fixtures" / f).exists()]
        capture(folder, appearance, files)
        # screencapture now and then hands back a window scaled down: take those again.
        for _ in range(4):
            sizes = {f: picture_size(folder / (f.name + ".png")) for f in files}
            usual = Counter(sizes.values()).most_common(1)[0][0]
            odd = [f for f, size in sizes.items() if size != usual]
            if not odd:
                break
            capture(folder, appearance, odd)


def capture(folder: Path, appearance: str, files: list[Path]) -> None:
    subprocess.run([str(BINARY), "--snapshot", str(folder), "--size", "1100x760", "--appearance", appearance,
                    "--delay", "1.5", *map(str, files)], capture_output=True, timeout=600, check=False)


def picture_size(path: Path) -> tuple[int, int]:
    if not path.exists():
        return (0, 0)
    with Image.open(path) as image:
        return image.size


def changed_fraction(a: Path, b: Path) -> float:
    with Image.open(a) as x, Image.open(b) as y:
        if x.size != y.size:
            return 1.0
        histogram = ImageChops.difference(x.convert("RGB"), y.convert("RGB")).convert("L").histogram()
        return sum(histogram[17:]) / (x.size[0] * x.size[1])


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "baseline":
        shutil.rmtree(BASELINE, ignore_errors=True)
        render(BASELINE)
        print(f"基线：{len(list(BASELINE.rglob('*.png')))} 张")
        return 0
    if not BASELINE.exists():
        print("还没有基线，先运行 scripts/visual-check.py baseline")
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        now = Path(tmp)
        render(now)
        bad = []
        pictures = sorted(BASELINE.rglob("*.png"))
        for before in pictures:
            after = now / before.relative_to(BASELINE)
            if not after.exists():
                bad.append((before.relative_to(BASELINE), "没生成"))
                continue
            fraction = changed_fraction(before, after)
            if fraction > MAX_CHANGED_PIXELS:
                bad.append((before.relative_to(BASELINE), f"{fraction:.2%} 的像素变了"))
                keep = ROOT / "build/visual-diff" / before.relative_to(BASELINE)
                keep.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(after, keep)
        for name, why in bad:
            print(f"变了 {name}：{why}")
        print(f"{len(pictures) - len(bad)} / {len(pictures)} 张一致")
        return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
