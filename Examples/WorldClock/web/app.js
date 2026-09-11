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
    empty.hidden = cities.length > 0;
    tick();
    if (inSash) sash.context.set({
      title: "World Clock",
      subtitle: cities.length ? `${cities.length} ${cities.length === 1 ? "city" : "cities"}` : "",
      commands: cities.length ? ["clock.add", "clock.copy"] : ["clock.add"]
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
    nameInput.focus();
    nameInput.select();
  }
  const openAdd = () => openDialog(null);
  dialog.addEventListener("close", () => { editing = null; });
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
    sash.on("sash:command", (c) => { if (c.id === "clock.add") openAdd(); if (c.id === "clock.copy") copyAll(); });
    sash.state.watch("settings", render);                 // the Settings window
    sash.on("sash:appearance", render);                  // the system's 24-hour switch, language, appearance
    window.addEventListener("storage", () => { cities = load(); render(); });  // another window
  }

  render();
  setInterval(tick, 1000);
  if (inSash) sash.ready();
})();
