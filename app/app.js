/* ReIN Bot — client.
 *
 * No framework, no build step, no bundler, and no supabase-js: the transport is one
 * polled RPC plus plain REST, which fetch() covers. The only third-party request the
 * page makes is a stylesheet from Google Fonts, and every font stack falls back to
 * system faces, so the game is fully playable without it.
 *
 * TRUST MODEL, in one paragraph, because it explains most of the odd choices below.
 * This client is not trusted with anything. It never sees an answer — grade_guess
 * returns a verdict, get_room_state returns the reveal only for rounds whose ends_at
 * has already passed, and the poster (the title card, by design) is withheld during
 * play. It is not trusted with the clock: every deadline is server-side and the
 * countdown runs off an offset measured against server_now, because a browser clock can
 * be minutes out. It is not trusted with scoring: points are summed inside the
 * database. If a player rewrote this file, the worst they could do is make their own UI
 * lie to them.
 *
 * STATE MODEL. There is exactly one source of truth — the last get_room_state payload —
 * and one function, route(), that decides which screen it implies. Nothing else calls
 * show(). Every "we're in the reveal now" style transition is derived from timestamps
 * rather than remembered, which is why a refresh mid-round lands exactly where it left.
 */
(function () {
  "use strict";

  // ════════════════════════════ config ════════════════════════════
  var CFG = window.REIN_CONFIG || {};
  var URL_BASE = (CFG.SUPABASE_URL || "").replace(/\/+$/, "");
  var ANON = CFG.SUPABASE_ANON_KEY || "";

  var POLL_MS = 1500;
  var TICK_MS = 100;
  var OVER_REVEAL_MS = 6000;   // how long the last answer holds before final scores
  var CODE_ALPHABET = /^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$/;  // Crockford, no I L O U

  var LS_TOKEN = "rein.session";
  var LS_ROOM = "rein.room";
  var LS_NAME = "rein.name";

  // ════════════════════════════ dom helpers ════════════════════════════
  function $(id) { return document.getElementById(id); }
  function on(el, ev, fn) { if (el) el.addEventListener(ev, fn); }
  function text(el, s) { if (el) el.textContent = s == null ? "" : String(s); }
  function cls(el, c) { if (el) el.className = c; }

  var currentScreen = null;
  function show(id) {
    if (currentScreen === id) return;
    currentScreen = id;
    var all = document.querySelectorAll(".screen");
    for (var i = 0; i < all.length; i++) all[i].classList.toggle("active", all[i].id === id);
    window.scrollTo(0, 0);
  }

  function toast(msg, kind) {
    var host = $("toasts");
    var el = document.createElement("div");
    el.className = "toast" + (kind ? " " + kind : "");
    el.textContent = msg;
    host.appendChild(el);
    setTimeout(function () { el.remove(); }, 3200);
  }

  function banner(el, msg) {
    if (!el) return;
    if (!msg) { el.classList.add("hidden"); return; }
    text(el, msg);
    el.classList.remove("hidden");
  }

  // ════════════════════════════ state ════════════════════════════
  var session = null;       // { access_token, refresh_token, expires_at }
  var clockSkew = 0;        // serverNow - clientNow, ms
  var roomId = null;
  var last = null;          // last get_room_state payload — the single source of truth
  var pollTimer = null, tickTimer = null;
  var polling = false;      // guard: never overlap two polls on a slow connection
  var advancedFor = null;   // deadline value already acted on
  var guessInFlight = false;
  var shownStills = 0;
  var lastStills = [];      // cached so the reveal can show what you were looking at
  var audioEl = null, audioKey = null;
  var overSince = 0;
  var pollFails = 0;
  var reconnecting = false;

  function serverNow() { return Date.now() + clockSkew; }
  function t(iso) { return iso ? new Date(iso).getTime() : 0; }

  // ════════════════════════════ http ════════════════════════════
  function req(path, opts) {
    opts = opts || {};
    // apikey identifies the project; Authorization carries the SESSION and is sent only
    // when there is one. Putting the publishable key in Authorization is wrong for the
    // sb_publishable_ format (not a JWT) and unnecessary in either: the pre-auth role
    // has no grant on anything here. The one pre-auth call is /auth/v1/signup.
    var headers = { apikey: ANON, "Content-Type": "application/json" };
    if (opts.auth !== false && session && session.access_token) {
      headers.Authorization = "Bearer " + session.access_token;
    }
    return fetch(URL_BASE + path, {
      method: opts.method || "POST",
      headers: headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    }).then(function (r) {
      return r.text().then(function (raw) {
        var j = null;
        try { j = raw ? JSON.parse(raw) : null; } catch (e) { j = null; }
        if (!r.ok) {
          var err = new Error((j && (j.message || j.error_description || j.error || j.msg))
                              || raw || ("HTTP " + r.status));
          err.status = r.status;
          throw err;
        }
        return j;
      });
    });
  }

  // PostgREST surfaces `raise exception 'ROOM_FULL'` as message "ROOM_FULL". The
  // functions raise bare uppercase codes on purpose so this mapping stays trivial.
  function rpc(name, args) { return req("/rest/v1/rpc/" + name, { body: args || {} }); }

  function assetUrl(key) { return URL_BASE + "/storage/v1/object/public/media/" + key; }

  // ════════════════════════════ auth ════════════════════════════
  function saveSession(s) {
    session = {
      access_token: s.access_token,
      refresh_token: s.refresh_token,
      expires_at: Date.now() + (s.expires_in || 3600) * 1000 - 60000,  // refresh a minute early
    };
    try { localStorage.setItem(LS_TOKEN, JSON.stringify(session)); } catch (e) {}
  }
  function loadSession() {
    try { var raw = localStorage.getItem(LS_TOKEN); if (raw) session = JSON.parse(raw); }
    catch (e) { session = null; }
  }
  function signIn() { return req("/auth/v1/signup", { auth: false, body: {} }).then(saveSession); }
  function refresh() {
    return req("/auth/v1/token?grant_type=refresh_token",
               { auth: false, body: { refresh_token: session.refresh_token } }).then(saveSession);
  }
  function ensureSession() {
    if (session && session.access_token && Date.now() < session.expires_at) return Promise.resolve();
    if (session && session.refresh_token) {
      return refresh().catch(function () { session = null; return signIn(); });
    }
    return signIn();
  }

  // ════════════════════════════ errors ════════════════════════════
  var FRIENDLY = {
    AUTH_REQUIRED: "Your session expired. Reload the page.",
    BAD_NAME: "Names need 1 to 24 characters.",
    BAD_ROUND_COUNT: "Rounds must be between 3 and 20.",
    BAD_DIFFICULTY: "That difficulty range isn't valid.",
    CODE_EXHAUSTED: "Couldn't get a free room code. Try again.",
    ROOM_NOT_FOUND: "No room with that code. Check it and try again.",
    NOT_IN_LOBBY: "That game has already started.",
    ROOM_FULL: "That room is full — 8 players is the limit.",
    ALREADY_IN_ROOM: "You're already in that room.",
    NAME_TAKEN: "Someone in that room already took that name.",
    NOT_A_MEMBER: "You're not in that room any more.",
    NOT_HOST: "Only the host can start the game.",
    ROUND_NOT_ACTIVE: "Too late — that round is over.",
    ALREADY_CORRECT: "You already got this one.",
    EMPTY_GUESS: "Type something first.",
    EMPTY_NORMALISED: "That guess has no letters or numbers in it.",
    GUESS_TOO_LONG: "That guess is too long.",
  };

  function friendly(err) {
    var m = (err && err.message) || "";
    for (var k in FRIENDLY) if (m.indexOf(k) === 0) return FRIENDLY[k];
    if (m.indexOf("INSUFFICIENT_CONTENT") === 0) {
      return "Not enough different anime for that many rounds at that difficulty. " +
             "Try fewer rounds, or widen the range.";
    }
    if (/anonymous/i.test(m)) return "Anonymous sign-in is disabled on this project.";
    // Supabase allows 30 anonymous sign-ins an hour PER IP. A whole group on one home
    // connection can reach that, and the generic message ("Request rate limit reached")
    // tells a player nothing they can act on.
    if (/rate limit/i.test(m) || err.status === 429) {
      return "Too many new sessions from this network in the last hour. " +
             "Wait a few minutes, or have someone on a different connection host.";
    }
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return "Network problem. Check your connection.";
    return m || "Something went wrong.";
  }

  // ════════════════════════════ routing ════════════════════════════
  // Hash routes cover only the pre-room screens. Once you are in a room the screen is
  // a function of game state, not of the URL — a lobby that jumped back to the landing
  // page because someone hit Back would be worse than Back doing nothing.
  var ROUTES = { "": "scr-landing", "/": "scr-landing", "/create": "scr-create", "/join": "scr-join" };

  function go(name) { location.hash = "#/" + name; }

  function applyHash() {
    if (roomId) return;                       // in a room: game state owns the screen
    var h = location.hash.replace(/^#/, "");
    var id = ROUTES[h] || ROUTES[""];
    show(id);
    if (id === "scr-create") $("in-name-c").focus();
    if (id === "scr-join" && !$("in-code").value) $("in-code").focus();
  }

  // ════════════════════════════ polling ════════════════════════════
  function startPolling() {
    stopPolling();
    poll();
    pollTimer = setInterval(poll, POLL_MS);
    tickTimer = setInterval(tick, TICK_MS);
  }
  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    if (tickTimer) clearInterval(tickTimer);
    pollTimer = tickTimer = null;
  }

  function poll() {
    if (!roomId || polling) return Promise.resolve();
    polling = true;
    return ensureSession()
      .then(function () { return rpc("get_room_state", { p_room_id: roomId }); })
      .then(function (s) {
        if (!s || !roomId) return;
        clockSkew = t(s.server_now) - Date.now();
        last = s;
        if (reconnecting) { reconnecting = false; toast("Reconnected", "good"); }
        pollFails = 0;
        route();
        maybeAdvance();
      })
      .catch(function (err) {
        var m = (err && err.message) || "";
        // A membership or room failure is terminal; anything else is probably the
        // network and deserves patience rather than ejection.
        if (m.indexOf("NOT_A_MEMBER") === 0 || m.indexOf("ROOM_NOT_FOUND") === 0) {
          toast(friendly(err), "bad");
          leaveRoom(false);
          return;
        }
        pollFails++;
        if (pollFails === 3 && !reconnecting) { reconnecting = true; toast("Reconnecting…"); }
      })
      .then(function () { polling = false; });
  }

  // Round progression has no server-side scheduler for the normal case: any member may
  // attempt the idempotent advance once the deadline has passed. advance_round's guard
  // tests a column its own UPDATE writes, so eight simultaneous callers advance exactly
  // once. advancedFor stops THIS client retrying while a request is in flight. A
  // pg_cron job (migration 0014) ends rooms everyone has abandoned.
  function maybeAdvance() {
    if (!last || last.state !== "playing" || !last.deadline) return;
    if (serverNow() < t(last.deadline)) return;
    if (advancedFor === last.deadline) return;
    advancedFor = last.deadline;
    rpc("advance_round", { p_room_id: roomId }).then(poll).catch(function () {
      /* another client won the race; the next poll shows the result */
    });
  }

  // ════════════════════════════ the one router ════════════════════════════
  function route() {
    if (!last) return;

    if (last.state === "lobby") { renderLobby(); return; }

    if (last.state === "over") {
      if (!overSince) overSince = serverNow();
      // Hold the last answer on screen before the final table, so the closing round is
      // not swallowed by game over — which is exactly what advance_round used to do.
      if (last.reveal && serverNow() - overSince < OVER_REVEAL_MS) { renderReveal(true); return; }
      renderOver();
      return;
    }

    if (last.state === "playing") {
      var r = last.round;
      if (!r) { renderPlay(); return; }
      var now = serverNow();
      // Two different situations, one screen:
      //   now >= ends_at  — the round is finished. Either it timed out, or somebody
      //                     won and migration 0015 pulled ends_at back to that moment.
      //   now <  starts_at — we are in the reveal gap before the next round.
      // Both mean "show the answer", and both are derived from timestamps rather than
      // remembered, so a refresh lands in the right place.
      if (last.reveal && (now >= t(r.ends_at) || now < t(r.starts_at))) { renderReveal(false); return; }
      renderPlay();
      return;
    }
  }

  // ════════════════════════════ avatars ════════════════════════════
  // Flat, saturated, and all dark enough to keep the black initial legible on top —
  // the palette is the stylesheet's, so avatars stay part of the same picture.
  var AV = ["#ff1f5a", "#17b6c9", "#d9f441", "#7b4fe8", "#ffb020", "#12a150", "#ff7ac6", "#5ad1ff"];
  function avatarFor(name) {
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
    var el = document.createElement("span");
    el.className = "avatar";
    el.style.background = AV[h % AV.length];
    el.textContent = (name.trim()[0] || "?").toUpperCase();
    return el;
  }

  // ════════════════════════════ lobby ════════════════════════════
  function renderLobby() {
    show("scr-lobby");
    text($("lobby-code"), last.code);
    var ps = last.players || [];
    text($("lobby-count"), ps.length + "/8");

    var ul = $("lobby-players");
    ul.innerHTML = "";
    ps.forEach(function (p) {
      var li = document.createElement("li");
      li.appendChild(avatarFor(p.name));
      var n = document.createElement("span");
      n.textContent = p.name;
      if (p.is_me) n.className = "you";
      li.appendChild(n);
      if (p.is_host) {
        var tag = document.createElement("span");
        tag.className = "tag";
        tag.textContent = "host";
        li.appendChild(tag);
      }
      ul.appendChild(li);
    });

    var start = $("btn-start");
    if (last.is_host) {
      start.classList.remove("hidden");
      start.disabled = ps.length < 2;
      text($("lobby-hint"), ps.length < 2
        ? "Waiting for at least one more player…"
        : last.round_count + " rounds · difficulty " + last.difficulty_min + "–" + last.difficulty_max +
          " · audio " + (last.audio_enabled ? "on" : "off"));
    } else {
      start.classList.add("hidden");
      text($("lobby-hint"), "Waiting for the host to start…");
    }
  }

  // ════════════════════════════ play ════════════════════════════
  function renderPlay() {
    show("scr-play");
    var r = last.round;
    if (!r) return;

    text($("play-round"), "Round " + r.ordinal + "/" + last.round_count);

    var keys = (r.assets && r.assets.stills) || [];
    var startMs = t(r.starts_at), endMs = t(r.ends_at);
    var dur = Math.max(endMs - startMs, 1);
    var elapsed = serverNow() - startMs;

    // Stills appear evenly across the round: 3 over 20s lands at 0 / 6.7 / 13.3s.
    var due = 0;
    for (var i = 0; i < keys.length; i++) if (elapsed >= i * (dur / keys.length)) due = i + 1;

    var box = $("play-stills");
    var isNewRound = box.dataset.round !== String(r.ordinal);
    if (isNewRound) {
      // Everything round-scoped resets here. Without it the previous round's feedback
      // banner and guess chips stay on screen, reading as though they belong to the
      // round now being played — seen in the first two-browser test.
      box.innerHTML = "";
      shownStills = 0;
      lastStills = keys.slice();
      cls($("play-feedback"), "feedback");
      text($("play-feedback"), "");
      $("play-mine").innerHTML = "";
      $("in-guess").value = "";
      box.dataset.round = String(r.ordinal);
    }
    box.dataset.n = String(keys.length);

    if (shownStills !== due) {
      for (var j = shownStills; j < due; j++) {
        var img = document.createElement("img");
        img.src = assetUrl(keys[j]);
        img.alt = "Frame " + (j + 1) + " from the opening";
        img.decoding = "async";
        img.onerror = function () { this.style.visibility = "hidden"; };
        box.appendChild(img);
      }
      shownStills = due;
    }
    if (due === 0 && !box.firstChild) {
      var ph = document.createElement("div");
      ph.className = "ghost-frame";
      ph.textContent = "Starting…";
      box.appendChild(ph);
    }

    playAudio(r.assets && r.assets.audio);

    // The server enforces this too (ALREADY_CORRECT); disabling just saves a round trip.
    var gi = $("in-guess");
    gi.disabled = !!r.answered;
    gi.placeholder = r.answered ? "You got it — sit tight." : "Name the anime…";
    $("btn-guess").disabled = !!r.answered;

    renderScores($("play-scores"), false);
  }

  // ════════════════════════════ reveal ════════════════════════════
  function renderReveal(isFinal) {
    show("scr-reveal");
    stopAudio();

    var rv = last.reveal || {};
    var ti = rv.titles || {};
    var title = ti.english || ti.romaji || ti.native || "?";

    text($("rev-ordinal"), "Round " + (rv.ordinal || "") + " · the answer was");
    text($("rev-title"), title);

    var sub = [];
    if (ti.romaji && ti.romaji !== title) sub.push(ti.romaji);
    if (ti.native && ti.native !== title) sub.push(ti.native);
    if (rv.theme) sub.push(rv.theme);
    if (rv.year) sub.push(String(rv.year));
    text($("rev-sub"), sub.join("  ·  "));

    var img = $("rev-poster");
    if (rv.poster) {
      var url = assetUrl(rv.poster);
      if (img.getAttribute("src") !== url) img.src = url;
      img.style.display = "";
    } else { img.removeAttribute("src"); img.style.display = "none"; }

    // The frames you were just looking at, kept alongside the poster.
    var strip = $("rev-strip");
    if (strip.dataset.round !== String(rv.ordinal)) {
      strip.innerHTML = "";
      lastStills.forEach(function (k) {
        var s = document.createElement("img");
        s.src = assetUrl(k);
        s.alt = "";
        s.onerror = function () { this.remove(); };
        strip.appendChild(s);
      });
      strip.dataset.round = String(rv.ordinal);
    }

    var w = $("rev-winner");
    if (rv.winner && rv.winner.name) {
      w.className = "winner hit";
      w.innerHTML = "";
      var b = document.createElement("b");
      b.textContent = rv.winner.name;
      w.appendChild(b);
      w.appendChild(document.createTextNode(" got it first — " + rv.winner.points + " points"));
    } else {
      w.className = "winner none";
      text(w, "Nobody got that one.");
    }

    renderScores($("rev-scores"), false);

    var a = $("rev-src");
    if (rv.source_url) { a.href = rv.source_url; a.style.display = ""; }
    else { a.style.display = "none"; }

    text($("rev-next"), isFinal ? "Final scores" : "Next round");
  }

  // ════════════════════════════ game over ════════════════════════════
  function renderOver() {
    show("scr-over");
    stopAudio();
    var ps = last.players || [];
    var top = ps[0];
    var me = ps.filter(function (p) { return p.is_me; })[0];
    if (top && me) {
      text($("over-eyebrow"), top.is_me ? "You won" : top.name + " wins");
      text($("over-title"), top.is_me ? "Nicely done." : "Final scores");
    }
    renderScores($("over-scores"), true);
  }

  function renderScores(ul, big) {
    if (!ul) return;
    var ps = last.players || [];
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
      li.appendChild(rank); li.appendChild(name); li.appendChild(pts);
      ul.appendChild(li);
    });
  }

  // ════════════════════════════ tick ════════════════════════════
  // Runs faster than the poll so the clock and the countdown are smooth between them.
  function tick() {
    if (!last) return;

    if (currentScreen === "scr-reveal") {
      var r0 = last.round;
      var ring = $("rev-ring"), cnt = $("rev-count");
      var C = 119.4;  // 2*pi*19, matching the SVG radius
      if (r0 && serverNow() < t(r0.starts_at)) {
        var msLeft = t(r0.starts_at) - serverNow();
        text(cnt, Math.max(1, Math.ceil(msLeft / 1000)));
        // The ring empties over the room's own reveal_duration, not an assumed 8s --
        // rooms.reveal_duration is a per-room column and 8 is only its default.
        var span = Math.max((last.reveal_seconds || 8) * 1000, 1);
        ring.style.strokeDashoffset = String(C * (1 - Math.min(msLeft / span, 1)));
      } else {
        // Round is over but the advance has not landed yet (or the game has ended).
        text(cnt, "·");
        ring.style.strokeDashoffset = "0";
      }
      return;
    }

    if (currentScreen !== "scr-play" || last.state !== "playing" || !last.round) return;

    var r = last.round;
    var startMs = t(r.starts_at), endMs = t(r.ends_at);
    if (serverNow() < startMs) return;

    var leftMs = Math.max(endMs - serverNow(), 0);
    var s = Math.ceil(leftMs / 1000);
    var clock = $("play-clock");
    text(clock, s);
    clock.className = "clock" + (s <= 5 ? " low" : "");
    $("play-bar").style.width = (100 * leftMs / Math.max(endMs - startMs, 1)).toFixed(1) + "%";

    renderPlay();   // reveal further stills between polls
  }

  // ════════════════════════════ audio ════════════════════════════
  function playAudio(key) {
    if (!key) { stopAudio(); return; }
    if (audioKey === key) return;
    stopAudio();
    audioKey = key;
    audioEl = new Audio(assetUrl(key));
    audioEl.preload = "auto";
    var p = audioEl.play();
    if (p && p.catch) {
      // Autoplay needs a user gesture. Creating or joining a room is one, but a page
      // restored from bfcache may not carry it, so offer a tap instead of failing mute.
      p.catch(function () { $("btn-sound").classList.remove("hidden"); });
    }
  }
  function stopAudio() {
    if (audioEl) { try { audioEl.pause(); } catch (e) {} }
    audioEl = null; audioKey = null;
    $("btn-sound").classList.add("hidden");
  }

  // ════════════════════════════ room lifecycle ════════════════════════════
  function enterRoom(id) {
    roomId = id;
    advancedFor = null;
    overSince = 0;
    shownStills = 0;
    lastStills = [];
    pollFails = 0;
    $("play-stills").dataset.round = "";
    $("rev-strip").dataset.round = "";
    try { localStorage.setItem(LS_ROOM, id); } catch (e) {}
    startPolling();
  }

  // Tell the server first when we can. Leaving used to be purely local, which stranded
  // a room whose HOST left: their players row stayed, host_player_id pointed at someone
  // never coming back, and start_game raised NOT_HOST for everyone else forever.
  // leave_room (0017) deletes the row in the lobby and passes the host role on; once
  // the game is playing it deliberately refuses, because guesses cascades from players
  // and deleting would wipe the leaver's score off everyone else's scoreboard.
  function leaveRoom(announce) {
    if (announce !== false && roomId && session) {
      rpc("leave_room", { p_room_id: roomId }).catch(function () {});
    }
    stopPolling();
    stopAudio();
    roomId = null;
    last = null;
    currentScreen = null;
    try { localStorage.removeItem(LS_ROOM); } catch (e) {}
    if (location.hash !== "#/") location.hash = "#/"; else applyHash();
  }

  // A blank name field is a small wall: people stall on it, or type "a". Everyone gets
  // a usable handle on arrival and can overwrite it. Two words so collisions are rare
  // inside a room of eight -- and since 0017 a collision is refused case- and
  // whitespace-insensitively, so "Neon Ronin" and "neonronin" cannot both join.
  var NAME_A = ["Neon", "Copper", "Velvet", "Midnight", "Paper", "Static", "Crimson",
                "Glass", "Feral", "Quiet", "Hollow", "Chrome", "Bitter", "Solar",
                "Wired", "Astral", "Rusted", "Gentle", "Vivid", "Zero"];
  var NAME_B = ["Ronin", "Senpai", "Kitsune", "Samurai", "Oracle", "Phantom", "Sensei",
                "Wanderer", "Bandit", "Prophet", "Rival", "Nomad", "Kouhai", "Shogun",
                "Drifter", "Alchemist", "Gunslinger", "Detective", "Pilot", "Rookie"];

  function randomName() {
    var a = NAME_A[Math.floor(Math.random() * NAME_A.length)];
    var b = NAME_B[Math.floor(Math.random() * NAME_B.length)];
    return a + " " + b;
  }

  function nameFrom(input) {
    var n = input.value.trim().replace(/\s+/g, " ");
    if (n) { try { localStorage.setItem(LS_NAME, n); } catch (e) {} }
    return n;
  }

  // ════════════════════════════ actions ════════════════════════════
  function doCreate() {
    var n = nameFrom($("in-name-c"));
    if (!n) { banner($("create-err"), "Pick a name first."); $("in-name-c").focus(); return; }

    var btn = $("btn-create");
    btn.disabled = true;
    banner($("create-err"), null);

    ensureSession()
      .then(function () {
        return rpc("create_room", { p_settings: {
          display_name: n,
          round_count: parseInt($("in-rounds").value, 10),
          difficulty_min: parseInt($("in-dmin").value, 10),
          difficulty_max: parseInt($("in-dmax").value, 10),
          audio_enabled: $("in-audio").checked,
        }});
      })
      .then(function (res) { enterRoom(res.room_id); })
      .catch(function (e) { banner($("create-err"), friendly(e)); })
      .then(function () { btn.disabled = false; });
  }

  function doJoin() {
    var n = nameFrom($("in-name-j"));
    var code = $("in-code").value.trim().toUpperCase();
    if (!n) { banner($("join-err"), "Pick a name first."); $("in-name-j").focus(); return; }
    if (!CODE_ALPHABET.test(code)) {
      banner($("join-err"), code.length !== 4
        ? "Room codes are exactly 4 characters."
        : "That code has a character we don't use — no I, L, O or U.");
      $("in-code").focus();
      return;
    }

    var btn = $("btn-join");
    btn.disabled = true;
    banner($("join-err"), null);

    ensureSession()
      .then(function () { return rpc("join_room", { p_code: code, p_display_name: n }); })
      .then(function (res) { enterRoom(res.room_id); })
      .catch(function (e) { banner($("join-err"), friendly(e)); })
      .then(function () { btn.disabled = false; });
  }

  function doStart() {
    var b = $("btn-start");
    b.disabled = true;
    banner($("lobby-err"), null);
    rpc("start_game", { p_room_id: roomId })
      .then(poll)
      .catch(function (e) { banner($("lobby-err"), friendly(e)); b.disabled = false; });
  }

  function doGuess(ev) {
    ev.preventDefault();
    if (guessInFlight) return;
    var input = $("in-guess");
    var g = input.value.trim();
    if (!g || !last || !last.round) return;

    guessInFlight = true;
    input.value = "";
    var fb = $("play-feedback");

    rpc("grade_guess", { p_round_id: last.round.round_id, p_guess: g })
      .then(function (res) {
        var li = document.createElement("li");
        li.textContent = g;
        if (res.verdict === "correct") {
          li.className = "good";
          if (res.is_first_correct) {
            cls(fb, "feedback good");
            text(fb, "Correct — +" + res.points + " points!");
          } else {
            // Winner-takes-all: correct but second scores 0, and since migration 0012
            // the server says so honestly instead of returning the winner's points.
            cls(fb, "feedback warn");
            text(fb, "Correct — but someone beat you to it.");
          }
        } else {
          cls(fb, "feedback bad");
          text(fb, "Not it.");
        }
        $("play-mine").appendChild(li);
        poll();
      })
      .catch(function (e) { cls(fb, "feedback bad"); text(fb, friendly(e)); })
      .then(function () { guessInFlight = false; });
  }

  // ════════════════════════════ wiring ════════════════════════════
  function wire() {
    var navs = document.querySelectorAll("[data-nav]");
    for (var i = 0; i < navs.length; i++) {
      on(navs[i], "click", function (e) { go(e.currentTarget.dataset.nav); });
    }

    var rounds = $("in-rounds");
    on(rounds, "input", function () {
      var n = parseInt(rounds.value, 10);
      text($("lbl-rounds"), n);
      var mins = Math.round(n * 28 / 60);
      text($("hint-rounds"), "About " + (mins < 1 ? "a minute" : mins + " minutes"));
    });

    var DIFF_WORDS = ["", "household names", "well known", "popular", "for regulars", "deep cuts"];
    function syncDiff() {
      var a = parseInt($("in-dmin").value, 10), b = parseInt($("in-dmax").value, 10);
      if (a > b) { $("in-dmax").value = a; b = a; }
      text($("lbl-diff"), a + " – " + b);
      text($("hint-diff"), a === b ? "Only " + DIFF_WORDS[a]
                                   : DIFF_WORDS[a] + " through to " + DIFF_WORDS[b]);
    }
    on($("in-dmin"), "input", syncDiff);
    on($("in-dmax"), "input", syncDiff);

    on($("btn-create"), "click", doCreate);
    on($("btn-join"), "click", doJoin);
    on($("btn-start"), "click", doStart);
    on($("btn-leave"), "click", function () { leaveRoom(true); });
    on($("btn-again"), "click", function () { leaveRoom(false); go("create"); });
    on($("frm-guess"), "submit", doGuess);

    on($("in-name-c"), "keydown", function (e) { if (e.key === "Enter") doCreate(); });
    on($("in-name-j"), "keydown", function (e) { if (e.key === "Enter") $("in-code").focus(); });
    on($("in-code"), "keydown", function (e) { if (e.key === "Enter") doJoin(); });
    on($("in-code"), "input", function () {
      // Uppercase as you type, and drop anything outside the Crockford alphabet so an
      // impossible code cannot be submitted in the first place.
      var v = $("in-code").value.toUpperCase().replace(/[^0-9ABCDEFGHJKMNPQRSTVWXYZ]/g, "");
      if (v !== $("in-code").value) $("in-code").value = v;
      banner($("join-err"), null);
    });

    on($("btn-sound"), "click", function () {
      $("btn-sound").classList.add("hidden");
      if (audioEl) audioEl.play().catch(function () {});
    });

    on($("btn-copy"), "click", function () {
      var link = location.origin + location.pathname + "?r=" + (last ? last.code : "");
      var done = function () { toast("Invite link copied", "good"); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(link).then(done, function () { prompt("Copy this link:", link); });
      } else { prompt("Copy this link:", link); }
    });

    on(window, "hashchange", applyHash);
    // A backgrounded tab throttles timers; poll the moment it comes back rather than
    // waiting out the interval and showing a stale round.
    on(document, "visibilitychange", function () { if (!document.hidden) poll(); });
  }

  // ════════════════════════════ POST screen ════════════════════════════
  // Once per browser SESSION, not per load: charming the first time, an obstacle the
  // fifth. Skippable with any key, click or touch, and removed from the DOM when done
  // rather than hidden, so it can never intercept a click or trap a focus ring.
  // Honours prefers-reduced-motion by not running at all.
  var BOOT_LINES = [
    "ReIN BIOS v1.34  (c) 2026",
    "",
    "Memory test ................ 640K OK",
    "Detecting media ............ 134 questions",
    "Series in rotation ......... 46",
    "OCR spoiler filter ......... ARMED",
    "Answer bank ................ SEALED",
    "Clock source ............... server",
    "",
    "Starting ReIN Bot...",
  ];

  function runBoot(done) {
    var el = $("boot"), out = $("boot-text");
    var seen = false;
    try { seen = sessionStorage.getItem("rein.booted") === "1"; } catch (e) {}
    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (!el) { done(); return; }
    if (seen || reduced) { el.remove(); done(); return; }
    try { sessionStorage.setItem("rein.booted", "1"); } catch (e) {}

    var i = 0, timer = null, finished = false;

    function finish() {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      document.removeEventListener("keydown", finish);
      document.removeEventListener("pointerdown", finish);
      el.classList.add("done");
      // Match the crt-off animation, then take it out of the document entirely.
      setTimeout(function () { el.remove(); }, 340);
      done();
    }

    function step() {
      if (i >= BOOT_LINES.length) { timer = setTimeout(finish, 420); return; }
      out.textContent += BOOT_LINES[i++] + String.fromCharCode(10);
      timer = setTimeout(step, 105);
    }

    document.addEventListener("keydown", finish);
    document.addEventListener("pointerdown", finish);
    step();
  }

  // ════════════════════════════ boot ════════════════════════════
  function setupScreen(title, bodyHtml) {
    text($("setup-title"), title);
    $("setup-body").innerHTML = bodyHtml;
    show("scr-setup");
    stopPolling();
  }

  function boot() {
    wire();

    if (!URL_BASE || !ANON || ANON.indexOf("PASTE_") === 0) {
      setupScreen("This deployment isn't configured yet.",
        "<p>Two setup steps are outstanding:</p><ol>" +
        "<li>Put the project's <b>publishable key</b> in <code>app/config.js</code> " +
        "(Supabase dashboard → Settings → API Keys).</li>" +
        "<li>Turn on <b>anonymous sign-ins</b> (Authentication → Sign In / Providers).</li>" +
        "</ol>");
      return;
    }

    var savedName = "";
    try { savedName = localStorage.getItem(LS_NAME) || ""; } catch (e) {}
    if (!savedName) savedName = randomName();
    $("in-name-c").value = savedName;
    $("in-name-j").value = savedName;

    // ?r=CODE deep link: prefill the code and open the join screen.
    var invite = (new URLSearchParams(location.search).get("r") || "").toUpperCase();
    if (CODE_ALPHABET.test(invite)) {
      $("in-code").value = invite;
      if (!location.hash || location.hash === "#/") location.hash = "#/join";
    }

    loadSession();
    ensureSession()
      .then(function () {
        var saved = null;
        try { saved = localStorage.getItem(LS_ROOM); } catch (e) {}
        if (!saved) { applyHash(); return; }
        // Rejoin whatever room this browser was in before a refresh. get_room_state
        // raises NOT_A_MEMBER if it is not actually in it, which poll() handles by
        // clearing the saved room and dropping back to the landing page.
        roomId = saved;
        return poll().then(function () {
          if (!last) { leaveRoom(false); return; }
          // A finished game is not somewhere to be restored INTO. Without this, every
          // later visit reopens the last game's final scoreboard instead of the
          // landing page -- and since rooms live 24 hours, that could be a day of
          // never seeing the front of your own site. Staying on the over screen
          // through a refresh moments after finishing is still fine: that path runs
          // through route(), not through here.
          if (last.state === "over") { leaveRoom(false); return; }
          enterRoom(saved);
        });
      })
      .catch(function (e) {
        var m = (e && e.message) || "";
        if (/anonymous/i.test(m) || e.status === 422) {
          setupScreen("Anonymous sign-in is turned off.",
            "<p>The game has no accounts, so every player needs an anonymous session.</p><ol>" +
            "<li>Supabase dashboard → <b>Authentication</b> → <b>Sign In / Providers</b></li>" +
            "<li>Enable <b>Allow anonymous sign-ins</b>. A warning about RLS appears — " +
            "<b>accept it</b>, or the toggle silently reverts.</li>" +
            "<li>Save, then reload this page.</li></ol>");
        } else if (e.status === 401) {
          setupScreen("That publishable key isn't valid for this project.",
            "<p>Copy it again from the Supabase dashboard → Settings → API Keys, into " +
            "<code>app/config.js</code>.</p>");
        } else {
          setupScreen("Couldn't reach the server.", "<p>" + friendly(e) + "</p>");
        }
      });
  }

  function start() { runBoot(function () {}); boot(); }

  if (document.readyState === "loading") on(document, "DOMContentLoaded", start);
  else start();
})();
