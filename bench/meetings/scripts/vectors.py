"""Real 256-d voice embeddings for the `consolidate` cases of
Tests/FluenceMeetingCoreTests/speaker-consolidation-vectors.json (FLU-33).

Reads the bench's cached diarizer output on the AMI dev meetings, VoIP-like copy
(scripts/run.sh voip), labels each raw voice with the AMI participant it overlaps most,
picks real voices that fit each case's contract, and rewrites only those cases'
`embeddings` lines: the turns, caps and expected mappings stay as written. Embeddings
are rounded to 3 decimals; no audio, no words, no names, no meeting IDs go in the file.

Usage: python3 -I scripts/vectors.py <MBENCH_DATA> <vectors.json>
"""
import json
import math
import re
import sys

DATA, VECTORS = sys.argv[1], sys.argv[2]
HERE = __file__.rsplit("/scripts/", 1)[0]
MERGE = 0.68  # SpeakerConsolidation.Settings.mergeSimilarity
MARGIN = 0.03  # keep every deciding cosine this far from MERGE


def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    return dot / math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))


def overlap(a, b):
    total = 0.0
    for s, e in a:
        for t, u in b:
            total += max(0.0, min(e, u) - max(s, t))
    return total


voices = []  # (meeting, voice, person, seconds, embedding)
for m in json.load(open(f"{HERE}/meetings.json"))["meetings"]:
    if m["split"] != "dev":
        continue
    run = json.load(open(f"{DATA}/cache/voip/{m['id']}.json"))["runs"]["nocap"]
    ref = {}
    for line in open(f"{DATA}/ami/setup/repo/only_words/rttms/dev/{m['id']}.rttm"):
        f = line.split()
        ref.setdefault(f[7], []).append((float(f[3]), float(f[3]) + float(f[4])))
    for voice, emb in run["embeddings"].items():
        own = [(t["start"], t["end"]) for t in run["turns"] if t["speaker"] == voice]
        seconds = sum(e - s for s, e in own)
        shares = {p: overlap(own, iv) for p, iv in ref.items()}
        person = max(shares, key=shares.get)
        if seconds >= 8 and shares[person] / seconds >= 0.6:  # clean voices only
            voices.append((m["id"], voice, person, seconds, [round(x, 3) for x in emb]))

pairs = [(cos(a[4], b[4]), a, b) for i, a in enumerate(voices) for b in voices[i + 1:] if a[0] == b[0]]
same = sorted((p for p in pairs if p[1][2] == p[2][2]), key=lambda p: p[0])
diff = sorted((p for p in pairs if p[1][2] != p[2][2]), key=lambda p: p[0])


def third(a, b, below):
    """A voice of another person in the same meeting, below `below` with both."""
    others = [v for v in voices if v[0] == a[0] and v[2] not in (a[2], b[2])]
    return next((v for v in others if max(cos(v[4], a[4]), cos(v[4], b[4])) < below), None)


picked = {}
# 1. One person split by the call: their most similar pair, well above the threshold.
c, a, b = same[-1]
assert c >= MERGE + MARGIN, c
picked["one voice split by the call's audio merges back"] = {"A": a, "B": b, "C": third(a, b, MERGE - MARGIN)}
# 2. Two people: the most similar pair still clear of the threshold (different people
#    above it exist on this data; README).
c, a, b = max(p for p in diff if p[0] <= MERGE - MARGIN)
picked["different people stay apart"] = {"A": a, "B": b}
picked["a minor voice without an embedding joins whoever speaks nearest"] = {"A": a, "B": b}
# 3. A few seconds of a person split below the threshold: closer to that person than to the other.
for c, b, minor in same:
    other = third(b, minor, MERGE - MARGIN)
    if c <= MERGE - MARGIN and other and cos(minor[4], b[4]) > cos(minor[4], other[4]) + MARGIN:
        picked["a few seconds of voice join the closest speaker"] = {"A": other, "B": b, "C": minor}
        break
# 5/6. A split below the threshold whose pair is still the closest of three voices:
#      merged by a cap of 2, kept without a cap.
for c, a, b in same:
    other = third(a, b, c - MARGIN)
    if c <= MERGE - MARGIN and other:
        for name in ("the call's participant count caps the voices: the closest pair merges",
                     "without a cap, distinct voices are all kept"):
            picked[name] = {"A": a, "B": b, "C": other}
        break
assert len(picked) == 6, sorted(picked)

text = open(VECTORS).read()
for name, chosen in picked.items():
    start = text.index(json.dumps(name, ensure_ascii=False))
    line = re.compile(r'\n(\s*)"embeddings": \{.*?\n?\s*\},\n', re.S).search(text, start)
    pad = line.group(1)
    body = ",\n".join(f'{pad}  "{k}": {json.dumps(v[4])}' for k, v in chosen.items())
    text = text[: line.start()] + f'\n{pad}"embeddings": {{\n{body}\n{pad}}},\n' + text[line.end():]
    cosines = {f"{x}{y}": round(cos(chosen[x][4], chosen[y][4]), 3) for x in chosen for y in chosen if x < y}
    print(f"{name}: {cosines}", file=sys.stderr)
open(VECTORS, "w").write(text)
