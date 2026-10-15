#!/usr/bin/env python3
"""Check every paper the agent's notes cite against the arXiv API.

Usage:  python3 -I audit/check_papers.py [--dir research|audit/original] [--abstracts DIR] [--md OUT.md]
Finds `Title (arXiv:ID)`, `[Title](https://arxiv.org/abs/ID)` and `**Title** (arXiv:ID)` patterns in research/*.md,
fetches the real titles in one batched call, fuzzy-compares, and prints/writes a table.
Network failure exits 2 (CI treats the step as non-gating).
"""
import difflib, glob, os, re, sys, urllib.request, xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ID = r"(\d{4}\.\d{4,5})"
PATTERNS = [
    re.compile(r"\[([^\]]{6,200})\]\(https?://arxiv\.org/abs/" + ID),
    re.compile(r"\*{0,2}([^\n*(]{6,200}?)\*{0,2}\s*\((?:arXiv:|arxiv:)" + ID),
]

def collect(base):
    seen = {}   # id -> set of (file, listed title)
    for path in sorted(glob.glob(os.path.join(base, "*.md"))):
        text = open(path, encoding="utf-8").read()
        for pat in PATTERNS:
            for m in pat.finditer(text):
                title, aid = m.group(1).strip(" -:*0123456789.\t"), m.group(2)
                seen.setdefault(aid, set()).add((os.path.basename(path), title))
        for aid in re.findall(r"arXiv:" + ID, text):
            seen.setdefault(aid, set())
    return seen

def fetch(ids):
    url = "https://export.arxiv.org/api/query?max_results=%d&id_list=%s" % (len(ids), ",".join(ids))
    with urllib.request.urlopen(url, timeout=60) as r:
        root = ET.fromstring(r.read())
    ns = {"a": "http://www.w3.org/2005/Atom"}
    out = {}
    for e in root.findall("a:entry", ns):
        aid = re.search(r"abs/(\d{4}\.\d{4,5})", e.find("a:id", ns).text).group(1)
        out[aid] = {"title": " ".join(e.find("a:title", ns).text.split()),
                    "abstract": " ".join(e.find("a:summary", ns).text.split())}
    return out

STOP = {"the", "a", "an", "of", "for", "and", "in", "on", "to", "with", "from", "via", "llm", "llms", "language", "models", "model", "large"}

def norm(s): return re.sub(r"[^a-z0-9 ]", "", s.lower())

def toks(s): return {w for w in norm(s).split() if w not in STOP and len(w) > 2}

def score(listed, actual):
    """max of sequence similarity and 'how many listed words appear in the real title'."""
    sim = difflib.SequenceMatcher(None, norm(listed), norm(actual)).ratio()
    lt = toks(listed)
    cont = len(lt & toks(actual)) / len(lt) if lt else 0
    return max(sim, cont)

def junk(t): return t.startswith(("From ", ")")) or len(t) < 8

def main():
    base = os.path.join(ROOT, sys.argv[sys.argv.index("--dir") + 1]) if "--dir" in sys.argv else os.path.join(ROOT, "research")
    seen = collect(base)
    ids = sorted(seen)
    try:
        real = fetch(ids)
    except Exception as e:
        print("arXiv unreachable:", e, file=sys.stderr); sys.exit(2)
    rows, counts = [], {"ok": 0, "paraphrased": 0, "wrong": 0, "no title": 0, "missing": 0}
    for aid in ids:
        r = real.get(aid)
        listed = sorted({t for _, t in seen[aid] if not junk(t)})
        if not r:
            counts["missing"] += 1; rows.append((aid, "|".join(listed)[:110], "NOT FOUND on arXiv", "missing", 0)); continue
        if not listed:
            counts["no title"] += 1; rows.append((aid, "(ID only / no usable title)", r["title"][:110], "no title", 0)); continue
        best = max(score(t, r["title"]) for t in listed)
        status = "ok" if best >= 0.75 else "paraphrased" if best >= 0.45 else "wrong"
        # an ID also listed under a title that has nothing to do with the real paper is an error
        if len(listed) > 1 and min(score(t, r["title"]) for t in listed) < 0.26:
            status = "wrong"; best = min(score(t, r["title"]) for t in listed)
        counts[status] += 1
        rows.append((aid, " / ".join(listed)[:110], r["title"][:110], status, best))
    lines = ["| arXiv ID | Title as listed in the notes | Actual title (arXiv API) | Verdict |", "|---|---|---|---|"]
    for aid, listed, actual, st, sc in rows:
        lines.append("| %s | %s | %s | %s |" % (aid, listed.replace("|", "/"), actual.replace("|", "/"),
                     {"ok": "ok", "paraphrased": "shortened/paraphrased (sim %.2f)" % sc, "wrong": "**WRONG TITLE** (sim %.2f)" % sc, "no title": "no title to check", "missing": "**NOT FOUND**"}[st]))
    table = "\n".join(lines)
    summary = "%d distinct IDs: %d ok, %d shortened/paraphrased, %d wrong title, %d no usable title, %d not found" % (
        len(ids), counts["ok"], counts["paraphrased"], counts["wrong"], counts["no title"], counts["missing"])
    print(table); print("\n" + summary)
    if "--md" in sys.argv:
        open(sys.argv[sys.argv.index("--md") + 1], "w").write(table + "\n\n" + summary + "\n")
    if "--abstracts" in sys.argv:
        d = sys.argv[sys.argv.index("--abstracts") + 1]; os.makedirs(d, exist_ok=True)
        for aid, r in real.items():
            open(os.path.join(d, aid + ".txt"), "w").write(r["title"] + "\n\n" + r["abstract"] + "\n")

if __name__ == "__main__":
    main()
