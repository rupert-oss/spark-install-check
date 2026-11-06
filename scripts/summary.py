"""Write one table for every machine in the run to the job summary."""
import json, os, pathlib, sys

EXPECTED = ["macos-26", "macos-15", "macos-26-intel", "macos-15-intel", "windows-2025", "windows-2022", "windows-11-arm"]
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "results")
rows, seen = [], set()
for m in sorted(root.glob("result-*/machine.json")):
    d = json.loads(m.read_text(encoding="utf-8-sig"))
    fails, warns = [], []
    tsv, js = m.parent / "results.tsv", m.parent / "results.json"
    if tsv.exists():
        for line in tsv.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] == "FAIL":
                fails.append(parts[0])
            elif len(parts) >= 2 and parts[1] == "WARN":
                warns.append(parts[0])
    elif js.exists():
        data = json.loads(js.read_text(encoding="utf-8-sig"))
        data = data if isinstance(data, list) else [data]
        fails = [r["check"] for r in data if r.get("result") == "FAIL"]
        warns = [r["check"] for r in data if r.get("result") == "WARN"]
    seen.add(d.get("runner"))
    rows.append((d.get("runner", "?"), f"{d.get('os', '?')} ({d.get('arch', '?')})", d.get("spark", "?"), d.get("result", "?"), ", ".join(fails) or "none", ", ".join(warns) or "none"))
for r in EXPECTED:
    if r not in seen:
        rows.append((r, "?", "?", "FAIL", "the machine produced no results", ""))
passed = sum(1 for r in rows if r[3] == "PASS")
lines = [f"## Spark install check: {passed} of {len(rows)} machines passed", "", "| Machine | OS | Spark | Result | Failed checks | Warnings |", "|---|---|---|---|---|---|"]
lines += [f"| {a} | {b} | {c} | {d} | {e} | {f} |" for a, b, c, d, e, f in rows]
out = "\n".join(lines) + "\n"
print(out)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
        f.write(out)
sys.exit(0 if passed == len(rows) else 1)
