// Shared helpers for the admin and crew pages.
(function () {
  const cfg = window.DD_CONFIG || {};
  const ready = !!(cfg.url && cfg.key && window.supabase);
  const sb = ready ? window.supabase.createClient(cfg.url, cfg.key) : null;

  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const money = (n) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(n) || 0);
  const num = (n) => { const v = Number(n) || 0; return Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100); };

  function today() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  }
  function fmtDate(iso) {
    if (!iso) return "";
    const [y, m, d] = iso.split("-").map(Number);
    return new Date(y, m - 1, d).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  }
  function fmtTime(t) {
    if (!t) return "";
    let [h, m] = t.split(":").map(Number);
    const ap = h >= 12 ? "PM" : "AM";
    h = h % 12 || 12;
    return `${h}:${String(m).padStart(2, "0")} ${ap}`;
  }
  function calcHours(start, end) {
    if (!start || !end || start === end) return 0;
    const toMin = (t) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; };
    let mins = toMin(end) - toMin(start);
    if (mins < 0) mins += 1440;
    return Math.round((mins / 60) * 100) / 100;
  }

  let toastTimer;
  function toast(msg) {
    let el = document.querySelector(".toast");
    if (!el) { el = document.createElement("div"); el.className = "toast"; document.body.appendChild(el); }
    el.textContent = msg;
    el.style.display = "block";
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (el.style.display = "none"), 2600);
  }

  // Bottom sheet. html = inner markup; onMount(sheetEl, close) wires it up.
  function sheet(html, onMount) {
    const bg = document.createElement("div");
    bg.className = "sheet-bg";
    bg.innerHTML = `<div class="sheet" role="dialog" aria-modal="true">${html}</div>`;
    const close = () => bg.remove();
    bg.addEventListener("click", (e) => { if (e.target === bg) close(); });
    document.body.appendChild(bg);
    onMount && onMount(bg.querySelector(".sheet"), close);
    return close;
  }

  function friendlyError(err) {
    const m = (err && (err.message || err.error_description)) || "Something went wrong";
    if (/Invalid login/i.test(m)) return "Wrong email or password.";
    if (/Email not confirmed/i.test(m)) return "Check your email and tap the confirm link first.";
    if (/already registered/i.test(m)) return "That email already has an account. Sign in instead.";
    if (/Password should be/i.test(m)) return "Password needs at least 6 characters.";
    return m;
  }

  // Sign-in / create-account screen. onDone() runs after a session exists.
  function authScreen(root, { title, note, onDone }) {
    let mode = "in";
    const draw = () => {
      root.innerHTML = `
        <div class="center-box">
          <div class="brand" style="font-size:22px">Didi's Dogs<small>${esc(title)}</small></div>
          <p class="sub" style="margin-top:12px">${esc(note || "")}</p>
          <form id="authForm">
            ${mode === "up" ? `<label for="aName">Your name</label><input id="aName" autocomplete="name" required>` : ""}
            <label for="aEmail">Email</label>
            <input id="aEmail" type="email" autocomplete="email" required>
            <label for="aPass">Password</label>
            <input id="aPass" type="password" autocomplete="${mode === "up" ? "new-password" : "current-password"}" minlength="6" required>
            <div style="height:16px"></div>
            <button class="btn full" type="submit">${mode === "up" ? "Create account" : "Sign in"}</button>
          </form>
          <p class="muted" style="text-align:center;margin-top:16px">
            ${mode === "up" ? "Have an account?" : "New here?"}
            <button class="link" id="swap" style="color:var(--text);font-weight:600">${mode === "up" ? "Sign in" : "Create account"}</button>
          </p>
        </div>`;
      root.querySelector("#swap").onclick = () => { mode = mode === "up" ? "in" : "up"; draw(); };
      root.querySelector("#authForm").onsubmit = async (e) => {
        e.preventDefault();
        const btn = e.target.querySelector("button[type=submit]");
        btn.disabled = true;
        const email = root.querySelector("#aEmail").value.trim();
        const password = root.querySelector("#aPass").value;
        try {
          if (mode === "up") {
            const name = root.querySelector("#aName").value.trim();
            const { data, error } = await sb.auth.signUp({ email, password, options: { data: { name } } });
            if (error) throw error;
            if (!data.session) {
              toast("Check your email and tap the confirm link, then sign in.");
              mode = "in"; draw(); return;
            }
          } else {
            const { error } = await sb.auth.signInWithPassword({ email, password });
            if (error) throw error;
          }
          onDone();
        } catch (err) {
          toast(friendlyError(err));
          btn.disabled = false;
        }
      };
    };
    draw();
  }

  function notConnected(root) {
    root.innerHTML = `<div class="center-box"><div class="brand" style="font-size:22px">Didi's Dogs</div>
      <p class="sub" style="margin-top:12px">Not connected to the database yet. Add the Supabase URL and key in <b>config.js</b>.</p></div>`;
  }

  async function loadMe() {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return null;
    const { data, error } = await sb.from("profiles").select("*").eq("id", user.id).maybeSingle();
    if (error) throw error;
    return data;
  }

  window.DD = { sb, ready, esc, money, num, today, fmtDate, fmtTime, calcHours, toast, sheet, friendlyError, authScreen, notConnected, loadMe };
})();
