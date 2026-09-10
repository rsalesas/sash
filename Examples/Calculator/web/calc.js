// A calculator. Nothing here knows it is inside an app except the two lines
// at the bottom, and it runs unchanged in a browser.
(function () {
  const display = document.getElementById("display");
  let current = "0", previous = null, operator = null, fresh = true;

  const show = () => { display.textContent = current.length > 12 ? Number(current).toPrecision(8) : current; };
  const apply = (a, op, b) => {
    a = Number(a); b = Number(b);
    switch (op) { case "+": return a + b; case "-": return a - b; case "*": return a * b; case "/": return b === 0 ? NaN : a / b; }
    return b;
  };
  const format = (n) => Number.isFinite(n) ? String(Number(n.toFixed(10))) : "Error";

  function digit(d) { current = fresh || current === "0" ? d : current + d; fresh = false; show(); }
  function dot() { if (fresh) { current = "0."; fresh = false; } else if (!current.includes(".")) current += "."; show(); }
  function op(o) {
    if (operator && !fresh) current = format(apply(previous, operator, current));
    previous = current; operator = o; fresh = true; show(); highlight();
  }
  function equals() {
    if (operator) { current = format(apply(previous, operator, current)); operator = null; previous = null; fresh = true; show(); highlight(); }
  }
  function clear() { current = "0"; previous = null; operator = null; fresh = true; show(); highlight(); }
  function negate() { if (current !== "0") { current = current.startsWith("-") ? current.slice(1) : "-" + current; show(); } }
  function percent() { current = format(Number(current) / 100); show(); }
  function highlight() {
    document.querySelectorAll("button.op").forEach(b => b.classList.toggle("active", b.dataset.op === operator));
  }

  document.getElementById("keys").addEventListener("click", (e) => {
    const b = e.target.closest("button"); if (!b) return;
    if (b.dataset.digit) digit(b.dataset.digit);
    else if (b.dataset.op) op(b.dataset.op);
    else ({ clear, negate, percent, dot, equals })[b.dataset.action]();
  });

  const keys = { Enter: "equals", "=": "equals", Escape: "clear", Backspace: "clear", ".": "dot", ",": "dot", "%": "percent" };
  window.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey) return;
    let target = null;
    if (/^[0-9]$/.test(e.key)) { digit(e.key); target = `[data-digit="${e.key}"]`; }
    else if ("+-*/".includes(e.key)) { op(e.key); target = `[data-op="${e.key}"]`; }
    else if (keys[e.key]) { ({ clear, negate, percent, dot, equals })[keys[e.key]](); target = `[data-action="${keys[e.key]}"]`; }
    else return;
    e.preventDefault();
    const b = document.querySelector(target);
    if (b) { b.classList.add("pressed"); setTimeout(() => b.classList.remove("pressed"), 90); }
  });

  show();
  if (window.sash) { sash.context.set({ title: "Calculator" }); sash.ready(); }
})();
