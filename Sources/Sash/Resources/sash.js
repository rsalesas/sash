// Sash runtime. Injected at document start after `window.__SASH_BOOT__`.
// Everything the page can do is one of four things: fetch a URL, listen to
// the events stream, call a declared function, or read and write shared state.
(function () {
  "use strict";
  if (window.sash) return;
  var boot = window.__SASH_BOOT__ || {};
  try { delete window.__SASH_BOOT__; } catch (_) { window.__SASH_BOOT__ = undefined; }
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sash;

  // ---- errors and transport ------------------------------------------------
  function SashError(e) {
    var err = new Error((e && e.message) || (e && e.code) || "failed");
    err.name = "SashError";
    err.code = (e && e.code) || "failed";
    err.data = e && e.data;
    return err;
  }
  var nextID = 1;
  function call(ns, name, args) {
    if (!handler) return Promise.reject(SashError({ code: "unavailable", message: "no bridge" }));
    var payload;
    try { payload = args === undefined || args === null ? {} : JSON.parse(JSON.stringify(args)); }
    catch (e) { return Promise.reject(SashError({ code: "invalid-args", message: String(e) })); }
    return handler.postMessage({ id: nextID++, ns: ns, name: name, args: payload }).then(function (r) {
      if (r && r.ok) return r.value === undefined ? null : r.value;
      throw SashError((r && r.error) || { code: "failed", message: "malformed reply" });
    });
  }

  var core = {};
  var session = boot.session || {};
  core.version = Object.freeze(Object.assign({}, boot.version || {}));
  core.session = { id: session.id || null, route: session.route || { path: location.pathname, query: {} }, isFocused: false };
  core.platform = Object.assign({}, boot.platform || {});

  // ---- capabilities and the generated function table -----------------------
  var caps = boot.capabilities || { api: 0, namespaces: {} };
  var nsObjects = {};
  function rebuild(newCaps) {
    caps = newCaps || caps;
    core.capabilities = caps;
    var spaces = caps.namespaces || {};
    Object.keys(spaces).forEach(function (ns) {
      var obj = nsObjects[ns] || (nsObjects[ns] = {});
      (spaces[ns].calls || []).forEach(function (name) {
        if (!(name in obj)) obj[name] = function (args) { return call(ns, name, args); };
      });
    });
  }
  rebuild(caps);
  core.has = function (ns) { return !!(caps.namespaces && caps.namespaces[ns]); };

  // ---- core calls -----------------------------------------------------------
  var readyPromise = null;
  core.ready = function () {
    if (!readyPromise) readyPromise = call("sash", "ready").catch(function (e) { readyPromise = null; throw e; });
    return readyPromise;
  };
  core.open = function (url) { return call("sash", "open", { url: String(url) }); };
  core.log = function (level) {
    var parts = Array.prototype.slice.call(arguments, 1).map(function (a) {
      if (typeof a === "string") return a;
      try { return JSON.stringify(a); } catch (_) { return String(a); }
    });
    return call("sash", "log", { level: String(level), message: parts.join(" ") });
  };
  core.context = { set: function (patch) { return call("context", "set", patch || {}); } };
  core.sessions = {
    list: function () { return call("sessions", "list"); },
    send: function (to, name, payload) { return call("sessions", "send", { to: to, name: name, payload: payload === undefined ? null : payload }); },
    broadcast: function (name, payload) { return call("sessions", "broadcast", { name: name, payload: payload === undefined ? null : payload }); }
  };

  // ---- events ---------------------------------------------------------------
  var listeners = {};          // name -> [fn]
  var framework = {};          // name -> fn, runs before user listeners
  var attached = {};           // names the EventSource has listeners for
  var source = null;
  function parse(ev) {
    if (!ev || ev.data === undefined || ev.data === "") return null;
    try { return JSON.parse(ev.data); } catch (_) { return ev.data; }
  }
  function dispatch(name, ev) {
    var data = parse(ev);
    if (framework[name]) { try { framework[name](data); } catch (e) { console.error("sash:", e); } }
    var fns = listeners[name];
    if (fns) fns.slice().forEach(function (fn) { try { fn(data, name); } catch (e) { console.error("sash listener", name, e); } });
  }
  function ensureSource() {
    if (source) return source;
    source = new EventSource("/_sash/events");
    source.onerror = function () { /* EventSource reconnects on its own with Last-Event-ID */ };
    Object.keys(attached).forEach(function (n) { source.addEventListener(n, function (ev) { dispatch(n, ev); }); });
    return source;
  }
  function attach(name) {
    if (attached[name]) return;
    attached[name] = true;
    if (source) source.addEventListener(name, function (ev) { dispatch(name, ev); });
  }
  core.on = function (name, fn) {
    (listeners[name] || (listeners[name] = [])).push(fn);
    attach(name);
    ensureSource();
    return function () { core.off(name, fn); };
  };
  core.off = function (name, fn) {
    var fns = listeners[name];
    if (!fns) return;
    var i = fns.indexOf(fn);
    if (i >= 0) fns.splice(i, 1);
  };

  // ---- state ----------------------------------------------------------------
  var mirror = {};
  var bootState = boot.state || {};
  Object.keys(bootState.scopes || {}).forEach(function (s) { mirror[s] = Object.assign({}, bootState.scopes[s]); });
  var seq = bootState.seq || 0;
  var watchers = {};           // scope -> [fn(key, value)]
  var pending = [];
  var flushScheduled = false;
  function flush() {
    flushScheduled = false;
    var ops = pending; pending = [];
    if (ops.length) call("state", "apply", { ops: ops }).catch(function (e) { console.error("sash.state.apply", e); });
  }
  function queue(op) {
    pending.push(op);
    if (!flushScheduled) { flushScheduled = true; queueMicrotask(flush); }
  }
  function notify(scope, key, value) {
    var fns = watchers[scope];
    if (fns) fns.slice().forEach(function (fn) { try { fn(key, value); } catch (e) { console.error("sash.state.watch", e); } });
  }
  var state = {
    get: function (scope, key) { var s = mirror[scope]; return s && Object.prototype.hasOwnProperty.call(s, key) ? s[key] : undefined; },
    set: function (scope, key, value) {
      if (value === undefined) return state.remove(scope, key);
      (mirror[scope] || (mirror[scope] = {}))[key] = value;
      queue({ scope: scope, key: key, value: value });
      notify(scope, key, value);
    },
    remove: function (scope, key) {
      var s = mirror[scope];
      if (s && Object.prototype.hasOwnProperty.call(s, key)) delete s[key];
      queue({ scope: scope, key: key, value: null });
      notify(scope, key, undefined);
    },
    keys: function (scope) { return Object.keys(mirror[scope] || {}); },
    all: function (scope) { return Object.assign({}, mirror[scope] || {}); },
    watch: function (scope, fn) {
      (watchers[scope] || (watchers[scope] = [])).push(fn);
      ensureSource();
      return function () { var i = watchers[scope].indexOf(fn); if (i >= 0) watchers[scope].splice(i, 1); };
    },
    flush: function () { if (flushScheduled) flush(); return Promise.resolve(); }
  };
  Object.defineProperty(state, "seq", { get: function () { return seq; } });
  core.state = state;

  framework["sash:state"] = function (ch) {
    if (!ch || !ch.scope) return;
    var origin = ch.origin || {};
    if (origin.seq > seq) seq = origin.seq;
    if (origin.session && origin.session === core.session.id) return;   // our own echo
    var s = mirror[ch.scope] || (mirror[ch.scope] = {});
    var old = s[ch.key];
    if (ch.value === null || ch.value === undefined) delete s[ch.key]; else s[ch.key] = ch.value;
    notify(ch.scope, ch.key, s[ch.key]);
    if (ch.scope === "local") fireStorageEvent(ch.key, old, s[ch.key]);
  };
  function resync() {
    return fetch("/_sash/state").then(function (r) { return r.json(); }).then(function (snap) {
      seq = snap.seq || seq;
      Object.keys(snap.scopes || {}).forEach(function (scope) {
        mirror[scope] = Object.assign({}, snap.scopes[scope]);
        Object.keys(mirror[scope]).forEach(function (k) { notify(scope, k, mirror[scope][k]); });
      });
    }).catch(function (e) { console.error("sash resync", e); });
  }
  framework["sash:hello"] = function (h) {
    if (h && typeof h.storeSeq === "number" && h.storeSeq > seq) resync();
  };
  framework["sash:focus"] = function (d) { core.session.isFocused = !!(d && d.focused); };
  framework["sash:capabilities"] = function (c) { if (c) rebuild(c); };
  framework["sash:appearance"] = function (p) { Object.assign(core.platform, p || {}); applyCSSVars(); };
  ["sash:hello", "sash:state", "sash:focus", "sash:capabilities", "sash:appearance", "sash:command", "sash:message", "sash:terminate"].forEach(attach);

  // ---- localStorage shim ----------------------------------------------------
  function local() { return mirror.local || (mirror.local = {}); }
  var storage = new Proxy({}, {
    get: function (_, prop) {
      switch (prop) {
        case "getItem": return function (k) { k = String(k); var s = local(); return Object.prototype.hasOwnProperty.call(s, k) ? s[k] : null; };
        case "setItem": return function (k, v) { state.set("local", String(k), String(v)); };
        case "removeItem": return function (k) { state.remove("local", String(k)); };
        case "clear": return function () { Object.keys(local()).forEach(function (k) { state.remove("local", k); }); };
        case "key": return function (i) { var keys = Object.keys(local()); return i < keys.length ? keys[i] : null; };
        case "length": return Object.keys(local()).length;
        case Symbol.toStringTag: return "Storage";
        case "toString": return function () { return "[object Storage]"; };
      }
      if (typeof prop === "symbol") return undefined;
      var s = local();
      return Object.prototype.hasOwnProperty.call(s, prop) ? s[prop] : undefined;
    },
    set: function (_, prop, v) { if (typeof prop === "symbol") return false; state.set("local", String(prop), String(v)); return true; },
    deleteProperty: function (_, prop) { if (typeof prop === "symbol") return false; state.remove("local", String(prop)); return true; },
    has: function (_, prop) { return typeof prop !== "symbol" && Object.prototype.hasOwnProperty.call(local(), prop); },
    ownKeys: function () { return Object.keys(local()); },
    getOwnPropertyDescriptor: function (_, prop) {
      var s = local();
      if (typeof prop === "string" && Object.prototype.hasOwnProperty.call(s, prop)) {
        return { value: s[prop], writable: true, enumerable: true, configurable: true };
      }
      return undefined;
    }
  });
  var shimWhere = "none";
  (function installShim() {
    var targets = [[window, "window"], [Window.prototype, "prototype"]];
    for (var i = 0; i < targets.length; i++) {
      try {
        Object.defineProperty(targets[i][0], "localStorage", { value: storage, configurable: true, enumerable: true, writable: false });
        if (window.localStorage === storage) { shimWhere = targets[i][1]; return; }
      } catch (_) { /* try the next */ }
    }
    console.warn("sash: localStorage shim unavailable; use sash.state with scope \"local\"");
  })();
  function fireStorageEvent(key, oldValue, newValue) {
    try {
      var ev = new Event("storage");
      Object.defineProperties(ev, {
        key: { value: key }, oldValue: { value: oldValue === undefined ? null : oldValue },
        newValue: { value: newValue === undefined ? null : newValue },
        storageArea: { value: storage }, url: { value: location.href }
      });
      window.dispatchEvent(ev);
    } catch (_) {}
  }

  // ---- platform as CSS ------------------------------------------------------
  function applyCSSVars() {
    try {
      var r = document.documentElement;
      if (!r) return;
      var p = core.platform;
      if (p.accent) r.style.setProperty("--sash-accent", p.accent);
      if (p.appearance) { r.style.setProperty("--sash-appearance", p.appearance); r.setAttribute("data-sash-appearance", p.appearance); }
      r.style.setProperty("--sash-reduced-motion", p.reducedMotion ? "1" : "0");
    } catch (_) {}
  }
  applyCSSVars();

  core._diagnostics = { localStorageShim: shimWhere, bridge: !!handler };

  // ---- the public object ----------------------------------------------------
  // Unknown namespaces reject with capability-missing instead of being
  // undefined, so a typo is a clear error and `sash.has()` is the real check.
  function missing(ns) {
    return new Proxy({}, {
      get: function (_, name) {
        if (typeof name === "symbol" || name === "then" || name === "toJSON") return undefined;
        return function () { return Promise.reject(SashError({ code: "capability-missing", message: ns })); };
      }
    });
  }
  var sash = new Proxy(core, {
    get: function (t, prop) {
      if (prop in t) return t[prop];
      if (typeof prop === "symbol" || prop === "then" || prop === "toJSON") return undefined;
      if (nsObjects[prop]) return nsObjects[prop];
      return missing(prop);
    },
    has: function (t, prop) { return prop in t || !!nsObjects[prop]; },
    ownKeys: function (t) { return Object.keys(t).concat(Object.keys(nsObjects)); },
    getOwnPropertyDescriptor: function (t, prop) {
      if (prop in t) return Object.getOwnPropertyDescriptor(t, prop);
      if (nsObjects[prop]) return { value: nsObjects[prop], enumerable: true, configurable: true };
      return undefined;
    }
  });
  Object.defineProperty(window, "sash", { value: sash, writable: false, configurable: false, enumerable: true });
  ensureSource();
})();
