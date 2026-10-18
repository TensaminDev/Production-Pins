"""Reject runtime code and enforce Pages Free's static asset limits."""
from pathlib import Path

root = Path("web")
if not (root / "index.html").is_file():
    raise SystemExit("The web build is missing index.html")
if (root / "404.html").exists():
    raise SystemExit("A top-level 404.html would disable Pages' SPA fallback")
for path in (root / "_worker.js", root / "functions", Path("functions")):
    if path.exists():
        raise SystemExit("Only static assets are allowed; Pages Functions and Workers are disabled")

# Preserve the model's binary HTTP response rather than serving it as HTML.
with (root / "_headers").open("a") as headers:
    headers.write("\n/assets/v3/models/DeepFilterNet3_onnx.tar.gz\n  Content-Type: application/gzip\n  Cache-Control: no-cache\n")
files = [path for path in root.rglob("*") if path.is_file()]
if len(files) > 20_000:
    raise SystemExit("The web build exceeds Pages Free's 20,000-file limit")
for path in files:
    if path.stat().st_size > 25 * 1024 * 1024:
        raise SystemExit(f"Static asset exceeds Pages' 25 MiB limit: {path.relative_to(root)}")
print(f"Validated {len(files)} static files. No Functions or Worker runtime will be deployed.")
