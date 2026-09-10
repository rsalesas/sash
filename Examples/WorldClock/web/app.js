// World Clock. Cities live in localStorage, which Sash backs with the app's
// UserDefaults; "show seconds" lives in the settings scope, which the Settings
// window edits too; 12- or 24-hour time follows the system, which Sash
// reports in sash.platform. Commands arrive from the toolbar and the menu.
(function () {
  const list = document.getElementById("clocks");
  const empty = document.getElementById("empty");
  const count = document.getElementById("count");
  const dialog = document.getElementById("add");
  const form = document.getElementById("addForm");

  const inSash = !!window.sash;
  const setting = (k, d) => inSash ? (sash.state.get("settings", k) ?? d) : d;

  let cities = load();
  function load() { try { return JSON.parse(localStorage.getItem("cities") || "[]"); } catch { return []; } }
  function save() { localStorage.setItem("cities", JSON.stringify(cities)); render(); }

  const zones = (Intl.supportedValuesOf ? Intl.supportedValuesOf("timeZone") : []);
  document.getElementById("zones").innerHTML = zones.map(z => `<option value="${z}">`).join("");

  // The locale alone does not say whether the user wants 24-hour time; the
  // system setting does, and Sash passes it through as platform.hourCycle.
  const locale = () => inSash ? sash.platform.locale : undefined;
  const hourCycle = () => inSash ? sash.platform.hourCycle : undefined;
  function fmt(tz) {
    const opts = { timeZone: tz, hour: "2-digit", minute: "2-digit" };
    if (hourCycle()) opts.hourCycle = hourCycle();
    if (setting("showSeconds", true)) opts.second = "2-digit";
    return new Intl.DateTimeFormat(locale(), opts).format(new Date());
  }
  function offset(tz) {
    const now = new Date();
    const here = now.getTimezoneOffset();
    const there = -(new Date(now.toLocaleString("en-US", { timeZone: tz })) - new Date(now.toLocaleString("en-US"))) / 60000 + here;
    const h = (here - there) / 60;
    return h === 0 ? "same time" : `${h > 0 ? "+" : ""}${Number(h.toFixed(1))} h`;
  }

  function render() {
    list.innerHTML = cities.map((c, i) => `
      <li data-i="${i}"><span><span class="name">${esc(c.name)}</span><span class="zone">${esc(c.tz)}</span></span>
      <span class="time" data-tz="${esc(c.tz)}">${fmt(c.tz)}</span><span class="offset">${offset(c.tz)}</span>
      <button class="remove" title="Remove" data-remove="${i}">✕</button></li>`).join("");
    empty.hidden = cities.length > 0;
    count.textContent = cities.length ? `${cities.length} ${cities.length === 1 ? "city" : "cities"}` : "";
    if (inSash) sash.context.set({ title: "World Clock", subtitle: cities.length ? `${cities.length} ${cities.length === 1 ? "city" : "cities"}` : "", commands: cities.length ? ["clock.add", "clock.copy"] : ["clock.add"] });
  }
  function tick() { list.querySelectorAll(".time").forEach(el => { el.textContent = fmt(el.dataset.tz); }); }
  const esc = (s) => String(s).replace(/[&<>"]/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[ch]);

  function openAdd() { form.reset(); dialog.showModal(); document.getElementById("name").focus(); }
  function copyAll() {
    const text = cities.map(c => `${c.name}: ${fmt(c.tz)}`).join("\n");
    if (inSash && sash.has("clipboard")) sash.clipboard.writeText({ text });
    else navigator.clipboard && navigator.clipboard.writeText(text);
  }

  form.addEventListener("submit", () => {
    const name = document.getElementById("name").value.trim();
    const tz = document.getElementById("tz").value.trim();
    if (!name || !tz) return;
    try { new Intl.DateTimeFormat(undefined, { timeZone: tz }); } catch { alert(`"${tz}" is not a time zone`); return; }
    cities.push({ name, tz }); save();
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
