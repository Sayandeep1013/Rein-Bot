"""Exercise rapid_words() against a faked rapidocr engine.

The real wheel cannot be installed on this machine (out-of-project install), and
every mistake in the return-shape handling costs a ~20 minute CI run, so the
contract is tested here against the documented v1.x shape:

    result, elapse = engine(path)
    result = [[box, text, score], ...]  # score 0..1
    result is None when nothing was detected

Covers: tuple unpacking, None result, bare-list return, short detection rows,
non-numeric score, whitespace splitting into words, punctuation stripping, and
CJK staying a single token.

Since the telemetry change it also covers the geometry half of the contract --
quad parsing, axis-aligned vs rotated height, line-level token counts -- plus
the parallel work in ocr_words and _ascii, driven through a faked `run()` so
that tesseract's TSV parsing is testable on a machine with no tesseract.

The single most important assertion here is invisible: every check() call also
verifies that `tokens` mirrors `words` exactly. That invariance is the entire
safety argument for the telemetry run. If it holds, the verdicts -- and so the
shipped set -- cannot have moved, and the 36 already-eyeballed run-3 stills stay
valid as labelled ground truth.
"""
import sys
import shutil
import types
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "pipeline" / "curate_theme.py"

# Inject a fake package BEFORE the module under test imports it.
FAKE_RETURN = [None]        # what the fake engine hands back


class FakeRapidOCR(object):
    calls = 0

    def __init__(self, *a, **kw):
        FakeRapidOCR.calls += 1

    def __call__(self, path):
        return FAKE_RETURN[0]


fake = types.ModuleType("rapidocr_onnxruntime")
fake.RapidOCR = FakeRapidOCR
sys.modules["rapidocr_onnxruntime"] = fake

spec = importlib.util.spec_from_file_location("curate_theme", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BOX = [[0, 0], [10, 0], [10, 10], [0, 10]]
TOKEN_KEYS = set(["conf", "text", "raw", "h", "hrot", "w", "top", "ntok",
                  "img_w", "img_h"])
fails = []


def check(label, expected):
    got = mod.rapid_words("frame.jpg")
    if not (isinstance(got, tuple) and len(got) == 2):
        print("%-46s FAIL (not a (words, tokens) pair)" % label)
        fails.append(label + " shape")
        return None
    words, tokens = got
    ok = words == expected
    print("%-46s %s" % (label, "OK" if ok else "FAIL"))
    if not ok:
        print("    expected %r" % (expected,))
        print("    got      %r" % (words,))
        fails.append(label)
    # The invariance the whole telemetry change rests on: tokens must be the
    # same tokens, in the same order, as the metric list. Verified on every
    # single check rather than once in a dedicated test, because a drift here
    # would mean the geometry rows describe different text than the verdict was
    # computed from -- calibrating offline against a lie.
    mirror = [(t["conf"], t["text"]) for t in tokens]
    if mirror != words:
        print("%-46s FAIL" % "  ^ tokens mirror words")
        print("    words  %r" % (words,))
        print("    tokens %r" % (mirror,))
        fails.append(label + " mirror")
    for t in tokens:
        if set(t.keys()) != TOKEN_KEYS:
            print("%-46s FAIL %r" % ("  ^ token keys exact", sorted(t.keys())))
            fails.append(label + " keys")
            break
    return tokens


def expect(label, got, want):
    ok = got == want
    print("%-46s %s" % (label, "OK" if ok else "FAIL"))
    if not ok:
        print("    expected %r" % (want,))
        print("    got      %r" % (got,))
        fails.append(label)


# 1. Documented v1.x shape: (detections, timings), score 0..1 -> 0..100.
FAKE_RETURN[0] = ([[BOX, "ASSASSINATION", 0.94]], 0.31)
check("tuple return, single word, score scaled", [(94.0, "ASSASSINATION")])

# 2. No detections is None, not [].
FAKE_RETURN[0] = (None, 0.05)
check("None detections -> empty", [])

# 3. Some builds return a bare list rather than a tuple.
FAKE_RETURN[0] = [[BOX, "BLACK", 0.9]]
check("bare list return", [(90.0, "BLACK")])

# 4. A detected line is split into words so "longest word" means the same
#    thing as it does for tesseract.
FAKE_RETURN[0] = ([[BOX, "KOROSENSEI teacher.", 0.88]], 0.2)
check("line split into words, punctuation stripped",
      [(88.0, "KOROSENSEI"), (88.0, "teacher")])

# 5. CJK has no spaces, so it stays one token. Intended, not a defect.
FAKE_RETURN[0] = ([[BOX, u"\u51fa\u5e2d\u756a\u53f7", 0.8]], 0.2)
check("CJK stays a single token", [(80.0, u"\u51fa\u5e2d\u756a\u53f7")])

# 6. Rows that are too short, and non-numeric scores, are skipped not fatal.
FAKE_RETURN[0] = ([[BOX, "short"], [BOX, "bad", "NaN-ish"], [BOX, "GOOD", 0.75]], 0.1)
check("malformed rows skipped", [(75.0, "GOOD")])

# 7. Punctuation-only detections carry no title and are dropped.
FAKE_RETURN[0] = ([[BOX, "!!! ---", 0.99]], 0.1)
check("punctuation-only dropped", [])

# 8. Empty list of detections.
FAKE_RETURN[0] = ([], 0.1)
check("empty detections -> empty", [])

# The engine must be constructed exactly once across all of the above.
print("%-46s %s (%d)" % ("engine constructed once and cached",
                         "OK" if FakeRapidOCR.calls == 1 else "FAIL",
                         FakeRapidOCR.calls))
if FakeRapidOCR.calls != 1:
    fails.append("engine cached")

# --- geometry half of the contract -----------------------------------------
# 9. Height, width and top come off the quad, and height is not width. The
#    whole hypothesis under test in CI is that title text is physically large,
#    so a transposed axis here would silently invalidate the calibration.
TALL = [[5, 20], [105, 20], [105, 60], [5, 60]]
FAKE_RETURN[0] = ([[TALL, "TITLE", 0.9]], 0.1)
toks = check("axis-aligned quad -> h/w/top", [(90.0, "TITLE")])
if toks:
    expect("  ^ geometry from quad",
           (toks[0]["h"], toks[0]["hrot"], toks[0]["w"], toks[0]["top"]),
           (40, 40, 100, 20))

# 10. A tilted line is why two heights are recorded: the axis-aligned extent
#     inflates with the tilt (70px here for ~22px glyphs) while the mean of the
#     short edges stays honest. Which one discriminates better is a question for
#     the artifact; this only proves they are measured and do differ.
ROT = [[0, 0], [100, 50], [90, 70], [-10, 20]]
FAKE_RETURN[0] = ([[ROT, "TILTED", 0.9]], 0.1)
toks = check("rotated quad -> h_aa inflates, h_rot honest",
             [(90.0, "TILTED")])
if toks:
    expect("  ^ h_aa 70 vs h_rot 22",
           (toks[0]["h"], toks[0]["hrot"], toks[0]["w"], toks[0]["top"]),
           (70, 22, 110, 0))

# 11. rapidocr detects whole lines, so two words out of one detection share one
#     height. ntok records that, so offline analysis cannot mistake a line
#     height for a per-glyph height.
FAKE_RETURN[0] = ([[TALL, "TWO WORDS", 0.9]], 0.1)
toks = check("line height shared, ntok records sharing",
             [(90.0, "TWO"), (90.0, "WORDS")])
if toks:
    expect("  ^ both tokens ntok=2 at h=40",
           [(t["ntok"], t["h"]) for t in toks], [(2, 40), (2, 40)])
    expect("  ^ raw keeps the whole line",
           [t["raw"] for t in toks], ["TWO WORDS", "TWO WORDS"])

# 12. This engine never reports the image size; ocr_frame backfills it from the
#     orig tesseract pass. Zero is the sentinel that backfill looks for, so it
#     must be zero and not absent.
FAKE_RETURN[0] = ([[TALL, "DIMS", 0.9]], 0.1)
toks = check("img dims unknown to this engine", [(90.0, "DIMS")])
if toks:
    expect("  ^ img_w/img_h are 0 sentinels",
           (toks[0]["img_w"], toks[0]["img_h"]), (0, 0))

# 13. A malformed box must degrade to zero geometry, never crash a 20-minute
#     run: the text half of the contract is the safety filter and has to survive.
FAKE_RETURN[0] = ([["nope", "SURVIVE", 0.9],
                   [[[0, 0], [1, 1], [2, 2]], "ALSO", 0.8]], 0.1)
toks = check("malformed box degrades to zeros",
            [(90.0, "SURVIVE"), (80.0, "ALSO")])
if toks:
    expect("  ^ zero geometry, no crash",
           [(t["h"], t["hrot"], t["w"], t["top"]) for t in toks],
           [(0, 0, 0, 0), (0, 0, 0, 0)])

# 14. Opt-out returns empty without touching the engine.
mod.RAPIDOCR_ENABLE = False
FAKE_RETURN[0] = ([[BOX, "IGNORED", 0.99]], 0.1)
check("RAPIDOCR_ENABLE=false -> empty", [])
mod.RAPIDOCR_ENABLE = True

# 15. A missing wheel must be fatal, never a silent downgrade to tesseract.
mod._RAPID[:] = []
del sys.modules["rapidocr_onnxruntime"]
try:
    mod.rapid_words("frame.jpg")
    print("%-46s FAIL (no raise)" % "missing wheel is fatal")
    fails.append("missing wheel")
except RuntimeError as exc:
    ok = "RAPIDOCR_ENABLE=false" in str(exc)
    print("%-46s %s" % ("missing wheel raises with opt-out hint",
                        "OK" if ok else "FAIL"))
    if not ok:
        fails.append("missing wheel message")

# --- ocr_words: tesseract's TSV, driven through a faked run() ---------------
# tesseract is not installed on this machine, and locally saved JPEGs cannot be
# re-OCR'd, so every parsing mistake would otherwise cost a ~20-minute CI run to
# discover. The riskiest new logic is the level-1 page-row trick that supplies
# the image dimensions without PIL and without 60 ffprobe calls per theme; it is
# exercised here against synthetic tesseract output.
TSV_HEAD = ["level", "page_num", "block_num", "par_num", "line_num",
            "word_num", "left", "top", "width", "height", "conf", "text"]
PAGE = ["1", "1", "0", "0", "0", "0", "0", "0", "1280", "720", "-1", ""]


def word(left, top, w, h, conf, text):
    return ["5", "1", "1", "1", "1", "1", left, top, w, h, conf, text]


def tsv(*rows):
    return "\n".join("\t".join(str(c) for c in r)
                     for r in ((TSV_HEAD,) + rows)) + "\n"


class FakeProc(object):
    def __init__(self, text, rc=0):
        self.returncode = rc
        self.stdout = text.encode("utf-8")


TESS = [FakeProc("")]
mod.run = lambda argv: TESS[0]


def ocr_check(label, text, expected):
    TESS[0] = FakeProc(text)
    got = mod.ocr_words("frame.jpg")
    if not (isinstance(got, tuple) and len(got) == 2):
        print("%-46s FAIL (not a (words, tokens) pair)" % label)
        fails.append(label + " shape")
        return None
    words, tokens = got
    expect(label, words, expected)
    mirror = [(t["conf"], t["text"]) for t in tokens]
    if mirror != words:
        print("%-46s FAIL" % "  ^ tokens mirror words")
        print("    words  %r" % (words,))
        fails.append(label + " mirror")
    for t in tokens:
        if set(t.keys()) != TOKEN_KEYS:
            print("%-46s FAIL %r" % ("  ^ token keys exact", sorted(t.keys())))
            fails.append(label + " keys")
            break
    return tokens


# 16. The ordinary case: page row supplies the dimensions, word rows supply the
#     boxes, and the alnum text still matches what the metric path always saw.
toks = ocr_check("tesseract page row -> dims + geometry",
                 tsv(PAGE,
                     word(100, 200, 60, 40, "95.5", "Angel"),
                     word(170, 200, 80, 40, "88", "Beats!")),
                 [(95.5, "Angel"), (88.0, "Beats")])
if toks:
    expect("  ^ geometry and dims on token 0",
           (toks[0]["h"], toks[0]["hrot"], toks[0]["w"], toks[0]["top"],
            toks[0]["img_w"], toks[0]["img_h"], toks[0]["ntok"]),
           (40, 40, 60, 200, 1280, 720, 1))
    expect("  ^ raw keeps the punctuation alnum strips",
           [t["raw"] for t in toks], ["Angel", "Beats!"])

# 17. The page row is only *conventionally* first. Backfilling dimensions after
#     the loop rather than inside it is what stops a late page row from leaving
#     un-normalisable rows in the dump.
toks = ocr_check("page row last -> dims still backfilled",
                 tsv(word(10, 20, 30, 40, "90", "LATE"), PAGE),
                 [(90.0, "LATE")])
if toks:
    expect("  ^ backfill runs after the loop",
           (toks[0]["img_w"], toks[0]["img_h"]), (1280, 720))

# 18. Layout rows (conf -1), punctuation-only fragments, unparseable confidences
#     and short rows are all skipped -- unchanged from before the telemetry work.
ocr_check("conf -1 / punctuation / short rows dropped",
          tsv(PAGE,
              word(0, 0, 5, 5, "-1", "ghost"),
              word(0, 0, 5, 5, "99", "!!!"),
              word(0, 0, 5, 5, "abc", "bad"),
              ["5", "1", "1"],
              word(0, 0, 5, 5, "70", "KEPT")),
          [(70.0, "KEPT")])

# 19. No page row at all: dimensions stay at the 0 sentinel instead of crashing,
#     because a missing normaliser is a row to discard offline, not a dead run.
toks = ocr_check("no page row -> dims 0, no crash",
                 tsv(word(1, 2, 3, 4, "80", "NOPAGE")),
                 [(80.0, "NOPAGE")])
if toks:
    expect("  ^ dims fall back to 0", (toks[0]["img_w"], toks[0]["img_h"]),
           (0, 0))

# 20. Non-numeric box values degrade to zero geometry. The text half of the
#     contract is the safety filter and must survive anything.
toks = ocr_check("non-numeric box degrades to zeros",
                 tsv(PAGE,
                     ["5", "1", "1", "1", "1", "1", "x", "y", "z", "q",
                      "77", "SAFE"]),
                 [(77.0, "SAFE")])
if toks:
    expect("  ^ zero geometry, dims still backfilled",
           (toks[0]["h"], toks[0]["w"], toks[0]["top"], toks[0]["img_w"]),
           (0, 0, 0, 1280))

# 21. A crashed OCR pass must stay fatal. Reading it as "no text found" would
#     turn the only safety filter into a no-op.
TESS[0] = FakeProc("boom", rc=1)
try:
    mod.ocr_words("frame.jpg")
    print("%-46s FAIL (no raise)" % "tesseract failure stays fatal")
    fails.append("tesseract failure")
except RuntimeError:
    print("%-46s OK" % "tesseract failure stays fatal")

# --- _ascii -----------------------------------------------------------------
# The token dump is opened encoding="ascii" so an escaping miss fails loudly at
# write time instead of producing a file that mis-decodes in three downstream
# scripts. Doubling backslashes first is what keeps the escaping reversible: a
# real CJK glyph becomes \u51fa, while the literal text \u51fa becomes \\u51fa,
# so the two remain distinguishable after escaping.
ACASES = [
    (u"plain", "plain"),
    (u"a\tb", "a b"),
    (u"a\r\nb", "a  b"),
    (u"a\\b", "a\\\\b"),
    (u"\u51fa\u5e2d", "\\u51fa\\u5e2d"),
    (u"\\u51fa", "\\\\u51fa"),
    (95.5, "95.5"),
]
for i, (src, want) in enumerate(ACASES, 1):
    expect("_ascii case %d" % i, mod._ascii(src), want)
try:
    for src, _ in ACASES:
        mod._ascii(src).encode("ascii")
    print("%-46s OK" % "_ascii output is always 7-bit")
except UnicodeEncodeError:
    print("%-46s FAIL" % "_ascii output is always 7-bit")
    fails.append("_ascii 7-bit")

# --- the dump writer, end to end -------------------------------------------
# ocr_frame is faked so the writer can be exercised with no ffmpeg and no
# tesseract. This is what proves the header and the value list stay aligned; a
# silent column drift would misparse every downstream analysis.
import tempfile


def fake_frame(path, workdir):
    geoms = [
        ("orig", [{"conf": 95.5, "text": "Angel", "raw": "Angel", "h": 40,
                   "hrot": 40, "w": 60, "top": 200, "ntok": 1,
                   "img_w": 1280, "img_h": 720}]),
        ("rapid", [{"conf": 98.0, "text": u"\u51fa\u5e2d",
                    "raw": u"\u51fa\u5e2d\t2", "h": 55, "hrot": 22, "w": 90,
                    "top": 30, "ntok": 2, "img_w": 1280, "img_h": 720}]),
    ]
    m = {"passes": [("orig", [(95.5, "Angel")]),
                    ("rapid", [(98.0, u"\u51fa\u5e2d")])],
         "geoms": geoms, "max_conf": 98.0, "words": 2,
         "sample": "Angel(95)"}
    for n in (0, 50, 60, 70, 80, 90):
        m["chars_%d" % n] = 7
        m["longest_%d" % n] = 5
    return m


mod.ocr_frame = fake_frame
mod.OCR_DUMP = True
# Scratch stays inside the project (CLAUDE.md), and .tmp/ is gitignored, so a
# fresh clone will not have it yet.
scratch = ROOT / ".tmp"
scratch.mkdir(exist_ok=True)
tmp = Path(tempfile.mkdtemp(dir=str(scratch)))
cands = [{"index": 0, "ts": 45.1, "bytes": 80090, "path": tmp / "f.jpg"}]
clean, texty = mod.text_filter(cands, tmp, tmp, "STEM")
expect("verdict routed by longest word", (len(clean), len(texty)), (0, 1))

tok_file = tmp / "tokens-STEM.tsv"
expect("token dump written", tok_file.exists(), True)
if tok_file.exists():
    # Read back with the same strict codec the writer used: if this decodes, no
    # analysis script downstream needs to know an encoding.
    lines = tok_file.read_text(encoding="ascii").splitlines()
    head = lines[0].split("\t")
    expect("header is 14 columns", len(head), 14)
    expect("every row matches the header width",
           sorted(set(len(l.split("\t")) for l in lines[1:])), [14])
    expect("one row per token per pass", len(lines) - 1, 2)
    row = dict(zip(head, lines[1].split("\t")))
    expect("  ^ orig row values",
           (row["ts"], row["verdict"], row["pass"], row["conf"], row["h_px"],
            row["hrot_px"], row["w_px"], row["top_px"], row["img_w"],
            row["img_h"], row["line_ntok"], row["len"], row["text"]),
           ("45.1", "TEXTY", "orig", "95.5", "40", "40", "60", "200",
            "1280", "720", "1", "5", "Angel"))
    row2 = dict(zip(head, lines[2].split("\t")))
    expect("  ^ CJK escaped, tab flattened, len is glyphs",
           (row2["pass"], row2["text"], row2["raw"], row2["len"],
            row2["h_px"], row2["hrot_px"]),
           ("rapid", "\\u51fa\\u5e2d", "\\u51fa\\u5e2d 2", "2", "55", "22"))
shutil.rmtree(str(tmp), ignore_errors=True)

print()
print("FAILURES: %d" % len(fails))
if fails:
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("rapid_words contract holds against the documented v1.x shape")
