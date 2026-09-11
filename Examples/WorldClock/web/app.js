// World Clock. Cities live in localStorage, which Sash backs with the app's
// UserDefaults; "show seconds" lives in the settings scope, which the Settings
// window edits too; 12- or 24-hour time follows the system, which Sash
// reports in sash.platform. Commands arrive from the toolbar and the menu.
(function () {
  const list = document.getElementById("clocks");
  const empty = document.getElementById("empty");
  const localEl = document.getElementById("local");
  const todayEl = document.getElementById("today");
  const nameInput = document.getElementById("name");
  const regionSel = document.getElementById("region");
  const zoneSel = document.getElementById("zone");
  const nowBtn = document.getElementById("now");
  const barEl = document.querySelector(".bar");
  const track = document.getElementById("track");
  const trackHandle = track.querySelector(".thandle");
  const trackPip = track.querySelector(".nowpip");
  const spacer = document.getElementById("spacer");
  const dialog = document.getElementById("add");
  const form = document.getElementById("addForm");

  const inSash = !!window.sash;
  const setting = (k, d) => inSash ? (sash.state.get("settings", k) ?? d) : d;
  const here = Intl.DateTimeFormat().resolvedOptions().timeZone;

  const readable = (tz) => tz.replace(/_/g, " ");
  const esc = (s) => String(s).replace(/[&<>"]/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[ch]);

  // null means live. Anything else freezes every clock at that instant, which
  // is what dragging a band does.
  let at = null;
  const nowish = () => at == null ? new Date() : new Date(at);

  let cities = load();
  function load() { try { return JSON.parse(localStorage.getItem("cities") || "[]"); } catch { return []; } }
  function save() { localStorage.setItem("cities", JSON.stringify(cities)); render(); }

  // tzdb identifiers are Region/Location — and the location is sometimes two
  // deep, as in America/Argentina/Buenos_Aires — so split on the first slash
  // only. Choosing the region first is what makes the list findable: there is
  // no America/San_Francisco, but scanning one region's worth of names to
  // land on Los Angeles is a fair ask; scanning 417 is not.
  const zones = (Intl.supportedValuesOf ? Intl.supportedValuesOf("timeZone") : []);
  const byRegion = new Map();
  for (const z of zones) {
    const cut = z.indexOf("/");
    if (cut < 0) continue;
    const region = z.slice(0, cut), place = z.slice(cut + 1);
    if (!byRegion.has(region)) byRegion.set(region, []);
    byRegion.get(region).push(place);
  }
  const placeLabel = (place) => place.replace(/_/g, " ").replace(/\//g, " / ");
  const opt = (value, label) => `<option value="${esc(value)}">${esc(label)}</option>`;

  regionSel.innerHTML = [...byRegion.keys()].sort().map(r => opt(r, r)).join("");
  function fillZones(region, selected) {
    const places = (byRegion.get(region) || []).slice().sort((a, b) => placeLabel(a).localeCompare(placeLabel(b)));
    zoneSel.innerHTML = places.map(pl => opt(pl, placeLabel(pl))).join("");
    if (selected && places.includes(selected)) zoneSel.value = selected;
  }
  regionSel.addEventListener("change", () => fillZones(regionSel.value));

  // The locale alone does not say whether the user wants 24-hour time; the
  // system setting does, and Sash passes it through as platform.hourCycle.
  const locale = () => inSash ? sash.platform.locale : undefined;
  const hourCycle = () => inSash ? sash.platform.hourCycle : undefined;

  // One fixed-shape reading of a zone, used for arithmetic rather than display.
  const wall = new Map();
  function fields(tz, at) {
    if (!wall.has(tz)) wall.set(tz, new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit"
    }));
    const o = {};
    for (const p of wall.get(tz).formatToParts(at)) o[p.type] = p.value;
    return o;
  }
  function offsetMinutes(tz, at) {
    const p = fields(tz, at);
    const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
    return Math.round((asUTC - at.getTime()) / 60000);
  }
  function offset(tz, at) {
    const h = (offsetMinutes(tz, at) - offsetMinutes(here, at)) / 60;
    return h === 0 ? "same time" : `${h > 0 ? "+" : "−"}${Number(Math.abs(h).toFixed(1))} h`;
  }
  // Which day it is there, relative to here — the thing a bare clock face hides.
  function dayTag(tz, at) {
    const a = fields(tz, at), b = fields(here, at);
    const d = Math.round((Date.UTC(+a.year, +a.month - 1, +a.day) - Date.UTC(+b.year, +b.month - 1, +b.day)) / 86400000);
    return d === 0 ? "" : d === 1 ? "tomorrow" : d === -1 ? "yesterday" : `${d > 0 ? "+" : "−"}${Math.abs(d)} days`;
  }
  // Where they are in their own day, as a fraction of the band's width.
  function markLeft(tz, when) {
    const p = fields(tz, when);
    return `${((+p.hour + +p.minute / 60 + +p.second / 3600) / 24 * 100).toFixed(3)}%`;
  }
  function wallMinutes(tz, when) { const p = fields(tz, when); return +p.hour * 60 + +p.minute; }

  // The seconds are split off so they can be set small and dim; a 12-hour
  // locale keeps its day period after them.
  function clock(tz, at) {
    const opts = { timeZone: tz, hour: "2-digit", minute: "2-digit" };
    if (hourCycle()) opts.hourCycle = hourCycle();
    if (setting("showSeconds", true)) opts.second = "2-digit";
    const ps = new Intl.DateTimeFormat(locale(), opts).formatToParts(at);
    const i = ps.findIndex(p => p.type === "second");
    if (i < 1) return { hm: ps.map(p => p.value).join(""), sec: "", ap: "" };
    return {
      hm: ps.slice(0, i - 1).map(p => p.value).join(""),
      sec: ps[i - 1].value + ps[i].value,
      ap: ps.slice(i + 1).map(p => p.value).join("")
    };
  }

  const BACK = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5h10a6 6 0 1 1-6 6"/><path d="M3.5 4v4.5H8"/></svg>';
  const X = '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg>';

  function render() {
    if (lift) return;
    const now = nowish();
    list.innerHTML = cities.map((c, i) => {
      const t = clock(c.tz, now), tag = dayTag(c.tz, now);
      return `<li data-tz="${esc(c.tz)}" data-i="${i}">
        <span><span class="name">${esc(c.name)}</span><span class="zone">${esc(readable(c.tz))}</span></span>
        <span><span class="band"><span class="mark" style="left: ${markLeft(c.tz, now)}"></span></span></span>
        <span class="rhs"><span class="time"><span class="hm">${t.hm}</span><span class="sec">${t.sec}</span><span class="ap">${t.ap}</span></span>
        <span class="off"><span class="ofs">${offset(c.tz, now)}</span> <span class="dayt">${tag}</span></span></span>
        <button class="remove" title="Remove ${esc(c.name)}" data-remove="${i}">${X}</button></li>`;
    }).join("");
    list.hidden = view === "globe";
    stage.hidden = view !== "globe";
    empty.hidden = cities.length > 0 || view === "globe";
    tick();
    publishContext();
  }

  // While the sheet is up the page handles nothing, which is what greys out a
  // toolbar it cannot reach: the buttons are bound to what the page says it
  // handles. The page's own controls are already inert — showModal sees to it.
  let modal = false;
  function publishContext() {
    if (!inSash) return;
    const commands = modal ? []
      : (cities.length ? ["clock.add", "clock.copy"] : ["clock.add"])
        .concat(view === "globe" ? ["clock.list"] : ["clock.globe"]);
    sash.context.set({
      title: "World Clock",
      subtitle: cities.length ? `${cities.length} ${cities.length === 1 ? "city" : "cities"}` : "",
      commands,
    });
  }

  // The bar carries what the window title does not: where you are and when —
  // and, once you have moved off the present, how far off and the way back.
  function bar(now) {
    const t = clock(here, now);
    localEl.textContent = `${here.split("/").pop().replace(/_/g, " ")}  ${t.hm}${t.sec}${t.ap}`;
    todayEl.textContent = new Intl.DateTimeFormat(locale(), { weekday: "short", day: "numeric", month: "short" }).format(now);
    todayEl.hidden = at != null;
    nowBtn.hidden = at == null;
    track.hidden = view !== "globe";
    spacer.hidden = view === "globe";
    barEl.classList.toggle("tracking", view === "globe");
    if (view === "globe") {
      trackHandle.style.left = `${(wallMinutes(here, now) / 1440 * 100).toFixed(3)}%`;
      trackPip.style.left = `${(wallMinutes(here, new Date()) / 1440 * 100).toFixed(3)}%`;
    }
    if (at != null) nowBtn.innerHTML = `${esc(delta())} ${BACK} Now`;
  }
  function delta() {
    const m = Math.round((at - (Date.now() - Date.now() % 60000)) / 60000);
    const a = Math.abs(m), sign = m < 0 ? "\u2212" : "+";
    return a >= 60 ? `${sign}${Math.floor(a / 60)} h${a % 60 ? ` ${a % 60} m` : ""}` : `${sign}${a} m`;
  }

  function tick() {
    const now = nowish();
    for (const li of list.querySelectorAll("li")) {
      const tz = li.dataset.tz, t = clock(tz, now);
      li.querySelector(".hm").textContent = t.hm;
      li.querySelector(".sec").textContent = t.sec;
      li.querySelector(".ap").textContent = t.ap;
      li.querySelector(".ofs").textContent = offset(tz, now);
      li.querySelector(".dayt").textContent = dayTag(tz, now);
      li.querySelector(".mark").style.left = markLeft(tz, now);
    }
    bar(now);
    drawGlobe();
  }

  // Dragging a band sets that city's wall-clock time; every other city moves
  // with it, because what moves is the instant, not the clock.
  function scrubTo(x, rect, tz, fine) {
    const real = Date.now(), w = wallMinutes(tz, new Date(real));
    const p = Math.min(1, Math.max(0, (x - rect.left) / rect.width));
    // Near the real position the thumb snaps back onto it and time runs again,
    // so coming back is the same gesture as leaving.
    if (Math.abs(p - w / 1440) * rect.width < 7) { at = null; tick(); return; }
    // The band is a day in ~128px — about eleven minutes to the pixel — so a
    // quarter hour is the finest step you can actually aim at, and it lands on
    // the hour every time. Option gives five-minute steps for the rest.
    const step = fine ? 5 : 15;
    // The last slot of the day, not the first of the next one: rounding at the
    // trailing edge reaches 1440, which is tomorrow's midnight, and the thumb
    // leaps to the far left because that instant's hour is zero.
    const mins = Math.min(1440 - step, Math.round(p * 1440 / step) * step);
    at = real - (real % 60000) + (mins - w) * 60000;
    tick();
  }
  // ---- reordering ---------------------------------------------------------
  // Rows move in the DOM as the pointer crosses them, so the list you see
  // during the move is the list you get; the array is rewritten on drop.
  let lift = null;   // { li, snapshot }
  const rowAt = (i) => list.children[i];
  const rowIndex = (li) => Array.prototype.indexOf.call(list.children, li);

  // A row interrupted mid-slide is measured where it currently looks, so the
  // new slide continues from there; one pending frame per row, or overlapping
  // moves stack up and flicker.
  const pending = new WeakMap();
  function slide(work) {
    const before = new Map();
    for (const li of list.children) before.set(li, li.getBoundingClientRect().top);
    work();
    for (const li of list.children) {
      if (lift && li === lift.li) continue;   // the held row goes straight to its slot
      const d = before.get(li) - li.getBoundingClientRect().top;
      if (!d) continue;
      if (pending.has(li)) cancelAnimationFrame(pending.get(li));
      li.style.transition = "none";
      li.style.transform = `translateY(${d}px)`;
      pending.set(li, requestAnimationFrame(() => {
        pending.delete(li);
        li.style.transition = "transform .16s ease";
        li.style.transform = "";
      }));
    }
  }
  function moveTo(index) {
    const rows = Array.prototype.slice.call(list.children);
    const to = Math.min(rows.length - 1, Math.max(0, index));
    if (rows[to] === lift.li) return;
    const from = rows.indexOf(lift.li);
    slide(() => list.insertBefore(lift.li, to > from ? rows[to].nextSibling : rows[to]));
  }
  function indexAt(clientY) {
    const n = list.children.length;
    if (!n) return 0;
    // Layout geometry, never getBoundingClientRect: a row mid-slide carries a
    // transform, and hit-testing against where it currently *looks* makes the
    // target flip back and forth every frame — the row sticks and the list
    // flashes. offsetHeight ignores transforms, so this stays still.
    const h = list.children[0].offsetHeight || 1;
    const y = clientY - list.getBoundingClientRect().top + list.scrollTop;
    return Math.max(0, Math.min(n - 1, Math.floor(y / h)));
  }
  function pickUp(li) {
    lift = { li, snapshot: cities.slice() };
    li.classList.add("lifted");
    list.classList.add("reordering");
  }
  function drop(commit) {
    if (!lift) return;
    const snapshot = lift.snapshot;
    const order = Array.prototype.map.call(list.children, (el) => +el.dataset.i);
    lift.li.classList.remove("lifted");
    list.classList.remove("reordering");
    for (const el of list.children) { el.style.transition = ""; el.style.transform = ""; }
    lift = null;
    if (commit) { cities = order.map((i) => snapshot[i]); save(); }
    else { cities = snapshot; render(); }
  }

  list.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    const band = e.target.closest(".band");
    if (band) {
      e.preventDefault();
      const li = band.closest("li"), tz = li.dataset.tz, rect = band.getBoundingClientRect();
      li.classList.add("scrubbing");
      const move = (ev) => scrubTo(ev.clientX, rect, tz, ev.altKey);
      const up = () => {
        window.removeEventListener("mousemove", move);
        window.removeEventListener("mouseup", up);
        window.removeEventListener("blur", up);
        li.classList.remove("scrubbing");
      };
      window.addEventListener("mousemove", move);
      window.addEventListener("mouseup", up);
      // Released over another app, no mouseup ever arrives; losing focus ends it.
      window.addEventListener("blur", up);
      scrubTo(e.clientX, rect, tz, e.altKey);
      return;
    }
    if (lift || e.target.closest(".remove")) return;
    const li = e.target.closest("li");
    if (!li) return;
    e.preventDefault();
    const startY = e.clientY;
    let started = false;
    const move = (ev) => {
      // A click is not a drag: wait for real travel before lifting the row.
      if (!started && Math.abs(ev.clientY - startY) < 4) return;
      if (!started) { started = true; pickUp(li); }
      moveTo(indexAt(ev.clientY));
    };
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      window.removeEventListener("blur", up);
      if (started) drop(true);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    window.addEventListener("blur", up);
  });

  // Double-click opens the row for editing — the same sheet as adding, with
  // the city's name and zone already in it.
  list.addEventListener("dblclick", (e) => {
    if (e.target.closest(".band") || e.target.closest(".remove")) return;
    const li = e.target.closest("li");
    if (li) openDialog(+li.dataset.i);
  });
  nowBtn.addEventListener("click", () => { at = null; tick(); });

  // Same gesture as a band, on your own day: drag to set the time and watch
  // the terminator move; let go near the pip and the clocks run again.
  track.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    track.setPointerCapture(e.pointerId);
    const rect = track.getBoundingClientRect();
    const move = (ev) => scrubTo(ev.clientX, rect, here, ev.altKey);
    const up = () => {
      track.removeEventListener("pointermove", move);
      track.removeEventListener("pointerup", up);
      track.removeEventListener("pointercancel", up);
    };
    track.addEventListener("pointermove", move);
    track.addEventListener("pointerup", up);
    track.addEventListener("pointercancel", up);
    scrubTo(e.clientX, rect, here, e.altKey);
  });

  // ---- the globe ----------------------------------------------------------
  // An orthographic projection drawn by hand: no library reaches this page, and
  // the maths is a dozen lines. The view frame is the projection's own frame,
  // so the same three numbers place a coastline, a city and the sun.
  const RAD = Math.PI / 180;
  const globe = document.getElementById("globe");
  const stage = document.getElementById("stage");
  const sky = document.getElementById("sky");
  let view = "list";
  let land = null, zonePoints = null;
  let spin = { lon: 0, lat: 18 };

  const canon = (tz) => { try { return new Intl.DateTimeFormat(undefined, { timeZone: tz }).resolvedOptions().timeZone; } catch { return tz; } };

  async function loadGlobeData() {
    if (land) return;
    const [l, z] = await Promise.all([fetch("land.json").then(r => r.json()), fetch("zones.json").then(r => r.json())]);
    land = l; zonePoints = z;
    // Open looking at where you are, not at the middle of the Atlantic.
    const p = zonePoints[canon(here)];
    if (p) { spin.lon = p[1]; spin.lat = Math.max(-70, Math.min(70, p[0])); }
  }

  // Position in the view's own frame: x right, y up, z toward the viewer.
  // z < 0 is the far side of the world.
  function toView(lat, lon) {
    const f = lat * RAD, l = (lon - spin.lon) * RAD, f0 = spin.lat * RAD;
    const cf = Math.cos(f), sf = Math.sin(f), cl = Math.cos(l), sl = Math.sin(l);
    const cf0 = Math.cos(f0), sf0 = Math.sin(f0);
    return { x: cf * sl, y: cf0 * sf - sf0 * cf * cl, z: sf0 * sf + cf0 * cf * cl };
  }

  // Where the sun is overhead. Declination is the usual approximation, which is
  // good to about a quarter of a degree — a pixel at this size.
  function subsolar(at) {
    const day = (at - Date.UTC(at.getUTCFullYear(), 0, 0)) / 86400000;
    const decl = 23.44 * Math.sin(2 * Math.PI * (day - 81) / 365.24);
    const hours = at.getUTCHours() + at.getUTCMinutes() / 60 + at.getUTCSeconds() / 3600;
    return { lat: decl, lon: 180 - hours * 15 };
  }

  // Land is painted into a flat lon/lat texture once, then sampled per pixel.
  // Projecting the rings directly means clipping each one to the horizon, and a
  // ring closed the wrong way round the limb fills the whole disc — which is
  // exactly what happened. Sampling cannot go wrong that way, and the shading
  // loop was already per pixel.
  const TEX_W = 1024, TEX_H = 512;
  let tex = null, texInk = "";
  function buildTexture(ocean, landFill) {
    if (tex && texInk === ocean + landFill) return;
    const c = document.createElement("canvas");
    c.width = TEX_W; c.height = TEX_H;
    const t = c.getContext("2d");
    t.fillStyle = ocean; t.fillRect(0, 0, TEX_W, TEX_H);
    t.fillStyle = landFill;
    t.beginPath();
    for (const r of land) {
      for (let k = 0; k < r.length; k += 2) {
        const x = (r[k] + 180) / 360 * TEX_W, y = (90 - r[k + 1]) / 180 * TEX_H;
        if (k === 0) t.moveTo(x, y); else t.lineTo(x, y);
      }
      t.closePath();
    }
    t.fill("evenodd");   // a polygon's inner rings are lakes, and stay ocean
    tex = t.getImageData(0, 0, TEX_W, TEX_H).data;
    texInk = ocean + landFill;
  }

  let disc = null, discCanvas = null, quality = 1;
  function drawGlobe() {
    if (!land || view !== "globe") return;
    const dpr = window.devicePixelRatio || 1;
    const w = globe.clientWidth, h = globe.clientHeight;
    if (!w || !h) return;
    if (globe.width !== Math.round(w * dpr)) { globe.width = Math.round(w * dpr); globe.height = Math.round(h * dpr); }
    const ctx = globe.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const cx = w / 2, cy = h / 2, R = Math.max(40, Math.min(w, h) / 2 - 26);
    const css = getComputedStyle(document.documentElement);
    const pick = (n, fallback) => (css.getPropertyValue(n).trim() || fallback);
    buildTexture(pick("--ocean", "#1f2a3d"), pick("--land", "#62708a"));

    const f0 = spin.lat * RAD, sf0 = Math.sin(f0), cf0 = Math.cos(f0);
    const now = nowish();
    const sun = subsolar(now);
    const s = toView(sun.lat, sun.lon);

    const size = Math.max(1, Math.round(R * 2 * dpr * quality));
    if (!discCanvas) discCanvas = document.createElement("canvas");
    if (discCanvas.width !== size) { discCanvas.width = discCanvas.height = size; disc = null; }
    const dctx = discCanvas.getContext("2d");
    if (!disc || disc.width !== size) disc = dctx.createImageData(size, size);
    const d = disc.data;
    for (let py = 0; py < size; py++) {
      const dy = 1 - (py + 0.5) * 2 / size;
      for (let px = 0; px < size; px++) {
        const dx = (px + 0.5) * 2 / size - 1;
        const r2 = dx * dx + dy * dy;
        const o = (py * size + px) * 4;
        if (r2 > 1) { d[o + 3] = 0; continue; }
        const z = Math.sqrt(1 - r2);
        // Undo the view rotation to get somewhere on the Earth.
        const lat = Math.asin(z * sf0 + dy * cf0);
        const lon = spin.lon + Math.atan2(dx, z * cf0 - dy * sf0) / RAD;
        let tx = Math.floor(((lon + 180) % 360 + 360) % 360 / 360 * TEX_W);
        let ty = Math.floor((90 - lat / RAD) / 180 * TEX_H);
        if (ty < 0) ty = 0; else if (ty >= TEX_H) ty = TEX_H - 1;
        const t0 = (ty * TEX_W + tx) * 4;

        const cosz = s.x * dx + s.y * dy + s.z * z;
        const night = Math.max(0, Math.min(1, (0.10 - cosz) / 0.30));
        // Warm at the terminator, cold well into the night: the day band, bent
        // around a sphere.
        const warm = Math.max(0, 1 - Math.abs(night - 0.42) / 0.42) * 0.55;
        const k = 1 - night * 0.72;
        d[o]     = tex[t0]     * k + warm * 150;
        d[o + 1] = tex[t0 + 1] * k + warm * 96;
        d[o + 2] = tex[t0 + 2] * k + warm * 40;
        d[o + 3] = 255;
      }
    }
    dctx.putImageData(disc, 0, 0);
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(discCanvas, cx - R, cy - R, R * 2, R * 2);

    ctx.save();
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, 7); ctx.clip();
    ctx.strokeStyle = pick("--graticule", "rgba(255,255,255,.11)"); ctx.lineWidth = 0.6;
    for (let lat = -60; lat <= 60; lat += 30) ring(ctx, cx, cy, R, (t) => toView(lat, t * 360 - 180));
    for (let lon = -180; lon < 180; lon += 30) ring(ctx, cx, cy, R, (t) => toView(t * 180 - 90, lon));
    ctx.restore();

    ctx.beginPath(); ctx.arc(cx, cy, R, 0, 7);
    ctx.strokeStyle = pick("--line", "#303036"); ctx.lineWidth = 1; ctx.stroke();

    // Cities last, so night never swallows them.
    const accent = pick("--accent", "#0a84ff"), fg = pick("--fg", "#f2f2f7"), bg = pick("--bg", "#1e1e21");
    ctx.font = "600 11px -apple-system, system-ui, sans-serif";
    ctx.textBaseline = "middle";
    // Cities four degrees apart share a dot but must not share their labels.
    const placed = [];
    const free = (x1, y1, x2, y2) => !placed.some(r => x1 < r[2] && x2 > r[0] && y1 < r[3] && y2 > r[1]);
    // The dot is the zone's own reference city, not the name you typed: your
    // "San Francisco" is plotted where America/Vancouver is. Labelling it with
    // your name would put the wrong word on the right dot. Two cities in one
    // zone are one point, so they get one label.
    const drawn = new Set();
    for (const c of cities) {
      const tz = canon(c.tz);
      if (drawn.has(tz)) continue;
      drawn.add(tz);
      const p = zonePoints[tz];
      if (!p) continue;
      const label = tz.split("/").pop().replace(/_/g, " ");
      const v = toView(p[0], p[1]);
      if (v.z < 0) continue;
      const px = cx + R * v.x, py = cy - R * v.y;
      ctx.beginPath(); ctx.arc(px, py, 3.5, 0, 7);
      ctx.fillStyle = accent; ctx.fill();
      ctx.strokeStyle = bg; ctx.lineWidth = 1.5; ctx.stroke();
      const right = px < cx;
      ctx.textAlign = right ? "left" : "right";
      const tx2 = px + (right ? 8 : -8);
      const t = clock(c.tz, now), time = t.hm + t.ap;
      ctx.font = "600 11px -apple-system, system-ui, sans-serif";
      const wide = Math.max(ctx.measureText(label).width, ctx.measureText(time).width);
      const x1 = right ? tx2 : tx2 - wide, x2 = x1 + wide;
      // Slide down, then up, until the label has somewhere of its own.
      let dy = 0;
      for (const off of [0, 15, -15, 30, -30, 45]) {
        if (free(x1, py - 13 + off, x2, py + 14 + off)) { dy = off; break; }
      }
      placed.push([x1, py - 13 + dy, x2, py + 14 + dy]);
      ctx.lineWidth = 3; ctx.strokeStyle = bg;
      ctx.strokeText(label, tx2, py - 6 + dy);
      ctx.fillStyle = fg; ctx.fillText(label, tx2, py - 6 + dy);
      ctx.font = "400 11px -apple-system, system-ui, sans-serif";
      ctx.strokeStyle = bg; ctx.strokeText(time, tx2, py + 7 + dy);
      ctx.fillStyle = fg; ctx.fillText(time, tx2, py + 7 + dy);
    }
  }

  // A sky, quietly. Fixed to the window, not to the globe: the world turns,
  // the stars do not. Most sit still; a few catch the light now and then.
  let stars = null, skyW = 0, skyH = 0, skyTimer = null;
  function makeStars(w, h) {
    let seed = 20260911;
    const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
    stars = [];
    const n = Math.round(w * h / 2400);
    for (let i = 0; i < n; i++) {
      stars.push({
        x: rnd() * w, y: rnd() * h,
        r: 0.35 + rnd() * 0.7,
        a: 0.08 + rnd() * 0.2,
        glint: i % 15 === 7,                       // a handful, not a Christmas tree
        period: 5200 + rnd() * 7000, phase: rnd() * 6.283,
      });
    }
    skyW = w; skyH = h;
  }
  function drawSky() {
    if (view !== "globe") return;
    const w = sky.clientWidth, h = sky.clientHeight;
    if (!w || !h) return;
    const dpr = window.devicePixelRatio || 1;
    if (sky.width !== Math.round(w * dpr)) { sky.width = Math.round(w * dpr); sky.height = Math.round(h * dpr); stars = null; }
    const ctx = sky.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    // On a light page a starfield is not atmosphere, it is dirt.
    if (document.documentElement.getAttribute("data-sash-appearance") !== "dark") return;
    if (!stars || skyW !== w || skyH !== h) makeStars(w, h);
    const t = performance.now();
    ctx.fillStyle = "#e8eeff";
    for (const s of stars) {
      let a = s.a, boost = 0;
      if (s.glint) {
        // A high power of a sine: mostly nothing, briefly bright.
        boost = Math.pow(Math.max(0, Math.sin(t / s.period * 6.283 + s.phase)), 28);
        a += boost * 0.7;
      }
      ctx.globalAlpha = Math.min(1, a);
      ctx.beginPath(); ctx.arc(s.x, s.y, s.r, 0, 7); ctx.fill();
      if (boost > 0.35) {
        ctx.globalAlpha = Math.min(1, boost * 0.5);
        const d = 2 + boost * 2.5;
        ctx.lineWidth = 0.6; ctx.strokeStyle = "#e8eeff";
        ctx.beginPath();
        ctx.moveTo(s.x - d, s.y); ctx.lineTo(s.x + d, s.y);
        ctx.moveTo(s.x, s.y - d); ctx.lineTo(s.x, s.y + d);
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
  }
  function runSky(on) {
    clearInterval(skyTimer); skyTimer = null;
    if (on) { drawSky(); skyTimer = setInterval(drawSky, 50); }
  }

  // A closed curve sampled in the view frame, broken where it goes behind.
  function ring(ctx, cx, cy, R, at) {
    ctx.beginPath();
    let started = false;
    for (let i = 0; i <= 120; i++) {
      const v = at(i / 120);
      if (v.z < 0) { started = false; continue; }
      const px = cx + R * v.x, py = cy - R * v.y;
      if (started) ctx.lineTo(px, py); else { ctx.moveTo(px, py); started = true; }
    }
    ctx.stroke();
  }

  // Pointer events arrive faster than a per-pixel globe can be drawn, so a draw
  // is asked for and happens once, on the next frame. Drawing straight from the
  // handler is what made it stutter.
  let globePending = false;
  function requestGlobe() {
    if (globePending) return;
    globePending = true;
    requestAnimationFrame(() => { globePending = false; drawGlobe(); });
  }
  // While it is moving the disc is rendered smaller and scaled up; a still
  // globe is worth the full resolution, a moving one is not.
  function moving(on) {
    const q = on ? 0.55 : 1;
    if (q !== quality) { quality = q; requestGlobe(); }
  }

  // A flick should carry; a drag that stopped before you let go should not.
  let glide = null;
  function coast(vx, vy) {
    cancelAnimationFrame(glide);
    moving(true);
    const step = () => {
      vx *= 0.94; vy *= 0.94;
      if (Math.abs(vx) < 0.02 && Math.abs(vy) < 0.02) { glide = null; moving(false); return; }
      spin.lon -= vx;
      spin.lat = Math.max(-89, Math.min(89, spin.lat + vy));
      drawGlobe();
      glide = requestAnimationFrame(step);
    };
    glide = requestAnimationFrame(step);
  }

  globe.addEventListener("pointerdown", (e) => {
    cancelAnimationFrame(glide); glide = null;
    globe.setPointerCapture(e.pointerId);   // the release is delivered even off-window
    globe.classList.add("spinning");
    moving(true);
    let lastX = e.clientX, lastY = e.clientY, lastT = e.timeStamp, vx = 0, vy = 0;
    const move = (ev) => {
      const k = 140 / Math.max(60, Math.min(globe.clientWidth, globe.clientHeight));
      const dx = (ev.clientX - lastX) * k, dy = (ev.clientY - lastY) * k;
      const dt = Math.max(8, ev.timeStamp - lastT);
      spin.lon -= dx;
      spin.lat = Math.max(-89, Math.min(89, spin.lat + dy));
      // Degrees per frame, from distance over time — so a pause between moves
      // brings it down instead of leaving the last value standing.
      vx = vx * 0.65 + (dx / dt) * 16 * 0.35;
      vy = vy * 0.65 + (dy / dt) * 16 * 0.35;
      lastX = ev.clientX; lastY = ev.clientY; lastT = ev.timeStamp;
      requestGlobe();
    };
    const up = (ev) => {
      // Stopped before letting go? Then it stops. Only a flick carries.
      const idle = ((ev && ev.timeStamp) || performance.now()) - lastT;
      const flick = idle < 90 && (Math.abs(vx) > 0.08 || Math.abs(vy) > 0.08);
      if (flick) coast(vx, vy); else moving(false);
      globe.removeEventListener("pointermove", move);
      globe.removeEventListener("pointerup", up);
      globe.removeEventListener("pointercancel", up);
      globe.classList.remove("spinning");
    };
    globe.addEventListener("pointermove", move);
    globe.addEventListener("pointerup", up);
    globe.addEventListener("pointercancel", up);
  });

  async function setView(next) {
    view = next;
    if (view === "globe") await loadGlobeData();
    render();
    drawGlobe();
    runSky(view === "globe");
  }

  // Adding and editing are the same sheet; `editing` says which.
  let editing = null;
  function openDialog(i) {
    editing = typeof i === "number" ? i : null;
    const c = editing == null ? null : cities[editing];
    form.reset();
    nameInput.value = c ? c.name : "";
    // A new city starts in your own region, which is usually the one you want.
    const tz = c ? c.tz : here;
    const cut = tz.indexOf("/");
    regionSel.value = cut > 0 ? tz.slice(0, cut) : regionSel.options[0]?.value ?? "";
    fillZones(regionSel.value, cut > 0 ? tz.slice(cut + 1) : undefined);
    document.getElementById("dialogTitle").textContent = c ? "Edit city" : "Add a city";
    document.getElementById("dialogPrimary").textContent = c ? "Save" : "Add";
    dialog.showModal();
    modal = true;
    publishContext();
    nameInput.focus();
    nameInput.select();
  }
  const openAdd = () => openDialog(null);
  dialog.addEventListener("close", () => { editing = null; modal = false; publishContext(); });
  function copyAll() {
    const now = nowish();
    const text = cities.map(c => { const t = clock(c.tz, now); return `${c.name}: ${t.hm}${t.sec}${t.ap}`; }).join("\n");
    if (inSash && sash.has("clipboard")) sash.clipboard.writeText({ text });
    else navigator.clipboard && navigator.clipboard.writeText(text);
  }

  form.addEventListener("submit", () => {
    const name = nameInput.value.trim(), tz = `${regionSel.value}/${zoneSel.value}`;
    if (!name || !regionSel.value || !zoneSel.value) return;
    try { new Intl.DateTimeFormat(undefined, { timeZone: tz }); } catch { alert(`"${tz}" is not a time zone`); return; }
    if (editing == null) cities.push({ name, tz });
    else cities[editing] = { name, tz };
    editing = null;
    save();
  });
  document.getElementById("cancel").addEventListener("click", () => dialog.close());
  list.addEventListener("click", (e) => {
    const b = e.target.closest("[data-remove]"); if (!b) return;
    cities.splice(Number(b.dataset.remove), 1); save();
  });
  window.addEventListener("keydown", (e) => { if (e.key === "n" && e.metaKey && !inSash) { e.preventDefault(); openAdd(); } });

  if (inSash) {
    sash.on("sash:command", (c) => {
      if (c.id === "clock.add") openAdd();
      if (c.id === "clock.copy") copyAll();
      if (c.id === "clock.globe") setView("globe");
      if (c.id === "clock.list") setView("list");
    });
    sash.state.watch("settings", render);                 // the Settings window
    sash.on("sash:appearance", render);                  // the system's 24-hour switch, language, appearance
    window.addEventListener("storage", () => { cities = load(); render(); });  // another window
  }

  render();
  setInterval(tick, 1000);
  if (inSash) sash.ready();
})();
