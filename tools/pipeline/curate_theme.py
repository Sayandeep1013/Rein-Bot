#!/usr/bin/env python3
"""Process ONE AnimeThemes theme into the five objects a question needs.

Implements doc/GAME-DESIGN.md 5.2. Reads one flattened manifest job as JSON on
stdin, writes one JSON result object to stdout, and logs prose to stderr.

WHY THIS IS PYTHON AND NOT MORE BASH
The previous video-era workflow carried this logic inline in YAML and needed
three separate bug fixes, every one of them a shell subtlety rather than a
mistake about the pipeline: ffmpeg consuming the job list from stdin, a pause
placed on an unreachable line, and an encoding fault that corrupted titles.
The work here is worse for bash than that version was -- per-theme medians,
float timestamps, sorting by two keys, grouping survivors -- so it lives in a
committed, diffable script and the workflow only orchestrates.

THE INVARIANT THAT MATTERS MOST
The frame OCR cleared must be the frame that ships. Re-extracting a chosen
frame from the source with `-ss <ts>` snaps to the nearest keyframe and can
hand back a DIFFERENT image than the one that passed the text filter, which is
precisely the doc/BLOCKERS.md B-28 failure mode. So candidates are extracted
exactly once, and every later step -- detail measurement, OCR, delivery
encode -- operates on that same file. Recompressing a cleared JPEG is safe
because it preserves the pixels; re-seeking the video is not.

Ordering is also load-bearing: all five objects are uploaded BEFORE
ingest_question is called, so a row can never point at bytes that never
arrived (doc/GAME-DESIGN.md 5.2 step 11).
"""

import io
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

# --------------------------------------------------------------------------
# Tunables. Defaults are the measured values from doc/GAME-DESIGN.md 5.2;
# every one is overridable from the workflow so that retuning after a dry-run
# inspection does not require editing pipeline logic. B-28's fallback ladder
# is operated through these.
# --------------------------------------------------------------------------
CANDIDATES = int(os.environ.get("CANDIDATES", "60"))
EDGE_SKIP = float(os.environ.get("EDGE_SKIP", "2"))        # seconds trimmed off each end
DETAIL_PCT = float(os.environ.get("DETAIL_PCT", "45"))     # % of per-theme median JPEG bytes
# The rejection rule is the LONGEST SINGLE WORD at or above OCR_MIN_CONF, not a
# character sum. Measured over 647 candidate frames from 12 themes at floor 70:
# junk word fragments from texture and motion peak at 3 characters (p50=2,
# p95=3), while every frame carrying real title text reached 5 or more --
# ASSASSINATION(92), ASSASSINATION(95), BLACK(94) CLOVER(96), gelBeals(90),
# Musamit(86). Exactly 18 of 647 frames (2.8%) clear 5, and all 18 are genuine.
#
# A character SUM cannot separate the two because it adds junk fragments from
# across the whole frame: chars_70 reached 34 on noise (p90=9, p99=19). That is
# why the earlier `chars_70 >= 4` rule skipped 8 of 10 themes on the first
# measured run while still passing text-bearing frames -- it was simultaneously
# too strict and too weak, because it was measuring the wrong thing.
OCR_MIN_WORD = int(os.environ.get("OCR_MIN_WORD", "5"))     # longest word that rejects a frame
OCR_MIN_CONF = float(os.environ.get("OCR_MIN_CONF", "70"))  # ignore words below this confidence
OCR_PSM = os.environ.get("OCR_PSM", "11")
# jpn_vert dropped: across those same 647 frames it never produced a single
# high-confidence word, contributing only junk fragments and runtime. Horizontal
# jpn is kept for the cases it may still catch.
OCR_LANGS = os.environ.get("OCR_LANGS", "eng+jpn")
# Second OCR engine. tesseract is measurably blind to stylised anime display
# typography, not merely mistuned: of the 36 stills shipped by measurement run
# 32605150598, three carried plainly legible overlaid text -- a large-Latin
# "KOROSENSEI teacher.", plus two credit-name cards -- for which tesseract
# returned no high-confidence word at all. Its longest word at conf>=70 on
# those frames was 1-2 characters, so no threshold on tesseract output could
# ever have rejected them. rapidocr is detector-first and is strong exactly
# where tesseract fails, so it runs as a second pass and the two are merged
# worst-case.
#
# Pinned to <2 deliberately (see .github/workflows/curate.yml): the 1.x
# rapidocr-onnxruntime wheels ship the .onnx weights inside the package,
# whereas the 2.x line (renamed to "rapidocr") downloads them on first use.
# Bundled weights mean no network call at inference time and nothing to
# pre-warm before the frame loop.
RAPIDOCR_ENABLE = os.environ.get("RAPIDOCR_ENABLE", "true").lower() == "true"
# Both engines are gated on the same OCR_MIN_CONF floor. Their scores are not
# calibrated against each other, so this is an assumption, not a measurement --
# but adding a second threshold would double the tuning surface with no data to
# justify a different value. The dump's culprit column records which engine
# fired, which is what would justify splitting them later.
#
# ------------------------------------------------------------ the union rule
# The longest-word rule above is necessary but not sufficient. It can only catch
# titles the engine READS, and two confirmed leaks shipped straight past it in
# run 32617226964: a Japanese credit-name card (AngelBeats-OP1 45.1) and a
# stylised logo the engine misread entirely (AnsatsuKyoushitsu-OP1 78.0). Both
# scored longest_70 = 2, the same as motion blur, so no threshold on word length
# could ever have rejected them.
#
# What separates them is not what the text says but how the boxes are arranged,
# so a second rule runs alongside: reject if EITHER typographic coherence
# (several confident boxes of one height on a shared baseline) or a count of
# large boxes (title-sized regions, confidence ignored) crosses its threshold.
# The two are deliberately complementary -- coherence catches titles that were
# read, the box count catches logos that were misread -- and neither separates
# the labelled set alone.
#
# These four numbers were fitted offline in .tmp/tokens.py against 41
# hand-labelled frames from the run-4 artifact, not guessed. Do not retune them
# from intuition: the falsification trail (peak height, single features,
# cluster-size relaxation, dilation) is in doc/BLOCKERS.md B-28, and three of the
# five original leak labels turned out to be wrong before any rule was fitted.
OCR_COH_T = float(os.environ.get("OCR_COH_T", "0.21"))
OCR_BIG_T = float(os.environ.get("OCR_BIG_T", "3"))
OCR_BIG_MIN_H = float(os.environ.get("OCR_BIG_MIN_H", "0.28"))
# Selector guard, NOT a filter. A frame at or above this risk must not be chosen
# as a still while a quieter frame exists in the same third. Measured cost on the
# 12 calibration themes is exactly zero -- it changes no pick, because no
# surviving high-risk frame currently wins its band on file size. It is here for
# the 122 themes not yet measured, three of which already hold survivors at
# 0.90-0.997 that would ship the moment one of them is the biggest in its band.
OCR_QUIET_T = float(os.environ.get("OCR_QUIET_T", "0.85"))
# Write out/ocr-<stem>.tsv: one row per (frame, OCR pass, word) with its
# confidence. This exists because the first real run showed the text filter
# rejecting 44-58 of ~55 frames per theme, and inspecting the images proved the
# rejections were mostly hallucination -- a plain blue sky scored 29 characters
# while the genuine "Angel Beats!" title card scored 43. Character counts alone
# cannot separate those, so the replacement threshold has to be chosen from a
# measured confidence distribution rather than guessed at a second time.
OCR_DUMP = os.environ.get("OCR_DUMP", "false").lower() == "true"
AUDIO_SECONDS = float(os.environ.get("AUDIO_SECONDS", "20"))
AUDIO_START = float(os.environ.get("AUDIO_START", "5"))    # skip the near-silent OP intro
AUDIO_BITRATE = os.environ.get("AUDIO_BITRATE", "64k")     # 64k x 20 s ~= 160 KB
CAND_WIDTH = int(os.environ.get("CAND_WIDTH", "854"))
CAND_QUALITY = os.environ.get("CAND_QUALITY", "3")         # generous: feeds OCR and measurement
DELIVER_QUALITY = os.environ.get("DELIVER_QUALITY", "6")   # what players download
OCR_UPSCALE = int(os.environ.get("OCR_UPSCALE", "2"))      # 0 disables the second OCR pass

MAX_BYTES = int(os.environ.get("MAX_BYTES", "524288"))     # media bucket file_size_limit
UA = os.environ.get(
    "UA", "GuessTheAnime-curate/1.0 (+https://github.com/Sayandeep1013/Rein-Bot)"
)
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_KEY = os.environ.get("SERVICE_KEY", "")
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
BUCKET = os.environ.get("BUCKET", "media")


def log(msg):
    sys.stderr.write(str(msg) + "\n")
    sys.stderr.flush()


def run(cmd, **kw):
    """Run a command, capturing output. Never raises; caller inspects returncode.

    stdin is closed for every child. ffmpeg has an interactive console and reads
    stdin when it is a pipe, which is how an earlier version of this pipeline
    had its job list silently eaten mid-loop. -nostdin is passed as well; this
    is the belt to that braces, and it covers any future child too.
    """
    return subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, **kw
    )


def must(cmd, what):
    p = run(cmd)
    if p.returncode != 0:
        tail = p.stdout.decode("utf-8", "replace")[-1500:]
        raise RuntimeError("%s failed (exit %d)\n%s" % (what, p.returncode, tail))
    return p.stdout.decode("utf-8", "replace")


def probe_duration(path):
    out = must(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        "ffprobe %s" % path,
    ).strip()
    try:
        return float(out.splitlines()[0])
    except (ValueError, IndexError):
        raise RuntimeError("ffprobe gave no duration for %s: %r" % (path, out))


# --------------------------------------------------------------------------
# Step 4: download the source ONCE.
# --------------------------------------------------------------------------
# This is the expensive step (~46.7 MB median, doc/GAME-DESIGN.md 5.2) and
# everything below derives from the one file. curl rather than letting ffmpeg
# stream it: ffmpeg would have to refetch for the audio pass and again for the
# frame pass, tripling AnimeThemes traffic for a free community service.
#
# Retried with backoff because AnimeThemes returned 5XX on five consecutive
# items once the run had pulled ~200 MB in about two minutes. A 5XX here is
# transient by definition and an earlier run threw away half a batch by
# treating the first one as fatal.
def download(url, dest, attempts=3):
    for attempt in range(1, attempts + 1):
        p = run([
            "curl", "-fsSL", "--max-time", "900",
            "-A", UA, "-o", str(dest), url,
        ])
        if p.returncode == 0 and dest.exists() and dest.stat().st_size > 0:
            return dest.stat().st_size
        backoff = attempt * 20
        log("  download attempt %d/%d failed (exit %d)"
            % (attempt, attempts, p.returncode))
        if attempt < attempts:
            log("  waiting %ds" % backoff)
            time.sleep(backoff)
    raise RuntimeError("download failed after %d attempts: %s" % (attempts, url))


# --------------------------------------------------------------------------
# Step 5: the audio object.
# --------------------------------------------------------------------------
# Opus in a WebM container, because the bucket's allowed_mime_types is
# {audio/webm, image/jpeg} (migration 0010) -- video/webm was removed outright
# so the one upload the design forbids is now impossible.
#
# -map_metadata -1 -map_chapters -1 is a correctness requirement, not tidiness:
# source containers carry title tags, and a tag naming the anime hands over the
# answer to anyone who opens the file in a media player.
def extract_audio(src, dest, duration):
    start = min(AUDIO_START, max(0.0, duration - AUDIO_SECONDS))
    must([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", "%.3f" % start, "-i", str(src), "-t", "%.3f" % AUDIO_SECONDS,
        "-vn", "-map_metadata", "-1", "-map_chapters", "-1",
        "-c:a", "libopus", "-b:a", AUDIO_BITRATE, "-ac", "2",
        "-f", "webm", str(dest),
    ], "audio extract")
    return probe_duration(dest), dest.stat().st_size


# --------------------------------------------------------------------------
# Step 6: ~60 evenly spaced candidate frames.
# --------------------------------------------------------------------------
# The first and last EDGE_SKIP seconds are excluded so fade-ins, fade-outs and
# the hard cut at either boundary never become a still.
#
# Extracted at delivery width and generous quality, once. See the module
# docstring: these exact files are measured, OCR'd and (recompressed) shipped.
def extract_candidates(src, outdir, duration):
    span = duration - 2 * EDGE_SKIP
    if span <= 1:
        raise RuntimeError("source too short for frame extraction (%.1fs)" % duration)
    fps = CANDIDATES / span
    must([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", "%.3f" % EDGE_SKIP, "-i", str(src), "-t", "%.3f" % span,
        "-map_metadata", "-1", "-map_chapters", "-1",
        "-vf", "fps=%.6f,scale=%d:-2" % (fps, CAND_WIDTH),
        "-q:v", CAND_QUALITY,
        str(outdir / "%03d.jpg"),
    ], "frame extract")

    frames = sorted(outdir.glob("*.jpg"))
    out = []
    for i, path in enumerate(frames, start=1):
        # Frames are evenly spaced, so the timestamp follows from the index and
        # does not need to be parsed back out of ffmpeg.
        out.append({
            "index": i,
            "path": path,
            "ts": EDGE_SKIP + (i - 1) * (span / CANDIDATES),
            "bytes": path.stat().st_size,
        })
    return out


# --------------------------------------------------------------------------
# Step 7 / 5.2.1: the detail filter.
# --------------------------------------------------------------------------
# Compressed size at fixed quality is a proxy for visual complexity, so this
# drops fades, flat colour fields and near-black frames using nothing but the
# encoder already in the pipeline.
#
# The median is PER THEME, never global: one sampled theme's frames all sit
# below the global median, so a global cut would over-reject dark shows
# wholesale while barely touching bright ones.
#
# Do NOT replace this with brightness or `ffmpeg blackframe`. Measured over 40
# real frames (doc/RESEARCH.md 4.10) the single worst frame -- a flat grey card
# -- has mean luma 180.0 and ranks 39th of 40 on brightness, so a brightness
# filter ranks the worst frame as one of the best.
def detail_filter(cands):
    median = statistics.median([c["bytes"] for c in cands])
    floor = median * (DETAIL_PCT / 100.0)
    kept, dropped = [], []
    for c in cands:
        (kept if c["bytes"] >= floor else dropped).append(c)
    log("  detail: median=%d floor=%d (%.0f%%) kept=%d dropped=%d"
        % (median, floor, DETAIL_PCT, len(kept), len(dropped)))
    return kept, dropped, median


# --------------------------------------------------------------------------
# Step 8 / 5.2.2: the text filter. This is the step that protects the answer.
# --------------------------------------------------------------------------
# Tuned to over-reject on purpose. A false positive costs one frame out of
# sixty; a false negative ships the answer. The asymmetry is total, so there is
# no reason to be conservative.
#
# Two passes per frame. Tesseract reads large glyphs far more reliably than
# small ones, and an anime title logo is the adversarial case for OCR --
# stylised, outlined, gradient-filled, often rotated. The upscaled copy adds no
# information but does make marginal text legible to the engine. Either pass
# finding text rejects the frame. The upscale is a throwaway: the shipped file
# is always the original candidate.
def ocr_words(path):
    """OCR one image, returning (words, tokens).

    `words` is the metric contract and is unchanged: [(confidence, alnum), ...].
    `tokens` is the same tokens, in the same order, each a dict that also carries
    the glyph geometry tesseract already gives away for free in its TSV and this
    function used to throw away.

    The geometry exists because the longest-token rule has two *measured* blind
    spots (B-28), neither of which is a threshold problem:

      * a Japanese name is 1-3 glyphs, so it can never reach a 5-character
        token -- `AngelBeats-OP1` t=45.1 shipped five name callouts read at
        86-99 confidence with longest_70 = 2;
      * scattered kinetic title typography is segmented glyph by glyph, so
        `AnsatsuKyoushitsu-OP1` t=78.0 has longest_0 = 2. With the confidence
        floor at *zero* the longest token is still 2, so no floor can catch it.

    What both leaks share, and what the clean frames that currently score
    highest do not, is that the text is physically large. The frame that blocks
    every cheaper fix is `AoNoExorcist-OP1` t=37.6: a cityscape with no text at
    all scoring longest_70 = 4, because four window mullions read as the
    katakana long-vowel mark.

    Heights are recorded raw, in pixels, next to the image dimensions rather
    than pre-divided, so the normalisation and the threshold can both be chosen
    offline from the artifact instead of costing another 20-minute CI run.

    TSV rather than plain stdout because plain text discards the one number
    that actually separates a rendered title card from a cloud: tesseract's
    per-word confidence. Measured on a real run, character count does not
    separate them at all -- a blank sky scored 29 characters and the real
    "Angel Beats!" card scored 43.

    Words with no alphanumeric content are dropped; tesseract emits many
    punctuation-only fragments from texture and they cannot spell a title.
    """
    p = run([
        "tesseract", str(path), "stdout",
        "--psm", OCR_PSM, "--oem", "1", "-l", OCR_LANGS, "tsv",
    ])
    if p.returncode != 0:
        # A crashed OCR pass must never be read as "no text found": that would
        # silently turn the one safety filter into a no-op.
        raise RuntimeError(
            "tesseract failed on %s: %s"
            % (path, p.stdout.decode("utf-8", "replace")[-400:])
        )
    words = []
    tokens = []
    img_w = img_h = 0
    for line in p.stdout.decode("utf-8", "replace").splitlines()[1:]:
        col = line.split("\t")
        if len(col) < 12:
            continue
        # level 1 is the page row, and its box is the image itself -- the only
        # dependency-free way to learn the dimensions here, given that ffprobing
        # every frame would add 60 subprocesses per theme. It carries conf -1
        # and no text, so the filters below still drop it.
        if col[0] == "1":
            try:
                img_w = int(float(col[8]))
                img_h = int(float(col[9]))
            except ValueError:
                pass
        try:
            conf = float(col[10])
        except ValueError:
            continue
        if conf < 0:            # -1 marks layout rows that carry no word
            continue
        alnum = "".join(ch for ch in col[11] if ch.isalnum())
        if alnum:
            words.append((conf, alnum))
            try:
                box_w = int(float(col[8]))
                box_h = int(float(col[9]))
                box_top = int(float(col[7]))
            except ValueError:
                box_w = box_h = box_top = 0
            tokens.append({
                "conf": conf, "text": alnum, "raw": col[11],
                # tesseract boxes are axis-aligned, so the rotated and
                # axis-aligned heights are the same number here. Both are still
                # recorded, so one dump schema covers both engines.
                "h": box_h, "hrot": box_h, "w": box_w, "top": box_top,
                "ntok": 1,
            })
    # Assigned after the loop rather than inside it because the page row is only
    # conventionally first, and a token that recorded img_h = 0 would silently
    # become an un-normalisable row in the dump.
    for t in tokens:
        t["img_w"] = img_w
        t["img_h"] = img_h
    return words, tokens


_RAPID = []      # one-element cache; [] means "not built yet"


def rapid_words(path):
    """Second OCR engine, returning the same (words, tokens) pair as ocr_words.

    Confidences are rescaled to tesseract's 0-100 so both passes can be gated
    on one OCR_MIN_CONF floor.

    rapidocr returns whole text *lines*, not words. Those lines are split on
    whitespace here so that "longest word" means the same thing for both
    engines -- otherwise a single detected line would count as one enormous
    word and the shared threshold would be far more trigger-happy on this pass
    than on tesseract's. CJK has no spaces, so a Japanese run stays a single
    token; that is correct rather than a flaw, because a six-character CJK run
    at high confidence carries far more of a title than six Latin letters do.

    The engine is built once per process and cached. Construction loads the
    ONNX models, so doing it per frame would dominate the runtime of a
    60-frame theme.
    """
    if not RAPIDOCR_ENABLE:
        return [], []
    if not _RAPID:
        try:
            from rapidocr_onnxruntime import RapidOCR
        except ImportError as exc:
            # Deliberately fatal. This pass exists because tesseract provably
            # cannot read some title cards, so quietly degrading to
            # tesseract-only would restore the exact blindness it was added to
            # remove -- and would do it invisibly, in a run that still reports
            # success. Set RAPIDOCR_ENABLE=false to opt out explicitly.
            raise RuntimeError(
                "rapidocr-onnxruntime is not installed (%s). Install it, or set "
                "RAPIDOCR_ENABLE=false to run with tesseract only and accept "
                "that stylised title text will not be detected." % exc
            )
        _RAPID.append(RapidOCR())
    # Default thresholds: this pass wants recall, and the discriminating is
    # done afterwards by OCR_MIN_CONF plus the longest-word rule. Passing
    # guessed threshold kwargs would risk a TypeError 20 CI-minutes in.
    out = _RAPID[0](str(path))
    # v1.x returns (detections, timings); no detections is None, not [].
    dets = out[0] if isinstance(out, tuple) else out
    words = []
    tokens = []
    for det in dets or []:
        # Each detection is [box, text, score] with score in 0..1.
        if len(det) < 3:
            continue
        text, score = det[1], det[2]
        try:
            conf = float(score) * 100.0
        except (TypeError, ValueError):
            continue
        # det[0] is a 4-point quad in original-frame pixels, and was previously
        # discarded outright. Two heights are recorded because they disagree on
        # rotated text: the axis-aligned extent inflates as a line tilts, while
        # the mean of the two short edges stays near the true glyph height.
        # Which one discriminates better is a question for the artifact, not a
        # guess to be baked in here.
        h_aa = w_aa = h_rot = top = 0
        try:
            pts = [(float(pt[0]), float(pt[1])) for pt in det[0]]
        except (TypeError, ValueError, IndexError):
            pts = []
        if len(pts) == 4:
            xs = [x for x, _ in pts]
            ys = [y for _, y in pts]
            h_aa = int(round(max(ys) - min(ys)))
            w_aa = int(round(max(xs) - min(xs)))
            top = int(round(min(ys)))
            h_rot = int(round((
                math.hypot(pts[0][0] - pts[3][0], pts[0][1] - pts[3][1])
                + math.hypot(pts[1][0] - pts[2][0], pts[1][1] - pts[2][1])
            ) / 2.0))
        toks = [a for a in (
            "".join(ch for ch in tok if ch.isalnum())
            for tok in str(text).split()
        ) if a]
        for alnum in toks:
            words.append((conf, alnum))
            tokens.append({
                "conf": conf, "text": alnum, "raw": str(text),
                "h": h_aa, "hrot": h_rot, "w": w_aa, "top": top,
                # rapidocr detects whole *lines*, so every token split out of
                # one line inherits that line's height. ntok records how many
                # shared it, because offline analysis must not read a line
                # height as a per-glyph height.
                "ntok": len(toks),
                # Unknown to this engine; ocr_frame backfills from the orig
                # tesseract pass, which measured the same file.
                "img_w": 0, "img_h": 0,
            })
    return words, tokens


def ocr_frame(path, workdir):
    """Every OCR pass for one frame, merged into one measurement.

    The second pass on a 2x lanczos upscale is kept because small or thin title
    text can be unreadable at 854px and readable at 1708px. Passes are merged by
    taking the worst case per metric: if either pass sees high-confidence text,
    the frame is text-positive. That preserves the asymmetry -- a false positive
    costs one frame out of sixty, a false negative ships the answer.

    Returns a dict of metrics at several confidence floors, so a threshold can
    be chosen later from the dump without re-running the whole pipeline.

    It also returns `geoms`, the per-token geometry parallel to `passes`. The
    metric code below deliberately does not read it: keeping the (conf, text)
    contract byte-for-byte identical is what guarantees this change cannot move
    a single verdict, which in turn is what lets the already-eyeballed run-3
    shipped set serve as labelled ground truth when the height threshold is
    picked offline. Geometry is measurement only, until it is calibrated.
    """
    passes = []
    geoms = []
    w, g = ocr_words(path)
    passes.append(("orig", w))
    geoms.append(("orig", g))
    if OCR_UPSCALE > 1:
        big = workdir / ("up-" + path.stem + ".png")
        p = run([
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(path),
            "-vf", "scale=iw*%d:ih*%d:flags=lanczos" % (OCR_UPSCALE, OCR_UPSCALE),
            str(big),
        ])
        try:
            if p.returncode != 0:
                # A skipped OCR pass is indistinguishable from "this pass found no
                # text", which is exactly how the one safety filter turns into a
                # no-op. ocr_words() already makes a tesseract crash fatal for that
                # reason; the same reasoning applies to the ffmpeg that feeds it.
                # Until this fix the branch dropped the pass silently -- no log, no
                # counter, no effect on the run's exit status.
                raise RuntimeError(
                    "upscale pass failed on %s (ffmpeg rc=%d): %s"
                    % (path, p.returncode,
                       p.stdout.decode("utf-8", "replace")[-400:])
                )
            name = "up%dx" % OCR_UPSCALE
            w, g = ocr_words(big)
            passes.append((name, w))
            geoms.append((name, g))
        finally:
            # Was inside the success branch, so a partial PNG leaked on failure.
            big.unlink(missing_ok=True)
    if RAPIDOCR_ENABLE:
        # Detector-first second engine, on the original frame only: rapidocr
        # rescales internally as part of detection, so feeding it the 2x
        # upscale mostly buys runtime.
        w, g = rapid_words(path)
        passes.append(("rapid", w))
        geoms.append(("rapid", g))

    # rapidocr does not report the image size, but its boxes are in
    # original-frame pixels and the orig tesseract pass measured that exact
    # file, so its page box is reused rather than ffprobing 60 frames a theme.
    # Only the orig pass will do: up2x's page box is twice the size.
    ref_w = ref_h = 0
    for name, g in geoms:
        if name == "orig":
            t = next((t for t in g if t.get("img_h")), None)
            if t:
                ref_w, ref_h = t["img_w"], t["img_h"]
            break

    if not ref_h and OCR_UPSCALE > 1:
        # FALLBACK ADDED AFTER REVIEW. Previously only the orig pass would do, and
        # when it produced no alphanumeric tokens -- 24 of 621 frames in run 5 --
        # every rapidocr box kept img_h = 0, so _frac() returned 0.0 and the box was
        # dropped from BOTH union features. That happened on precisely the frames
        # where tesseract read nothing and rapidocr is therefore the only defence,
        # which is the worst possible place for a silent fail-open. up2x's page box
        # is a known multiple of the real one, so it converts exactly.
        for name, g in geoms:
            if name == "up%dx" % OCR_UPSCALE:
                t = next((t for t in g if t.get("img_h")), None)
                if t:
                    ref_w = t["img_w"] // OCR_UPSCALE
                    ref_h = t["img_h"] // OCR_UPSCALE
                break

    orphans = 0
    for name, g in geoms:
        if name != "rapid":
            continue
        for t in g:
            if not t.get("img_h"):
                if ref_h:
                    t["img_w"] = ref_w
                    t["img_h"] = ref_h
                else:
                    orphans += 1

    m = {"passes": passes, "geoms": geoms}
    # Detections whose geometry cannot be resolved by either route are UNMEASURED,
    # not clean. The cost asymmetry that settles every other threshold in this file
    # settles this one too: a missed leak makes a round unplayable, a lost clean
    # frame is one fewer out of ~50. ocr_risk() reads this and rejects.
    m["geom_unresolved"] = orphans > 0
    for floor in (0, 50, 60, 70, 80, 90):
        best_chars = 0
        best_word = 0
        for _, words in passes:
            kept = [(c, t) for c, t in words if c >= floor]
            chars = sum(len(t) for _, t in kept)
            longest = max([len(t) for _, t in kept], default=0)
            best_chars = max(best_chars, chars)
            best_word = max(best_word, longest)
        m["chars_%d" % floor] = best_chars
        m["longest_%d" % floor] = best_word
    all_confs = [c for _, words in passes for c, _ in words]
    m["max_conf"] = max(all_confs, default=0.0)
    m["words"] = sum(len(w) for _, w in passes)
    # Highest-confidence words first: this is what a human reads to judge
    # whether a rejection was real text or noise.
    top = sorted(((c, t) for _, words in passes for c, t in words),
                 key=lambda ct: -ct[0])[:6]
    m["sample"] = " ".join("%s(%d)" % (t, int(c)) for c, t in top)
    return m


def _ascii(s):
    """Escape a token to pure ASCII, and flatten anything that breaks a TSV.

    The dumps are read back on a cp1252 console, where merely *printing* a CJK
    character raises UnicodeEncodeError, and they are parsed by throwaway
    analysis scripts that should not each have to remember an encoding. Escaping
    at the point of writing removes the whole class of problem: the file is
    7-bit, so every reader is correct by default. Backslashes are doubled first
    so that a literal backslash in OCR output cannot be mistaken for an escape.
    """
    return (str(s)
            .replace("\\", "\\\\")
            .replace("\t", " ").replace("\r", " ").replace("\n", " ")
            .encode("ascii", "backslashreplace")
            .decode("ascii"))


# --------------------------------------------------------------------------
# Step 8b / 5.2.2: the union leak rule.
# --------------------------------------------------------------------------
# Ported verbatim from .tmp/tokens.py, where it was fitted and validated against
# 41 hand-labelled frames. "Verbatim" is a requirement, not a courtesy: the
# offline calibrator predicts what this pipeline will ship, and .tmp/cmp-sim.py
# gates every future run on prediction == reality. If the two implementations
# drift numerically, that gate silently stops meaning anything. So the maths
# below is a copy, and the only new code is the adapter that renames this file's
# token keys to the calibrator's.
#
# Fitted result on the labelled set: 4 of 4 known-bad rejected, 0 missed, 5 clean
# frames lost, worst-theme yield 33 candidates against a floor of 3.
_TOL = 0.25             # a cluster is heights within +/-25% of the cluster median
_MIN_SIZE = 3           # this many boxes before "consistent" means anything
_CONF_K = 2.0           # exponent on conf/100: soft, monotone, no cliff
_BASELINE_BONUS = 1.5   # multiplier when the cluster shares a tight baseline
_DUP_SIZE = 0.15        # cross-pass: heights and widths must agree this closely
_DUP_POS = 0.20         # cross-pass: tops must agree within this much of height


def _risk_tokens(metrics):
    """Flatten ocr_frame's per-pass geometry into the calibrator's schema.

    ocr_frame reports `geoms` as [(pass_name, [token])] and names the geometry
    keys h/w/top; the calibrator reads flat rows keyed h_px/w_px/top_px with the
    pass name on the row, because that is the shape of the TSV dump it was
    written against. The pass name MUST survive this flattening: cross-pass
    duplicate suppression is the difference between the highest-risk frame in the
    set being a real leak and it being a hallucinated glyph on a hair curve, and
    it decides sameness by comparing passes.
    """
    out = []
    for name, toks in metrics.get("geoms", []):
        for t in toks:
            out.append({
                "pass": name,
                "conf": float(t["conf"]),
                "h_px": float(t["h"]),
                "w_px": float(t["w"]),
                "top_px": float(t["top"]),
                "img_w": float(t["img_w"]),
                "img_h": float(t["img_h"]),
            })
    return out


def _frac(t, key="h_px"):
    """Box dimension as a fraction of its own image. Invariant to the 2x upscale
    pass: both the token box and the page box double, so the ratio does not."""
    if not t["img_h"]:
        return 0.0
    return t[key] / float(t["img_h"])


def _norm(t):
    """Box as (height, width, top) fractions of its own image.

    Each pass reports its own img_w/img_h -- up2x rows are twice the pixel size
    of orig rows for the same feature -- so every box must be normalised by the
    dimensions recorded on its own row before any two are compared.
    """
    ih = float(t["img_h"]) or 1.0
    iw = float(t["img_w"]) or 1.0
    return t["h_px"] / ih, t["w_px"] / iw, t["top_px"] / ih


def _same_box(a, b):
    """Do two boxes from DIFFERENT passes describe one image feature?"""
    if a["pass"] == b["pass"]:
        return False
    ha, wa, ta = _norm(a)
    hb, wb, tb = _norm(b)
    if ha <= 0 or hb <= 0:
        return False
    if abs(ha - hb) > _DUP_SIZE * max(ha, hb):
        return False
    if abs(wa - wb) > _DUP_SIZE * max(wa, wb, 1e-9):
        return False
    return abs(ta - tb) <= _DUP_POS * max(ha, hb)


def _dedupe(toks):
    """Drop boxes that a second pass found in the same place as a first.

    Up to three passes read the same image, so ONE feature can be reported three
    times. Counting those as independent corroboration is exactly what made a
    hallucinated pair of glyphs on a single hair curve the highest-risk frame in
    the whole set: its two boxes were one box, seen twice. Same-pass boxes are
    never merged -- two boxes from one pass really are two. The highest-confidence
    member survives, so what remains is the best reading of each feature.
    """
    out = []
    for t in sorted(toks, key=lambda x: -x["conf"]):
        if not any(_same_box(t, k) for k in out):
            out.append(t)
    return out


def _clusters(toks, min_conf, key="h_px", tol=_TOL):
    """Group confident tokens into candidate typographic clusters by height.

    Seeded from every token, then re-centred on the group median so the result
    does not depend on which token happened to be first. Deduplicated by
    membership, so N tokens of one size yield one cluster rather than N.
    """
    toks = _dedupe(toks)
    idx = [(i, t) for i, t in enumerate(toks)
           if t["conf"] >= min_conf and _frac(t, key) > 0.0]
    out, seen = [], set()
    for _, seed in idx:
        h0 = _frac(seed, key)
        near = [(i, t) for i, t in idx if abs(_frac(t, key) - h0) <= tol * h0]
        med = statistics.median([_frac(t, key) for _, t in near])
        grp = [(i, t) for i, t in idx if abs(_frac(t, key) - med) <= tol * med]
        sig = tuple(i for i, _ in grp)
        if sig in seen:
            continue
        seen.add(sig)
        out.append([t for _, t in grp])
    return out


def _coherence(toks, min_conf, key="h_px"):
    """Risk that this frame carries rendered title/name text.

        risk = median_height * sqrt(cluster_size) * median_conf_weight

    sqrt, not linear, on size: going from 1 box to 4 is most of the evidence,
    4 to 16 adds little. A tight shared baseline multiplies the result, because
    that is the signature of a single run of set type rather than a coincidence
    of similarly-sized noise. Confidence enters as a continuous weight and never
    as a second hard floor -- both floor experiments failed as cliff artifacts.
    """
    best = 0.0
    for grp in _clusters(toks, min_conf, key):
        # _MIN_SIZE applies uniformly. Relaxing it to 2 for large type was tried
        # and abandoned: it readmitted a hair-curve pair and made that CLEAN
        # frame the highest-scoring frame in the set. Two boxes are not a
        # corroborated typeface at any size.
        if len(grp) < _MIN_SIZE:
            continue
        med_h = statistics.median([_frac(t, key) for t in grp])
        w = statistics.median([(t["conf"] / 100.0) ** _CONF_K for t in grp])
        risk = med_h * math.sqrt(len(grp)) * w
        # grp[0], not toks[0]. The baseline bonus is a property of THIS cluster, but
        # the guard used to read the first token of the whole frame -- which need not
        # be in the cluster at all. When that unrelated token had no page box, the
        # 1.5x bonus was skipped for every cluster in the frame even though each
        # member had valid dimensions: an under-rejection, the unsafe direction.
        # Latent rather than firing on run-5 data (only 5 tokens of 16,038 lacked
        # img_h), and faithfully ported from the offline calibrator, defect included.
        if grp[0]["img_h"]:
            tops = [t["top_px"] / float(t["img_h"]) for t in grp]
            if statistics.pstdev(tops) < med_h:
                risk *= _BASELINE_BONUS
        if risk > best:
            best = risk
    return best


def _bigcount(toks, key="h_px"):
    """How many large, deduped boxes the frame has -- with NO confidence floor.

    Coherence is structurally blind to a stylised logo: the engine does not read
    it, so every box is low-confidence and the conf weight drives risk to zero.
    AnsatsuKyoushitsu-OP1 79.5 is the proof -- a confirmed leak whose five boxes
    top out at conf 58.6, which every confidence-weighted feature scores 0.0000.

    What that frame does have is large boxes. A stylised title gets segmented
    into big glyph-like regions and then misread; noise -- a hair curve, a blur
    streak, window mullions -- yields one or two at most, or none. So this counts
    large boxes and ignores confidence entirely: a segmentation signal, not a
    reading.
    """
    return float(sum(1 for t in _dedupe(toks) if _frac(t, key) >= OCR_BIG_MIN_H))


def ocr_risk(metrics):
    """Union of the two features, normalised so 1.0 is the reject line.

    Each feature is divided by its own threshold and the worse of the two wins,
    which turns a two-threshold rule into one scalar that the filter, the
    selector, the telemetry and the offline calibrator all consume unchanged.
    """
    # Unmeasurable is not clean. If a detection survived with no resolvable page box
    # (see the backfill in ocr_frame), both features would silently score it 0.0 --
    # a frame the engines DID see text on, scoring as if they had seen nothing.
    # Rejecting costs at most a handful of frames per run; the alternative is the
    # exact fail-open this rule exists to prevent.
    if metrics.get("geom_unresolved"):
        return 1.0

    toks = _risk_tokens(metrics)
    if not toks:
        return 0.0
    a = _coherence(toks, OCR_MIN_CONF) / OCR_COH_T
    b = _bigcount(toks) / OCR_BIG_T
    return max(a, b)


def text_filter(cands, workdir, outdir, stem):
    """Split candidates into (clean, text-positive).

    A frame is rejected if EITHER rule fires:

      1. `longest single word at or above OCR_MIN_CONF >= OCR_MIN_WORD`,
         worst case across every OCR pass. See the OCR_MIN_WORD comment at the
         top of this file for the 647-frame measurement behind it.
      2. `ocr_risk(...) >= 1.0` -- the geometric union rule. See the OCR_COH_T
         comment for why rule 1 alone shipped two confirmed leaks.

    Rule 2 is strictly additional: it can only reject frames, never readmit one
    that rule 1 caught. Every frame it rejects joins `texty`, which is also the
    poster pool -- and that is the desired outcome, because a frame the union rule
    rejects is by construction a frame carrying large or well-set type, which is
    exactly what a poster wants.

    Every threshold stays configurable from the workflow because B-28's fallback
    ladder is operated through them.
    """
    clean, texty = [], []
    rows = []
    union_only = 0
    for c in cands:
        m = ocr_frame(c["path"], workdir)
        chars = 0
        longest = 0
        culprit = ""
        for name, words in m["passes"]:
            kept = [(conf, t) for conf, t in words if conf >= OCR_MIN_CONF]
            chars = max(chars, sum(len(t) for _, t in kept))
            for conf, t in kept:
                if len(t) > longest:
                    longest = len(t)
                    # Which engine and which word triggered it. Without this,
                    # a run cannot answer "is the second engine earning its
                    # runtime, or is tesseract catching everything anyway?"
                    culprit = "%s:%s(%d)" % (name, t, int(conf))
        risk = ocr_risk(m)
        wordy = longest >= OCR_MIN_WORD
        risky = risk >= 1.0
        c["ocr_chars"] = chars
        c["ocr_longest"] = longest
        c["ocr_culprit"] = culprit
        c["ocr_max_conf"] = round(m["max_conf"], 1)
        c["ocr_sample"] = m["sample"]
        c["ocr_metrics"] = m
        # Set unconditionally, on every candidate, including rejected ones. The
        # selector indexes this key directly rather than defaulting a missing one
        # to zero: a lookup miss must never render as "no text detected", which
        # is the failure mode that made the calibrator's own audit report a clean
        # sweep on stale labels.
        c["ocr_risk"] = risk
        if risky and not wordy:
            union_only += 1
        (texty if (wordy or risky) else clean).append(c)
        rows.append((c, m, chars, longest, culprit))

    if OCR_DUMP:
        dump = outdir / ("ocr-" + stem + ".tsv")
        with io.open(dump, "w", encoding="utf-8", newline="\n") as f:
            # `verdict` keeps its original meaning: the decision that actually
            # shipped. `reason` and `risk` are additions, not a redefinition --
            # collapsing two rules into one label would throw away which rule
            # fired, which is the only thing that makes a rejection re-analysable
            # offline. Safe to extend because every reader parses by header name.
            cols = ["index", "ts", "bytes", "verdict", "reason", "risk",
                    "longest_at_min_conf",
                    "chars_at_min_conf", "culprit", "max_conf", "words"]
            cols += ["chars_%d" % n for n in (0, 50, 60, 70, 80, 90)]
            cols += ["longest_%d" % n for n in (0, 50, 60, 70, 80, 90)]
            cols += ["top_words"]
            f.write("\t".join(cols) + "\n")
            for c, m, chars, longest, culprit in rows:
                wordy = longest >= OCR_MIN_WORD
                risky = c["ocr_risk"] >= 1.0
                reason = "-"
                if wordy and risky:
                    reason = "both"
                elif wordy:
                    reason = "word"
                elif risky:
                    reason = "union"
                vals = [c["index"], "%.1f" % c["ts"], c["bytes"],
                        "TEXTY" if (wordy or risky) else "CLEAN",
                        reason, "%.4f" % c["ocr_risk"],
                        longest, chars, culprit or "-",
                        "%.1f" % m["max_conf"], m["words"]]
                vals += [m["chars_%d" % n] for n in (0, 50, 60, 70, 80, 90)]
                vals += [m["longest_%d" % n] for n in (0, 50, 60, 70, 80, 90)]
                vals += [m["sample"].replace("\t", " ")]
                f.write("\t".join(str(v).replace("\t", " ") for v in vals) + "\n")
        log("  ocr dump: %s" % dump.name)

        # Second dump: one row per token per pass, with geometry. This is the
        # whole point of the next run. B-28 showed that no scalar currently
        # recorded separates the three-frame counterexample set, so the next
        # threshold has to be chosen against real per-token data. Dumping it
        # costs nothing (~26k rows for 12 themes) and it is the difference
        # between calibrating offline and burning a 20-minute CI run per guess.
        #
        # Written as ASCII with an ASCII codec, not UTF-8: if a token ever
        # escapes _ascii() the write should fail loudly here rather than produce
        # a file that silently mis-decodes in three tools downstream.
        tdump = outdir / ("tokens-" + stem + ".tsv")
        ntok = 0
        with io.open(tdump, "w", encoding="ascii", newline="\n") as f:
            cols = ["ts", "verdict", "pass", "conf", "h_px", "hrot_px", "w_px",
                    "top_px", "img_w", "img_h", "line_ntok", "len", "text",
                    "raw"]
            f.write("\t".join(cols) + "\n")
            for c, m, chars, longest, culprit in rows:
                # Same convention as the frame dump: the decision that shipped.
                verdict = "TEXTY" if (longest >= OCR_MIN_WORD
                                      or c["ocr_risk"] >= 1.0) else "CLEAN"
                for name, toks in m.get("geoms", []):
                    for t in toks:
                        vals = ["%.1f" % c["ts"], verdict, name,
                                "%.1f" % t["conf"],
                                t["h"], t["hrot"], t["w"], t["top"],
                                t["img_w"], t["img_h"], t["ntok"],
                                len(t["text"]),
                                _ascii(t["text"]), _ascii(t["raw"])]
                        if len(vals) != len(cols):
                            raise RuntimeError(
                                "token dump column drift: %d vals vs %d cols"
                                % (len(vals), len(cols)))
                        f.write("\t".join(str(v) for v in vals) + "\n")
                        ntok += 1
        log("  token dump: %s (%d tokens)" % (tdump.name, ntok))

    log("  ocr: clean=%d text-positive=%d (word>=%d at conf>=%g, psm=%s, langs=%s)"
        % (len(clean), len(texty), OCR_MIN_WORD, OCR_MIN_CONF,
           OCR_PSM, OCR_LANGS))
    # The only number that says whether the union rule is still earning its
    # place, or whether the word rule has quietly started catching everything.
    log("  ocr union: %d rejected by geometry alone (coh_t=%g big_t=%g min_h=%g)"
        % (union_only, OCR_COH_T, OCR_BIG_T, OCR_BIG_MIN_H))
    return clean, texty, union_only


# --------------------------------------------------------------------------
# Step 9 / 5.2.3: spread -- best frame from each third.
# --------------------------------------------------------------------------
# The stated purpose is that the three stills come from different moments, so
# the progressive reveal adds genuinely new information rather than three near
# duplicates of one shot.
#
# 5.2.3 says "three equal spans by timestamp". This splits the SURVIVOR list
# into three equal-count contiguous groups instead, which serves that purpose
# strictly better: equal timestamp spans can come back empty when survivors
# cluster (a sequence whose middle third is all flat pans), yielding one still
# for a theme that had plenty of usable frames -- and still_count must be 2 or
# 3, never 1. Equal-count groups over survivors that were themselves drawn
# evenly across the whole sequence always yield 2 or 3, always in time order.
def spread(clean):
    ordered = sorted(clean, key=lambda c: c["index"])
    n = len(ordered)
    if n < 2:
        return []
    groups = 3 if n >= 3 else 2
    chosen = []
    for g in range(groups):
        lo = (n * g) // groups
        hi = (n * (g + 1)) // groups
        band = ordered[lo:hi]
        if band:
            # File size stays the primary signal -- it is a proxy for visual
            # detail, and ranking bands by risk instead was measured and rejected
            # (18 bands reshuffled, 17 extra unverified frames, worst band down to
            # 55% of its detail, and zero known-bad frames avoided). Sub-threshold
            # risk has no demonstrated relationship to leakage, so it does not get
            # to choose.
            #
            # It does get a veto. A frame that survived the filter but sits close
            # to it must not win a band while a quieter alternative exists in the
            # same third. Cost on the 12 calibration themes is exactly zero picks
            # changed; three survivors elsewhere sit at 0.90-0.997 and would ship
            # the moment one of them happened to be the biggest in its band.
            #
            # `c["ocr_risk"]` is indexed, never .get() with a default: text_filter
            # sets it on every candidate it returns, so a KeyError here means the
            # contract broke and should fail loudly rather than silently treat an
            # unscored frame as clean.
            quiet = [c for c in band if c["ocr_risk"] < OCR_QUIET_T]
            chosen.append(max(quiet or band, key=lambda c: c["bytes"]))
    # Guard against a degenerate band collision rather than trusting the maths.
    seen, uniq = set(), []
    for c in chosen:
        if c["index"] not in seen:
            seen.add(c["index"])
            uniq.append(c)
    return sorted(uniq, key=lambda c: c["index"])[:3]


# --------------------------------------------------------------------------
# Step 10: the poster, taken from the frames rejected for containing text.
# --------------------------------------------------------------------------
# The title card is a liability during play and the ideal image on reveal, and
# step 8 has already identified it. Highest detail among the text-positive
# frames is the most likely full card rather than a stray subtitle.
#
# The poster is mandatory: question_asset_keys always names posters/{slug}.jpg
# and the reveal expects it. Hence the fallback ladder.
def pick_poster(texty, clean, chosen):
    if texty:
        return max(texty, key=lambda c: c["bytes"]), "text-positive"
    used = {c["index"] for c in chosen}
    spare = [c for c in clean if c["index"] not in used]
    if spare:
        return max(spare, key=lambda c: c["bytes"]), "fallback-clean-unused"
    if chosen:
        return max(chosen, key=lambda c: c["bytes"]), "fallback-reused-still"
    return None, "none"


def encode_delivery(src_jpg, dest):
    """Recompress a cleared candidate to delivery quality.

    Safe with respect to the module docstring's invariant: this preserves the
    pixels OCR approved. It is re-EXTRACTING from the video that is forbidden.
    """
    must([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src_jpg), "-map_metadata", "-1",
        "-q:v", DELIVER_QUALITY, str(dest),
    ], "deliver encode %s" % dest.name)
    return dest.stat().st_size


# --------------------------------------------------------------------------
# Upload and ingest.
# --------------------------------------------------------------------------
def http(method, url, body, headers, timeout=300):
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def upload(key, path, content_type):
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise RuntimeError(
            "%s is %d bytes, over the bucket limit of %d" % (key, size, MAX_BYTES)
        )
    with open(path, "rb") as fh:
        body = fh.read()
    # x-upsert so a retried batch overwrites the same key instead of 409-ing.
    status, resp = http(
        "POST",
        "%s/storage/v1/object/%s/%s" % (SUPABASE_URL, BUCKET, key),
        body,
        {
            "Authorization": "Bearer " + SERVICE_KEY,
            "apikey": SERVICE_KEY,
            "Content-Type": content_type,
            "x-upsert": "true",
        },
    )
    if status != 200:
        raise RuntimeError(
            "upload %s -> HTTP %d %s"
            % (key, status, resp[:300].decode("utf-8", "replace"))
        )
    return size


def ingest(payload):
    # Wrapped in {"p_payload": ...}, NOT posted bare.
    #
    # PostgREST maps the top-level keys of an RPC body to NAMED function arguments,
    # so posting the payload bare made it look for a 22-argument ingest_question and
    # fail with PGRST202 -- "Searched for the function public.ingest_question with
    # parameters anime_format, anime_season, ... or with a single unnamed json/jsonb
    # parameter". The function takes one argument, p_payload jsonb, so the body has
    # to name it. (An unnamed single jsonb parameter would also have worked, but the
    # SQL is applied and verified; the client is the side that was wrong.)
    #
    # This is the first thing that broke when the HTTP path finally ran: every prior
    # test of ingest_question went through SQL, where the argument is positional and
    # this class of mistake cannot exist.
    status, resp = http(
        "POST",
        "%s/rest/v1/rpc/ingest_question" % SUPABASE_URL,
        json.dumps({"p_payload": payload}).encode("utf-8"),
        {
            "Authorization": "Bearer " + SERVICE_KEY,
            "apikey": SERVICE_KEY,
            "Content-Type": "application/json",
        },
    )
    text = resp.decode("utf-8", "replace")
    if status != 200:
        raise RuntimeError("ingest_question -> HTTP %d %s" % (status, text[:400]))
    return json.loads(text)


def process(job, result):
    basename = job["basename"]
    stem = result["stem"]
    link = job.get("link") or ("https://v.animethemes.moe/" + basename)

    work = Path(os.environ.get("WORKDIR", "work")) / stem
    if work.exists():
        shutil.rmtree(work)
    cand_dir = work / "cand"
    cand_dir.mkdir(parents=True)
    out_dir = Path(os.environ.get("OUTDIR", "out"))
    for sub in ("stills", "posters", "audio", "rejected"):
        (out_dir / sub).mkdir(parents=True, exist_ok=True)

    still_slug = result["asset_slug"]
    poster_slug = result["poster_slug"]
    audio_slug = result["audio_slug"]

    src = work / "src.webm"
    src_bytes = download(link, src)
    duration = probe_duration(src)
    log("  source: %.1f MB, %.1fs" % (src_bytes / 1048576.0, duration))
    result["source_bytes"] = src_bytes
    result["source_seconds"] = round(duration, 1)

    audio_path = work / "audio.webm"
    audio_seconds, audio_bytes = extract_audio(src, audio_path, duration)

    cands = extract_candidates(src, cand_dir, duration)
    log("  candidates: %d" % len(cands))
    if not cands:
        raise RuntimeError("no candidate frames produced")

    kept, dropped, median = detail_filter(cands)
    clean, texty, union_only = text_filter(kept, work, out_dir, stem)
    chosen = spread(clean)

    result["candidates"] = len(cands)
    result["detail_median"] = int(median)
    result["detail_dropped"] = len(dropped)
    result["ocr_clean"] = len(clean)
    result["ocr_texty"] = len(texty)
    # Per-theme, so a future run can tell whether the union rule is carrying a
    # particular sequence or is inert on it. A theme-level zero across all 134
    # would be the signal to reconsider the rule; a zero on one theme means
    # nothing.
    result["ocr_union_only"] = union_only

    # Fewer than 2 clean stills means skip the theme. Do NOT degrade to one:
    # still_count is CHECKed 2..3 and a single-image round is not guessable.
    if len(chosen) < 2:
        result["status"] = "SKIP"
        result["note"] = "only %d clean still(s) after filters" % len(chosen)
        log("  SKIP: " + result["note"])
        return

    poster, poster_src = pick_poster(texty, clean, chosen)
    if poster is None:
        result["note"] = "no poster candidate"
        raise RuntimeError(result["note"])
    result["poster_source"] = poster_src

    # Deliverables. Named readably on disk so a human inspecting the artifact
    # can tell which anime a leaked title belongs to; the BUCKET keys use the
    # unguessable per-class slug form built from question_asset_keys'
    # convention, and share no common substring with each other.
    still_paths, still_bytes = [], []
    for n, c in enumerate(chosen, start=1):
        dest = out_dir / "stills" / ("%s-still%d.jpg" % (stem, n))
        still_bytes.append(encode_delivery(c["path"], dest))
        still_paths.append(dest)
    poster_path = out_dir / "posters" / ("%s-poster.jpg" % stem)
    poster_bytes = encode_delivery(poster["path"], poster_path)

    audio_out = out_dir / "audio" / ("%s.webm" % stem)
    shutil.copyfile(audio_path, audio_out)

    # Text-positive frames are kept in the artifact as the evidence for B-28.
    # A green run proves nothing on its own: these are what show whether OCR
    # actually caught the title cards (true positives) rather than merely not
    # crashing.
    for c in texty[:12]:
        shutil.copyfile(
            c["path"],
            out_dir / "rejected" / ("%s-t%03d-w%02d.jpg"
                                    % (stem, c["index"], c["ocr_longest"])),
        )

    bytes_total = audio_bytes + sum(still_bytes) + poster_bytes
    result.update({
        "still_count": len(chosen),
        "audio_seconds": int(round(audio_seconds)),
        "audio_bytes": audio_bytes,
        "still_bytes": still_bytes,
        "poster_bytes": poster_bytes,
        "bytes_total": bytes_total,
        "still_ts": [round(c["ts"], 1) for c in chosen],
        "poster_ts": round(poster["ts"], 1),
        "poster_ocr_chars": poster.get("ocr_chars", 0),
        "poster_ocr_longest": poster.get("ocr_longest", 0),
        "poster_ocr_culprit": poster.get("ocr_culprit", ""),
    })
    log("  chosen: %d stills at %s s, poster at %.1fs (%s), total %.1f KB"
        % (len(chosen), result["still_ts"], poster["ts"], poster_src,
           bytes_total / 1024.0))

    if DRY_RUN:
        result["status"] = "DRY"
        result["note"] = "not uploaded"
        return

    if not SUPABASE_URL or not SERVICE_KEY:
        raise RuntimeError("SUPABASE_URL / SERVICE_KEY missing on a non-dry run")

    # Objects first, always. A row pointing at bytes that never arrived is
    # worse than an orphaned upload, and with five objects that window is five
    # times wider. Keys follow question_asset_keys(still, poster, audio, count):
    #   stills/{still_slug}-{n}.jpg  posters/{poster_slug}.jpg
    #   audio/{audio_slug}.webm
    # Three unrelated roots: no key here can be edited into any other key, so
    # holding a still reveals nothing about where the poster or audio lives.
    uploaded = 0
    uploaded += upload("audio/%s.webm" % audio_slug, audio_out, "audio/webm")
    for n, path in enumerate(still_paths, start=1):
        uploaded += upload("stills/%s-%d.jpg" % (still_slug, n), path, "image/jpeg")
    uploaded += upload("posters/%s.jpg" % poster_slug, poster_path, "image/jpeg")
    log("  uploaded %d objects, %.1f KB" % (2 + len(still_paths), uploaded / 1024.0))

    payload = {
        "asset_slug": still_slug,
        "poster_slug": poster_slug,
        "audio_slug": audio_slug,
        "still_count": len(chosen),
        "audio_seconds": int(round(audio_seconds)),
        "bytes_total": bytes_total,
        "animethemes_video_id": None,
        "animethemes_theme_id": None,
        "anime_slug": job["anime_slug"],
        "titles": job["titles"],
        "synonyms": job.get("synonyms") or [],
        "anime_year": job["anime_year"],
        "anime_season": job.get("anime_season"),
        "anime_format": job["anime_format"],
        "theme_type": job["theme_type"],
        "theme_sequence": job.get("theme_sequence"),
        "difficulty": job["difficulty"],
        # Forwarded from the API, never asserted. question_bank's
        # credit_free_only / not_subbed / sfw_only CHECKs exist to stop an
        # unsafe asset even from a buggy ingest run; substituting literals here
        # would leave those constraints validating a constant.
        "nc": job["nc"],
        "subbed": job["subbed"],
        "overlap": job.get("overlap"),
        "spoiler": job["spoiler"],
        "nsfw": job["nsfw"],
    }
    row_id = ingest(payload)
    # id and the three asset slugs are four different uuids ON PURPOSE
    # (migrations 0010, 0011): id is client-readable via rounds.question_id --
    # create_room pre-inserts every round, so every room member can read every
    # question_id in the room from the first second. The slugs are not readable
    # that way. They are not meant to agree with id or with each other, so this
    # is logged, never compared.
    result["question_id"] = row_id
    result["status"] = "OK"
    log("  ingested row %s" % row_id)


def main():
    # Decode stdin as UTF-8 explicitly rather than through the locale. Every job line
    # carries titles.native in CJK, and the workflow sets no LANG, LC_ALL, PYTHONUTF8
    # or PYTHONIOENCODING -- this works today only because GitHub's ubuntu-latest
    # image happens to set LANG=C.UTF-8. One runner-image change away, json.load(
    # sys.stdin) would raise UnicodeDecodeError on every theme in the batch. The
    # module docstring already cites an encoding fault that corrupted titles once,
    # and build-manifest.ps1 defends the PowerShell side of the same boundary.
    job = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    basename = job.get("basename") or "?"
    stem = basename[:-5] if basename.endswith(".webm") else basename

    # THREE independent random slugs, one per asset class -- never derived from
    # anything public and never derived from each other (migration 0011).
    #
    # Not derived from public data: basename IS public AnimeThemes data, so a
    # derived slug (md5(basename), as the old video pipeline did for its id)
    # could be recomputed for every title in the pool -- and the bucket is
    # public-read, so a player could prefetch all content and reverse-image
    # match whatever still appears.
    #
    # Not derived from each other: under the single-slug layout of 0010, a
    # player holding stills/{slug}-1.jpg could edit that one string into
    # posters/{slug}.jpg, and the poster is deliberately the title card -- the
    # answer. Reads on a public bucket are by key and bypass RLS entirely
    # (measured: dropping the storage policy left GETs returning 200 and only
    # stopped listing), so key unguessability is the whole protection. Three
    # unrelated 122-bit roots make each asset class its own separate secret.
    #
    # Idempotency across retries comes from the workflow skipping themes already
    # present in question_bank, not from making any slug predictable.
    result = {
        "basename": basename, "stem": stem,
        "asset_slug": str(uuid.uuid4()),
        "poster_slug": str(uuid.uuid4()),
        "audio_slug": str(uuid.uuid4()),
        "status": "FAIL", "note": "", "still_count": 0,
        "audio_seconds": 0, "bytes_total": 0,
    }

    # One bad theme must not abort the batch: the failure is recorded in the
    # result row and the workflow keeps going. Exit code is still non-zero so a
    # caller that cares can tell.
    try:
        process(job, result)
    except Exception as exc:
        result["status"] = "FAIL"
        result["note"] = str(exc).replace("\n", " ")[:300]
        log("  ERROR: %s" % exc)
        print(json.dumps(result))
        return 1

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
