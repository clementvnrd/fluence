"""franglais.py <results dir> [-v]: English work words in French dictations (FLU-122).

Per result file: recall of the English words listed in franglais.ref (an occurrence counts when
the hypothesis holds the word as often as the reference, after score.py's norm(), so case and
punctuation do not matter but « cleané » is not « cleaner »), on franglais and franglais-webcam,
split into Thomas (written form) and the three respelled voices; and false terms: those words in
FLEURS and tech outputs that their reference does not have. -v lists the missed words.
"""
import glob
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ns = {}
exec(open(os.path.join(HERE, "score.py"), encoding="utf-8").read().split("refs = {}")[0], ns)
norm, B = ns["norm"], ns["B"]


def count(seq, words):
    n = len(seq)
    return sum(words[i:i + n] == seq for i in range(len(words) - n + 1))


assert count(["kick", "off"], norm("le kick-off et le Kick off")) == 2

refs, terms_of = {}, {}
for line in open(f"{B}/franglais.ref", encoding="utf-8"):
    i, t, _, terms = line.rstrip("\n").split("\t")
    for n in range(1, 5):
        for s in ("franglais", "franglais-webcam"):
            refs[f"{s}/{i}-{n}"] = t
            terms_of[f"{s}/{i}-{n}"] = [norm(x) for x in terms.split(",")]
vocab = {tuple(x) for ts in terms_of.values() for x in ts}
for line in open(f"{B}/fleurs.ref", encoding="utf-8"):
    f, t = line.rstrip("\n").split("\t")
    refs["fleurs/" + f[:-4]] = refs["fleurs-webcam/" + f[:-4]] = t
for line in open(f"{B}/tech.ref", encoding="utf-8"):
    i, t = line.rstrip("\n").split("\t")
    refs["tech/" + i] = refs["tech-webcam/" + i] = t

cols = ["franglais", "f-thomas", "f-respelled", "franglais-webcam", "fw-thomas", "fw-respelled"]
print(f"{'arm':28}" + "".join(f"{c:>17}" for c in cols) + f"{'false terms':>12}")
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.tsv"))):
    hit = {c: [0, 0] for c in cols}
    false, missed, inserted = 0, Counter(), Counter()
    for line in open(path, encoding="utf-8"):
        p = line.rstrip("\n").split("\t") + [""] * 4
        key, s = p[0], p[0].split("/")[0]
        if key not in refs:
            continue
        r, h = norm(refs[key]), norm(p[3])
        if s.startswith("franglais"):
            voice = ("f" if s == "franglais" else "fw") + ("-thomas" if key.endswith("-1") else "-respelled")
            for t in {tuple(x) for x in terms_of[key]}:
                cr, ch = count(list(t), r), count(list(t), h)
                for c in (s, voice):
                    hit[c][0] += min(cr, ch)
                    hit[c][1] += cr
                if ch < cr:
                    missed[" ".join(t)] += cr - ch
        else:
            for t in vocab:
                extra = count(list(t), h) - count(list(t), r)
                if extra > 0:
                    false += extra
                    inserted[" ".join(t)] += extra
    cells = "".join(f"{100 * a / max(b, 1):9.0f}% {a:3d}/{b:<3d}" for a, b in hit.values())
    print(f"{os.path.basename(path)[:-4]:28}{cells}{false:12d}")
    if "-v" in sys.argv:
        print("   missed:", ", ".join(f"{w} {n}" for w, n in missed.most_common()))
        if inserted:
            print("   false:", ", ".join(f"{w} {n}" for w, n in inserted.most_common()))
