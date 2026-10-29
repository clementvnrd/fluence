"""score.py <results dir>: corpus WER per engine and test set, plus speed.

Normalisation (same for reference and hypothesis): lowercase, NFKC, apostrophes and
hyphens and dots split words ("l'équipe" -> "l équipe", "node.js" -> "node js"),
other punctuation removed. Numbers are left as written.
"""
import glob
import os
import re
import sys
import unicodedata

B = os.environ.get("FBENCH_DIR", "/tmp/fluence-french-bench") + "/sets"


def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    s = s.replace("’", "'").replace("‘", "'")
    s = re.sub(r"['\-.]", " ", s)
    s = re.sub(r"[^\w\s]", " ", s)
    return s.split()


def edits(r, h):
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] != h[j - 1]))
        prev = cur
    return prev[-1]


refs = {}
for line in open(f"{B}/fleurs.ref", encoding="utf-8"):
    f, t = line.rstrip("\n").split("\t")
    refs["fleurs/" + f[:-4]] = t
    refs["fleurs-webcam/" + f[:-4]] = t
for line in open(f"{B}/tech.ref", encoding="utf-8"):
    i, t = line.rstrip("\n").split("\t")
    refs["tech/" + i] = t
    refs["tech-webcam/" + i] = t
for line in open(f"{B}/franglais.ref", encoding="utf-8"):
    i, t = line.rstrip("\n").split("\t")[:2]
    for n in range(1, 5):
        refs[f"franglais/{i}-{n}"] = refs[f"franglais-webcam/{i}-{n}"] = t

sets = ["fleurs", "fleurs-webcam", "tech", "tech-webcam", "franglais", "franglais-webcam"]
rows = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.tsv"))):
    name = os.path.basename(path)[:-4]
    acc = {s: [0, 0] for s in sets}
    audio = proc = 0.0
    worst = []
    long_lat = None
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 4:
            parts += [""] * (4 - len(parts))
        key, a, p, hyp = parts[0], float(parts[1]), float(parts[2]), parts[3]
        s = key.split("/")[0]
        r = norm(refs[key])
        e = edits(r, norm(hyp))
        acc[s][0] += e
        acc[s][1] += len(r)
        audio += a
        proc += p
        if key.endswith("/long") and s == "tech":
            long_lat = p
        if s.startswith("tech"):
            worst.append((e / max(1, len(r)), key, hyp))
    rows.append((name, {s: 100 * acc[s][0] / max(1, acc[s][1]) for s in sets}, audio / max(proc, 1e-9), long_lat, worst))

print(f"{'engine':16} " + " ".join(f"{s:>14}" for s in sets) + f" {'x realtime':>11} {'44 s dict.':>10}")
for name, w, rt, ll, _ in rows:
    print(f"{name:16} " + " ".join(f"{w[s]:13.1f}%" for s in sets) + f" {rt:10.0f}x {ll if ll is not None else float('nan'):9.2f}s")

if "-v" in sys.argv:
    for name, _, _, _, worst in rows:
        print(f"\n## {name}: worst tech lines")
        for wer, key, hyp in sorted(worst, reverse=True)[:5]:
            print(f"  {100 * wer:5.0f}%  {key}: {hyp}")
