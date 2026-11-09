(function () {
  "use strict";

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // ── SQL blocks: split sql/trade_surveillance.sql on "-- [step:<id>]" markers ──
  function splitSteps(sql) {
    var steps = {};
    var parts = sql.split(/^-- \[step:([a-z_-]+)\]\s*$/m);
    for (var i = 1; i < parts.length; i += 2) steps[parts[i]] = parts[i + 1].trim();
    return steps;
  }

  function renderCode(el, code) {
    el.innerHTML =
      '<div class="code-bar"><span class="code-lang">SQL</span>' +
      '<button class="copy-btn" type="button">Copy</button></div>' +
      '<pre class="language-sql"><code class="language-sql"></code></pre>';
    var codeEl = el.querySelector("code");
    codeEl.textContent = code;
    if (window.Prism) Prism.highlightElement(codeEl);
    el.querySelector(".copy-btn").addEventListener("click", function () {
      var btn = this;
      copyText(code).then(function () {
        btn.textContent = "Copied!";
        btn.classList.add("copied");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1800);
      });
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    return Promise.resolve();
  }

  var loadErr = '<div class="code-loading">Could not load content. If you opened this file directly, serve the folder over HTTP (e.g. <code>python3 -m http.server</code>).</div>';

  fetch("sql/trade_surveillance.sql")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
    .then(function (sql) {
      var steps = splitSteps(sql);
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) {
        var code = steps[el.getAttribute("data-step")];
        if (code) renderCode(el, code);
      });
    })
    .catch(function () {
      document.querySelectorAll(".code-wrap[data-step]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Result tables from data/sample_results.json ──
  function wrap(head, body) {
    return '<div class="table-scroll"><table class="results-table"><thead><tr>' +
      head.map(function (c) { return "<th>" + esc(c) + "</th>"; }).join("") +
      "</tr></thead><tbody>" + body + "</tbody></table></div>";
  }
  function n(v) { return Number(v).toLocaleString(); }
  function ruleChip(r) { return '<span class="rule-chip rule-' + r.toLowerCase() + '">' + esc(r) + "</span>"; }
  function sev(s) { return '<span class="sev ' + (s >= 90 ? "sev-high" : s >= 80 ? "sev-med" : "sev-low") + '">' + s + "</span>"; }
  function status(s) { return '<span class="chg chg-' + (s === "CANCELLED" ? "delete" : "insert") + '">' + esc(s) + "</span>"; }

  var render = {
    blotter: function (d) {
      var body = d.blotter.map(function (b) {
        return '<tr data-planted="' + (b.order_id >= 900000 ? "1" : "0") + '"><td class="num">' + esc(b.time) + '</td><td class="col-name">' +
          esc(b.trader) + '</td><td class="col-name">' + esc(b.account) + "</td><td>" + esc(b.side) + '</td><td class="num">' + n(b.qty) +
          '</td><td class="num">' + b.price.toFixed(2) + "</td><td>" + status(b.status) + "</td></tr>";
      }).join("");
      return wrap(["Time", "Trader", "Account", "Side", "Qty", "Price", "Status"], body) +
        '<button class="reveal-btn" type="button" data-reveal>Reveal the spoofing orders</button>';
    },
    funnel: function (d) {
      var alerts = d.noise.reduce(function (a, r) { return a + r.alerts; }, 0);
      return '<div class="funnel"><div><div class="big-num">' + n(d.totals.orders) + '</div><span>Orders scanned</span></div>' +
        '<div><div class="big-num">' + n(d.totals.executions) + '</div><span>Executions</span></div>' +
        '<div><div class="big-num">' + n(d.totals.cancelled) + '</div><span>Cancels</span></div>' +
        '<div><div class="big-num" style="color:#B4232C">' + alerts + "</div><span>Alerts to review</span></div></div>" +
        wrap(["Rule", "Orders scanned", "Alerts"], d.noise.map(function (r) {
          return "<tr><td>" + ruleChip(r.rule) + '</td><td class="num">' + n(r.orders_scanned) + '</td><td class="num"><strong>' + r.alerts + "</strong></td></tr>";
        }).join(""));
    },
    queue: function (d) {
      return wrap(["Alert", "Rule", "Severity", "Trader", "Ticker", "Time", "Explanation"], d.queue.map(function (a) {
        return '<tr><td class="col-name">' + esc(a.alert_id) + "</td><td>" + ruleChip(a.rule) + "</td><td>" + sev(a.severity) +
          '</td><td class="col-name">' + esc(a.trader) + '</td><td class="col-name">' + esc(a.ticker) + '</td><td class="num">' +
          esc(a.time) + '</td><td class="wrap">' + esc(a.explanation) + "</td></tr>";
      }).join(""));
    },
    rule: function (d, el) {
      var rule = el.getAttribute("data-rule");
      var rows = d.queue.filter(function (a) { return a.rule === rule; })
                        .sort(function (a, b) { return a.alert_id < b.alert_id ? -1 : 1; });
      return wrap(["Alert", "Severity", "Trader", "Ticker", "Time", "Explanation"], rows.map(function (a) {
        return '<tr><td class="col-name">' + esc(a.alert_id) + "</td><td>" + sev(a.severity) + '</td><td class="col-name">' +
          esc(a.trader) + '</td><td class="col-name">' + esc(a.ticker) + '</td><td class="num">' + esc(a.time) +
          '</td><td class="wrap">' + esc(a.explanation) + "</td></tr>";
      }).join(""));
    },
    "case": function (d) {
      return wrap(["Time", "Event", "Side", "Qty", "Price", "Order"], d["case"].map(function (c) {
        var cls = c.event === "CANCELLED" ? "chg-delete" : c.event === "FILLED" ? "chg-insert" : "chg-update";
        return '<tr><td class="num">' + esc(c.time) + '</td><td><span class="chg ' + cls + '">' + esc(c.event) + "</span></td><td>" +
          esc(c.side) + '</td><td class="num">' + n(c.qty) + '</td><td class="num">' + c.price.toFixed(2) + '</td><td class="num">' + c.order_id + "</td></tr>";
      }).join(""));
    },
    dynamic: function (d) {
      var rules = Object.keys(d.dynamic.after).sort();
      var t = wrap(["Rule", "Before new orders", "After refresh"], rules.map(function (r) {
        var b = d.dynamic.before[r] || 0, a = d.dynamic.after[r];
        return "<tr" + (a !== b ? ' class="flag"' : "") + "><td>" + ruleChip(r) + '</td><td class="num">' + b +
          '</td><td class="num"><strong>' + a + "</strong>" + (a !== b ? ' <span class="delta-up">+' + (a - b) + "</span>" : "") + "</td></tr>";
      }).join(""));
      var h = wrap(["Refresh", "State", "Action", "Trigger"], d.dynamic.history.map(function (x, i) {
        return '<tr><td class="num">' + (d.dynamic.history.length - i) + "</td><td>" + esc(x.state) + '</td><td class="col-name">' +
          esc(x.action) + '</td><td class="col-name">' + esc(x.trigger) + "</td></tr>";
      }).join(""));
      return t + '<h3 class="table-title">Refresh history</h3>' + h;
    },
    masking: function (d) {
      function tbl(rows) {
        return wrap(["Alert", "Rule", "Trader", "Account", "Ticker"], rows.map(function (r) {
          return '<tr><td class="col-name">' + esc(r.ALERT_ID) + "</td><td>" + ruleChip(r.RULE) + '</td><td class="col-name">' +
            esc(r.TRADER_ID) + '</td><td class="col-name">' + esc(r.ACCOUNT_ID) + '</td><td class="col-name">' + esc(r.TICKER) + "</td></tr>";
        }).join(""));
      }
      return '<div class="ba-grid"><div><h4><span class="role-chip role-admin">SURV_ANALYST</span></h4>' + tbl(d.masking.analyst) +
        '</div><div><h4><span class="role-chip role-analyst">SURV_REVIEWER</span></h4>' + tbl(d.masking.reviewer) + "</div></div>";
    }
  };

  fetch("data/sample_results.json")
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (d) {
      document.querySelectorAll(".results[data-results]").forEach(function (el) {
        var fn = render[el.getAttribute("data-results")];
        if (fn) el.innerHTML = fn(d, el);
      });
      document.querySelectorAll("[data-reveal]").forEach(function (b) {
        b.addEventListener("click", function () {
          var rows = b.parentNode.querySelectorAll('tr[data-planted="1"]');
          var on = !b.classList.contains("on");
          rows.forEach(function (r) { r.classList.toggle("planted", on); });
          b.classList.toggle("on", on);
          b.textContent = on ? "Hide" : "Reveal the spoofing orders";
        });
      });
    })
    .catch(function () {
      document.querySelectorAll(".results[data-results]").forEach(function (el) { el.innerHTML = loadErr; });
    });

  // ── Mobile Nav ──
  var btn = document.querySelector(".nav-hamburger");
  var links = document.querySelector(".nav-links");
  btn.addEventListener("click", function () {
    var open = links.classList.toggle("open");
    btn.classList.toggle("open", open);
    btn.setAttribute("aria-expanded", String(open));
  });
  links.querySelectorAll("a").forEach(function (a) {
    a.addEventListener("click", function () {
      links.classList.remove("open");
      btn.classList.remove("open");
      btn.setAttribute("aria-expanded", "false");
    });
  });

  // ── Nav Scroll Shadow ──
  var nav = document.getElementById("navbar");
  window.addEventListener("scroll", function () {
    nav.classList.toggle("scrolled", window.scrollY > 10);
  }, { passive: true });

  // ── Reveal on Scroll ──
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches && "IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("visible"); observer.unobserve(e.target); }
      });
    }, { threshold: 0.08, rootMargin: "0px 0px -40px 0px" });
    document.querySelectorAll(".reveal").forEach(function (el) { observer.observe(el); });
  } else {
    document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("visible"); });
  }
})();
