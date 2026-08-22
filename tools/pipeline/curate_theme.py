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
OCR_MIN_CHARS = int(os.environ.get("OCR_MIN_CHARS", "1"))  # >= this many chars rejects a frame
OCR_MIN_CONF = float(os.environ.get("OCR_MIN_CONF", "0"))  # ignore words below this confidence
OCR_PSM = os.environ.get("OCR_PSM", "11")
OCR_LANGS = os.environ.get("OCR_LANGS", "eng+jpn+jpn_vert")
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
    """OCR one image, returning [(confidence, alnum_text), ...] per word.

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
    for line in p.stdout.decode("utf-8", "replace").splitlines()[1:]:
        col = line.split("\t")
        if len(col) < 12:
            continue
        try:
            conf = float(col[10])
        except ValueError:
            continue
        if conf < 0:            # -1 marks layout rows that carry no word
            continue
        alnum = "".join(ch for ch in col[11] if ch.isalnum())
        if alnum:
            words.append((conf, alnum))
    return words


def ocr_frame(path, workdir):
    """Both OCR passes for one frame, merged into one measurement.

    The second pass on a 2x lanczos upscale is kept because small or thin title
    text can be unreadable at 854px and readable at 1708px. Passes are merged by
    taking the worst case per metric: if either pass sees high-confidence text,
    the frame is text-positive. That preserves the asymmetry -- a false positive
    costs one frame out of sixty, a false negative ships the answer.

    Returns a dict of metrics at several confidence floors, so a threshold can
    be chosen later from the dump without re-running the whole pipeline.
    """
    passes = [("orig", ocr_words(path))]
    if OCR_UPSCALE > 1:
        big = workdir / ("up-" + path.stem + ".png")
        p = run([
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(path),
            "-vf", "scale=iw*%d:ih*%d:flags=lanczos" % (OCR_UPSCALE, OCR_UPSCALE),
            str(big),
        ])
        if p.returncode == 0:
            passes.append(("up%dx" % OCR_UPSCALE, ocr_words(big)))
            big.unlink(missing_ok=True)

    m = {"passes": passes}
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


def text_filter(cands, workdir, outdir, stem):
    """Split candidates into (clean, text-positive).

    The rejection rule is `chars at or above OCR_MIN_CONF >= OCR_MIN_CHARS`.
    Both halves are configurable from the workflow because B-28's fallback
    ladder is operated through them, and because the first measured run proved
    the original rule (any single character at any confidence) rejected
    essentially every frame.
    """
    clean, texty = [], []
    rows = []
    for c in cands:
        m = ocr_frame(c["path"], workdir)
        chars = 0
        for _, words in m["passes"]:
            chars = max(chars, sum(len(t) for conf, t in words
                                   if conf >= OCR_MIN_CONF))
        c["ocr_chars"] = chars
        c["ocr_max_conf"] = round(m["max_conf"], 1)
        c["ocr_sample"] = m["sample"]
        c["ocr_metrics"] = m
        (texty if chars >= OCR_MIN_CHARS else clean).append(c)
        rows.append((c, m, chars))

    if OCR_DUMP:
        dump = outdir / ("ocr-" + stem + ".tsv")
        with io.open(dump, "w", encoding="utf-8", newline="\n") as f:
            cols = ["index", "ts", "bytes", "verdict", "chars_at_min_conf",
                    "max_conf", "words"]
            cols += ["chars_%d" % n for n in (0, 50, 60, 70, 80, 90)]
            cols += ["longest_%d" % n for n in (0, 50, 60, 70, 80, 90)]
            cols += ["top_words"]
            f.write("\t".join(cols) + "\n")
            for c, m, chars in rows:
                vals = [c["index"], "%.1f" % c["ts"], c["bytes"],
                        "TEXTY" if chars >= OCR_MIN_CHARS else "CLEAN",
                        chars, "%.1f" % m["max_conf"], m["words"]]
                vals += [m["chars_%d" % n] for n in (0, 50, 60, 70, 80, 90)]
                vals += [m["longest_%d" % n] for n in (0, 50, 60, 70, 80, 90)]
                vals += [m["sample"].replace("\t", " ")]
                f.write("\t".join(str(v) for v in vals) + "\n")
        log("  ocr dump: %s" % dump.name)

    log("  ocr: clean=%d text-positive=%d (>=%d chars at conf>=%g, psm=%s, langs=%s)"
        % (len(clean), len(texty), OCR_MIN_CHARS, OCR_MIN_CONF,
           OCR_PSM, OCR_LANGS))
    return clean, texty


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
            chosen.append(max(band, key=lambda c: c["bytes"]))
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
    status, resp = http(
        "POST",
        "%s/rest/v1/rpc/ingest_question" % SUPABASE_URL,
        json.dumps(payload).encode("utf-8"),
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

    slug = result["asset_slug"]

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
    clean, texty = text_filter(kept, work, out_dir, stem)
    chosen = spread(clean)

    result["candidates"] = len(cands)
    result["detail_median"] = int(median)
    result["detail_dropped"] = len(dropped)
    result["ocr_clean"] = len(clean)
    result["ocr_texty"] = len(texty)

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
    # can tell which anime a leaked title belongs to; the BUCKET keys are the
    # unguessable slug form and are built only from question_asset_keys'
    # convention.
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
            out_dir / "rejected" / ("%s-t%03d-%dch.jpg"
                                    % (stem, c["index"], c["ocr_chars"])),
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
    # times wider. Keys follow question_asset_keys(asset_slug, still_count):
    #   audio/{slug}.webm  stills/{slug}-{n}.jpg  posters/{slug}.jpg
    uploaded = 0
    uploaded += upload("audio/%s.webm" % slug, audio_out, "audio/webm")
    for n, path in enumerate(still_paths, start=1):
        uploaded += upload("stills/%s-%d.jpg" % (slug, n), path, "image/jpeg")
    uploaded += upload("posters/%s.jpg" % slug, poster_path, "image/jpeg")
    log("  uploaded %d objects, %.1f KB" % (2 + len(still_paths), uploaded / 1024.0))

    payload = {
        "asset_slug": slug,
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
    # id and asset_slug are two different uuids ON PURPOSE (migration 0010):
    # id is client-readable via rounds.question_id, asset_slug is not. They are
    # not meant to agree, so this is logged, never compared.
    result["question_id"] = row_id
    result["status"] = "OK"
    log("  ingested row %s" % row_id)


def main():
    job = json.load(sys.stdin)
    basename = job.get("basename") or "?"
    stem = basename[:-5] if basename.endswith(".webm") else basename

    # A fresh random slug, never derived from anything public. basename IS
    # public AnimeThemes data, so a derived slug (md5(basename), as the old
    # video pipeline did for its id) could be recomputed for every title in the
    # pool -- and the bucket is public-read, so a player could prefetch all
    # content and reverse-image-match whatever still appears. Idempotency
    # across retries comes from the workflow skipping themes already present in
    # question_bank, not from making the slug predictable.
    result = {
        "basename": basename, "stem": stem, "asset_slug": str(uuid.uuid4()),
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
