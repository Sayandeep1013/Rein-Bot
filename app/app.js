/* ReIN Bot -- client.
 *
 * No framework, no build step, no bundler, and deliberately no supabase-js: the
 * transport is one polled RPC plus plain REST, which fetch() covers, so the page has
 * zero third-party runtime dependencies and nothing to break when a CDN does.
 *
 * TRUST MODEL, in one paragraph, because it explains most of the odd choices below.
 * This client is not trusted with anything. It never sees an answer -- grade_guess
 * returns a verdict, get_room_state returns the reveal only for rounds whose ends_at
 * has already passed, and the poster (which is the title card by design) is withheld
 * during play. It is not trusted with the clock either: every deadline is server-side
 * and the countdown runs off an offset measured against server_now, because a browser
 * clock can be minutes out. It is not trusted with scoring: points are summed inside
 * the database. If this file were rewritten by a player, the worst they could do is
 * make their own UI lie to them.
 */
(function () {
  "use strict";

  // ---------------------------------------------------------------- config
  var CFG = window.REIN_CONFIG || {};
  var URL_BASE = (CFG.SUPABASE_URL || "").replace(/\/+$/, "");
  var ANON = CFG.SUPABASE_ANON_KEY || "";
  var POLL_MS = 1500;
  var LS_TOKEN = "rein.session";
  var LS_ROOM = "rein.room";
  var LS_NAME = "rein.name";

  // ---------------------------------------------------------------- dom
  function $(id) { return document.getElementById(id); }
  function show(id) {
    var all = document.querySelectorAll(".screen");
    for (var i = 0; i < all.length; i++) all[i].classList.remove("active");
    $(id).classList.add("active");
  }
  function text(el, s) { el.textContent = s == null ? "" : String(s); }
  function on(el, ev, fn) { el.addEventListener(ev, fn); }

  function fatal(msg, helpHtml) {
    text($("fatal-msg"), msg);
    $("fatal-help").innerHTML = helpHtml || "";
    show("scr-fatal");
    stopPolling();
  }

  // ---------------------------------------------------------------- state
  var session = null;      // { access_token, refresh_token, expires_at }
  var clockSkew = 0;       // serverNow - clientNow, in ms
  var roomId = null;
  var last = null;         // last get_room_state payload
  var pollTimer = null;
  var tickTimer = null;
  var advancedFor = null;  // deadline value we have already tried to advance past
  var shownStills = 0;
  var audioEl = null;
  var audioKeyPlaying = null;
  var overSince = 0;
  var myGuesses = [];

  function serverNow() { return Date.now() + clockSkew; }

  // ---------------------------------------------------------------- http
  function req(path, opts) {
    opts = opts || {};
    // apikey identifies the project; Authorization carries the SESSION, and is sent
    // only when there is one. The obvious-looking fallback of putting the publishable
    // key in Authorization is wrong for the `sb_publishable_` format, which is not a
    // JWT -- and it is unnecessary in either format, because the pre-auth role has no
    // grant on anything here. The only call made before sign-in is /auth/v1/signup,
    // which authenticates on apikey alone.
    var headers = { apikey: ANON, "Content-Type": "application/json" };
    if (opts.auth !== false && session && session.access_token) {
      headers.Authorization = "Bearer " + session.access_token;
    }
    return fetch(URL_BASE + path, {
      method: opts.method || "POST",
      headers: headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    }).then(function (r) {
      return r.text().then(function (t) {
        var j = null;
        try { j = t ? JSON.parse(t) : null; } catch (e) { j = null; }
        if (!r.ok) {
          var e2 = new Error((j && (j.message || j.error_description || j.error)) || t || ("HTTP " + r.status));
          e2.status = r.status;
          e2.payload = j;
          throw e2;
        }
        return j;
      });
    });
  }

  // PostgREST surfaces `raise exception 'ROOM_FULL'` as message "ROOM_FULL". The
  // functions raise bare uppercase codes on purpose so this mapping stays trivial.
  function rpc(name, args) {
    return req("/rest/v1/rpc/" + name, { body: args || {} });
  }

  function assetUrl(key) {
    return URL_BASE + "/storage/v1/object/public/media/" + key;
  }

  // ---------------------------------------------------------------- auth
  function saveSession(s) {
    session = {
      access_token: s.access_token,
      refresh_token: s.refresh_token,
      // expires_in is seconds; refresh a minute early.
      expires_at: Date.now() + (s.expires_in || 3600) * 1000 - 60000,
    };
    try { localStorage.setItem(LS_TOKEN, JSON.stringify(session)); } catch (e) {}
  }

  function loadSession() {
    try {
      var raw = localStorage.getItem(LS_TOKEN);
      if (raw) session = JSON.parse(raw);
    } catch (e) { session = null; }
  }

  function signInAnonymously() {
    return req("/auth/v1/signup", { auth: false, body: {} }).then(saveSession);
  }

  function refreshSession() {
    return req("/auth/v1/token?grant_type=refresh_token", {
      auth: false,
      body: { refresh_token: session.refresh_token },
    }).then(saveSession);
  }

  function ensureSession() {
    if (session && session.access_token && Date.now() < session.expires_at) {
      return Promise.resolve();
    }
    if (session && session.refresh_token) {
      return refreshSession().catch(function () {
        session = null;
        return signInAnonymously();
      });
    }
    return signInAnonymously();
  }

  // ---------------------------------------------------------------- errors
  var FRIENDLY = {
    AUTH_REQUIRED: "Session expired. Reload the page.",
    BAD_NAME: "Pick a name between 1 and 24 characters.",
    BAD_ROUND_COUNT: "Rounds must be between 3 and 20.",
    BAD_DIFFICULTY: "That difficulty range is not valid.",
    CODE_EXHAUSTED: "Could not allocate a room code. Try again.",
    ROOM_NOT_FOUND: "No room with that code.",
    NOT_IN_LOBBY: "That game has already started.",
    ROOM_FULL: "That room is full (8 players).",
    ALREADY_IN_ROOM: "You are already in that room.",
    NAME_TAKEN: "Someone in that room already has that name.",
    NOT_A_MEMBER: "You are not in that room.",
    NOT_HOST: "Only the host can start the game.",
    ROUND_NOT_ACTIVE: "That round is not accepting guesses.",
    ALREADY_CORRECT: "You already got this one.",
    EMPTY_GUESS: "Type something first.",
    EMPTY_NORMALISED: "That guess has no letters or digits in it.",
    GUESS_TOO_LONG: "That guess is too long.",
  };

  function friendly(err) {
    var m = (err && err.message) || "";
    for (var k in FRIENDLY) {
      if (m.indexOf(k) === 0) {
        // INSUFFICIENT_CONTENT carries a count in the message; keep it.
        return FRIENDLY[k];
      }
    }
    if (m.indexOf("INSUFFICIENT_CONTENT") === 0) {
      return "Not enough anime in the question bank for that many rounds at that " +
             "difficulty. Try fewer rounds or a wider difficulty range.";
    }
    if (/Anonymous sign-ins are disabled/i.test(m)) {
      return "Anonymous sign-in is disabled on this Supabase project.";
    }
    return m || "Something went wrong.";
  }

  function banner(el, msg) {
    if (!msg) { el.classList.add("hidden"); return; }
    text(el, msg);
    el.classList.remove("hidden");
  }

  // ---------------------------------------------------------------- polling
  function startPolling() {
    stopPolling();
    poll();
    pollTimer = setInterval(poll, POLL_MS);
    tickTimer = setInterval(tick, 200);
  }
  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    if (tickTimer) clearInterval(tickTimer);
    pollTimer = tickTimer = null;
  }

  function poll() {
    if (!roomId) return Promise.resolve();
    return ensureSession()
      .then(function () { return rpc("get_room_state", { p_room_id: roomId }); })
      .then(function (s) {
        if (!s) return;
        clockSkew = new Date(s.server_now).getTime() - Date.now();
        last = s;
        render();
        maybeAdvance();
      })
      .catch(function (err) {
        // A dropped poll is normal on mobile. Only a hard membership/room failure
        // should tear the session down.
        var m = (err && err.message) || "";
        if (m.indexOf("NOT_A_MEMBER") === 0 || m.indexOf("ROOM_NOT_FOUND") === 0) {
          leaveRoom();
        }
      });
  }

  // Round progression has no server-side scheduler: any member may attempt the
  // idempotent advance once the deadline has passed. The guard in advance_round
  // tests a column the same UPDATE writes, so eight simultaneous callers advance
  // exactly once (see B-17). advancedFor stops THIS client retrying every 1.5 s
  // while the request is in flight.
  function maybeAdvance() {
    if (!last || last.state !== "playing" || !last.deadline) return;
    var dl = new Date(last.deadline).getTime();
    if (serverNow() < dl) return;
    if (advancedFor === last.deadline) return;
    advancedFor = last.deadline;
    rpc("advance_round", { p_room_id: roomId })
      .then(poll)
      .catch(function () { /* another client won the race; the next poll shows it */ });
  }

  // ---------------------------------------------------------------- render
  function render() {
    if (!last) return;

    if (last.state === "lobby") { renderLobby(); return; }

    if (last.state === "over") {
      if (!overSince) overSince = serverNow();
      // Show the final round's reveal before the scoreboard, so the last answer is
      // not swallowed by game over -- which is exactly what advance_round used to do.
      if (last.reveal && serverNow() - overSince < 8000) { renderReveal(true); return; }
      renderOver();
      return;
    }

    if (last.state === "playing") {
      var r = last.round;
      // The gap before starts_at IS the reveal phase (migration 0012). grade_guess
      // rejects guesses inside it, so the UI must not offer the input.
      if (r && serverNow() < new Date(r.starts_at).getTime() && last.reveal) {
        renderReveal(false);
        return;
      }
      renderPlay();
      return;
    }
  }

  function renderLobby() {
    show("scr-lobby");
    text($("lobby-code"), last.code);
    var ps = last.players || [];
    text($("lobby-count"), ps.length + "/8");

    var ul = $("lobby-players");
    ul.innerHTML = "";
    ps.forEach(function (p) {
      var li = document.createElement("li");
      var n = document.createElement("span");
      n.textContent = p.name;
      if (p.is_me) n.className = "you";
      li.appendChild(n);
      if (p.is_host) {
        var h = document.createElement("span");
        h.className = "host";
        h.textContent = "HOST";
        li.appendChild(h);
      }
      ul.appendChild(li);
    });

    if (last.is_host) {
      $("btn-start").classList.remove("hidden");
      $("btn-start").disabled = ps.length < 2;
      text($("lobby-hint"), ps.length < 2
        ? "Waiting for at least one more player."
        : last.round_count + " rounds, audio " + (last.audio_enabled ? "on" : "off") + ".");
    } else {
      $("btn-start").classList.add("hidden");
      text($("lobby-hint"), "Waiting for the host to start.");
    }
  }

  function renderPlay() {
    show("scr-play");
    var r = last.round;
    if (!r) return;

    text($("play-round"), "Round " + r.ordinal + "/" + last.round_count);

    // Stills appear progressively across the round, evenly spaced.
    var keys = (r.assets && r.assets.stills) || [];
    var startMs = new Date(r.starts_at).getTime();
    var endMs = new Date(r.ends_at).getTime();
    var dur = Math.max(endMs - startMs, 1);
    var elapsed = serverNow() - startMs;
    var due = 0;
    for (var i = 0; i < keys.length; i++) {
      if (elapsed >= i * (dur / keys.length)) due = i + 1;
    }

    var box = $("play-stills");
    if (shownStills !== due || box.dataset.round !== String(r.ordinal)) {
      if (box.dataset.round !== String(r.ordinal)) {
        // New round: everything round-scoped resets here. Without this the previous
        // round's "Correct -- +161 points!" banner and the chips for guesses made two
        // rounds ago stay on screen, which reads as though they belong to the round
        // now being played. Seen live in the first two-browser test.
        box.innerHTML = "";
        shownStills = 0;
        $("play-feedback").className = "feedback";
        text($("play-feedback"), "");
        $("play-mine").innerHTML = "";
        $("in-guess").value = "";
      }
      box.dataset.round = String(r.ordinal);
      for (var j = shownStills; j < due; j++) {
        var img = document.createElement("img");
        img.src = assetUrl(keys[j]);
        img.alt = "Frame " + (j + 1) + " of the opening";
        img.loading = "eager";
        box.appendChild(img);
      }
      if (due === 0 && !box.firstChild) {
        var ph = document.createElement("div");
        ph.className = "placeholder";
        ph.textContent = "Starting…";
        box.appendChild(ph);
      }
      shownStills = due;
    }

    playAudio(r.assets && r.assets.audio);

    // Input is closed once you have already answered correctly: the server enforces
    // this too (ALREADY_CORRECT), this just stops a pointless round trip.
    $("in-guess").disabled = !!r.answered;
    if (r.answered) $("in-guess").placeholder = "You got it.";
    else $("in-guess").placeholder = "Name the anime…";

    renderScores($("play-scores"), false);
  }

  function renderReveal(isFinal) {
    show("scr-reveal");
    var rv = last.reveal || {};
    var t = rv.titles || {};
    var title = t.english || t.romaji || t.native || "?";

    text($("rev-ordinal"), "Round " + (rv.ordinal || "") + " answer");
    text($("rev-title"), title);

    var sub = [];
    if (t.romaji && t.romaji !== title) sub.push(t.romaji);
    if (rv.theme) sub.push(rv.theme);
    if (rv.year) sub.push(String(rv.year));
    text($("rev-sub"), sub.join(" · "));

    var img = $("rev-poster");
    if (rv.poster) { img.src = assetUrl(rv.poster); img.style.display = ""; }
    else { img.removeAttribute("src"); img.style.display = "none"; }

    var w = $("rev-winner");
    if (rv.winner && rv.winner.name) {
      w.className = "winner";
      w.innerHTML = "";
      var b = document.createElement("b");
      b.textContent = rv.winner.name;
      w.appendChild(b);
      w.appendChild(document.createTextNode(" got it first — " + rv.winner.points + " points"));
    } else {
      w.className = "winner none";
      text(w, "Nobody got this one.");
    }

    var a = $("rev-src");
    if (rv.source_url) { a.href = rv.source_url; a.style.display = ""; }
    else { a.style.display = "none"; }

    text($("rev-next"), isFinal ? "Final scores coming up…" : "Next round starting…");
    stopAudio();
  }

  function renderOver() {
    show("scr-over");
    renderScores($("over-scores"), true);
    stopAudio();
  }

  function renderScores(ul, big) {
    var ps = (last.players || []).slice();
    ul.innerHTML = "";
    ul.className = "scores" + (big ? " big" : "");
    ps.forEach(function (p, i) {
      var li = document.createElement("li");
      var rank = document.createElement("span");
      rank.className = "rank";
      rank.textContent = i + 1;
      var name = document.createElement("span");
      name.textContent = p.name;
      if (p.is_me) name.className = "you";
      var pts = document.createElement("span");
      pts.className = "pts";
      pts.textContent = p.score;
      li.appendChild(rank);
      li.appendChild(name);
      li.appendChild(pts);
      ul.appendChild(li);
    });
  }

  // The countdown runs on its own faster timer so the clock is smooth between polls.
  function tick() {
    if (!last || last.state !== "playing" || !last.round) return;
    var r = last.round;
    var startMs = new Date(r.starts_at).getTime();
    var endMs = new Date(r.ends_at).getTime();
    if (serverNow() < startMs) return;  // reveal gap

    var leftMs = Math.max(endMs - serverNow(), 0);
    var secs = Math.ceil(leftMs / 1000);
    var clock = $("play-clock");
    text(clock, secs);
    clock.className = "clock" + (secs <= 5 ? " low" : "");

    var dur = Math.max(endMs - startMs, 1);
    $("play-bar").style.width = (100 * leftMs / dur).toFixed(1) + "%";

    // Reveal further stills between polls too.
    if (document.getElementById("scr-play").classList.contains("active")) renderPlay();
  }

  // ---------------------------------------------------------------- audio
  function playAudio(key) {
    if (!key) { stopAudio(); return; }
    if (audioKeyPlaying === key) return;
    stopAudio();
    audioKeyPlaying = key;
    audioEl = new Audio(assetUrl(key));
    audioEl.preload = "auto";
    var p = audioEl.play();
    if (p && p.catch) {
      // Browsers block autoplay without a gesture. Creating a room or joining one is
      // a gesture, but a page restored from bfcache may not carry it, so offer a tap.
      p.catch(function () { $("btn-sound").classList.remove("hidden"); });
    }
  }
  function stopAudio() {
    if (audioEl) { try { audioEl.pause(); } catch (e) {} }
    audioEl = null;
    audioKeyPlaying = null;
    $("btn-sound").classList.add("hidden");
  }

  // ---------------------------------------------------------------- actions
  function enterRoom(id) {
    roomId = id;
    advancedFor = null;
    overSince = 0;
    myGuesses = [];
    $("play-mine").innerHTML = "";
    try { localStorage.setItem(LS_ROOM, id); } catch (e) {}
    startPolling();
  }

  function leaveRoom() {
    stopPolling();
    stopAudio();
    roomId = null;
    last = null;
    try { localStorage.removeItem(LS_ROOM); } catch (e) {}
    show("scr-home");
  }

  function nameValue() {
    var n = $("in-name").value.trim();
    try { localStorage.setItem(LS_NAME, n); } catch (e) {}
    return n;
  }

  function doCreate() {
    var n = nameValue();
    if (!n) { banner($("home-err"), "Enter a name first."); return; }
    banner($("home-err"), null);
    $("btn-create").disabled = true;
    ensureSession()
      .then(function () {
        return rpc("create_room", {
          p_settings: {
            display_name: n,
            round_count: parseInt($("in-rounds").value, 10),
            difficulty_min: parseInt($("in-dmin").value, 10),
            difficulty_max: parseInt($("in-dmax").value, 10),
            audio_enabled: $("in-audio").checked,
          },
        });
      })
      .then(function (res) { enterRoom(res.room_id); })
      .catch(function (e) { banner($("home-err"), friendly(e)); })
      .then(function () { $("btn-create").disabled = false; });
  }

  function doJoin() {
    var n = nameValue();
    var code = $("in-code").value.trim().toUpperCase();
    if (!n) { banner($("home-err"), "Enter a name first."); return; }
    if (code.length !== 4) { banner($("home-err"), "Room codes are 4 characters."); return; }
    banner($("home-err"), null);
    $("btn-join").disabled = true;
    ensureSession()
      .then(function () { return rpc("join_room", { p_code: code, p_display_name: n }); })
      .then(function (res) { enterRoom(res.room_id); })
      .catch(function (e) { banner($("home-err"), friendly(e)); })
      .then(function () { $("btn-join").disabled = false; });
  }

  function doStart() {
    $("btn-start").disabled = true;
    banner($("lobby-err"), null);
    rpc("start_game", { p_room_id: roomId })
      .then(poll)
      .catch(function (e) { banner($("lobby-err"), friendly(e)); })
      .then(function () { $("btn-start").disabled = false; });
  }

  function doGuess(ev) {
    ev.preventDefault();
    var input = $("in-guess");
    var g = input.value.trim();
    if (!g || !last || !last.round) return;
    input.value = "";

    var fb = $("play-feedback");
    rpc("grade_guess", { p_round_id: last.round.round_id, p_guess: g })
      .then(function (res) {
        var li = document.createElement("li");
        li.textContent = g;
        if (res.verdict === "correct") {
          li.className = "good";
          if (res.is_first_correct) {
            fb.className = "feedback good";
            text(fb, "Correct — +" + res.points + " points!");
          } else {
            // Winner-takes-all: correct but second scores 0, and since 0012 the
            // server says so honestly instead of reporting the winner's points.
            fb.className = "feedback warn";
            text(fb, "Correct — but someone beat you to it.");
          }
        } else {
          fb.className = "feedback bad";
          text(fb, "Not it.");
        }
        $("play-mine").appendChild(li);
        poll();
      })
      .catch(function (e) {
        fb.className = "feedback bad";
        text(fb, friendly(e));
      });
  }

  // ---------------------------------------------------------------- wiring
  function wire() {
    var tabs = document.querySelectorAll(".tab");
    for (var i = 0; i < tabs.length; i++) {
      on(tabs[i], "click", function (e) {
        var which = e.currentTarget.dataset.tab;
        for (var k = 0; k < tabs.length; k++) tabs[k].classList.toggle("active", tabs[k] === e.currentTarget);
        $("pane-join").classList.toggle("active", which === "join");
        $("pane-create").classList.toggle("active", which === "create");
      });
    }

    on($("in-rounds"), "input", function () { text($("lbl-rounds"), $("in-rounds").value); });

    function syncDiff() {
      var a = parseInt($("in-dmin").value, 10), b = parseInt($("in-dmax").value, 10);
      if (a > b) { $("in-dmax").value = a; b = a; }
      text($("lbl-diff"), a + " – " + b);
    }
    on($("in-dmin"), "input", syncDiff);
    on($("in-dmax"), "input", syncDiff);

    on($("btn-create"), "click", doCreate);
    on($("btn-join"), "click", doJoin);
    on($("btn-start"), "click", doStart);
    on($("btn-leave"), "click", leaveRoom);
    on($("btn-again"), "click", leaveRoom);
    on($("frm-guess"), "submit", doGuess);
    on($("in-code"), "keydown", function (e) { if (e.key === "Enter") doJoin(); });

    on($("btn-sound"), "click", function () {
      $("btn-sound").classList.add("hidden");
      if (audioEl) audioEl.play().catch(function () {});
    });

    on($("btn-copy"), "click", function () {
      var link = location.origin + location.pathname + "?r=" + (last ? last.code : "");
      var done = function () { text($("btn-copy"), "Copied!"); setTimeout(function () { text($("btn-copy"), "Copy invite link"); }, 1500); };
      if (navigator.clipboard) navigator.clipboard.writeText(link).then(done, done);
      else done();
    });

    // Poll immediately when a backgrounded tab comes back, rather than waiting.
    on(document, "visibilitychange", function () { if (!document.hidden) poll(); });
  }

  // ---------------------------------------------------------------- boot
  function boot() {
    wire();

    if (!URL_BASE || !ANON || ANON.indexOf("PASTE_") === 0) {
      fatal("This deployment is not configured yet.",
        "<p>Someone needs to finish two setup steps:</p><ol>" +
        "<li>Put the project's <b>publishable key</b> in <code>app/config.js</code> " +
        "(Supabase dashboard → Settings → API Keys).</li>" +
        "<li>Turn on <b>Anonymous sign-ins</b> (Supabase dashboard → Authentication " +
        "→ Sign In / Providers).</li></ol>");
      return;
    }

    try { $("in-name").value = localStorage.getItem(LS_NAME) || ""; } catch (e) {}

    var params = new URLSearchParams(location.search);
    var invite = (params.get("r") || "").toUpperCase();
    if (invite) $("in-code").value = invite;

    loadSession();
    ensureSession()
      .then(function () {
        var saved = null;
        try { saved = localStorage.getItem(LS_ROOM); } catch (e) {}
        if (saved) {
          // Rejoin whatever we were in before a refresh. get_room_state raises
          // NOT_A_MEMBER if this browser is not actually in it, which poll() handles.
          roomId = saved;
          return poll().then(function () {
            if (!last) { leaveRoom(); return; }
            enterRoom(saved);
          });
        }
        show("scr-home");
      })
      .catch(function (e) {
        var m = (e && e.message) || "";
        if (/Anonymous sign-ins are disabled/i.test(m) || e.status === 422) {
          fatal("Anonymous sign-in is turned off for this project.",
            "<p>The game has no accounts, so every player needs an anonymous session. " +
            "Enable it here:</p><ol>" +
            "<li>Supabase dashboard → <b>Authentication</b> → " +
            "<b>Sign In / Providers</b></li>" +
            "<li>Turn on <b>Anonymous sign-ins</b>, and save.</li></ol>");
        } else if (e.status === 401) {
          fatal("The publishable key in app/config.js is not valid for this project.",
            "<p>Copy it again from Supabase dashboard → Settings → API Keys.</p>");
        } else {
          fatal("Could not reach the server: " + friendly(e), "");
        }
      });
  }

  if (document.readyState === "loading") on(document, "DOMContentLoaded", boot);
  else boot();
})();
