(() => {
  "use strict";

  const MAX_LOG_ROWS = 200;
  const RPS_WINDOW_MS = 5000;
  const MAX_SERIES_SLOTS = 8;

  /** @type {{total:number, succeeded:number, failed:number, latencySum:number, timestamps:number[]}} */
  const stats = { total: 0, succeeded: 0, failed: 0, latencySum: 0, timestamps: [] };

  /** pod name -> series slot (1-8), or 0 for the "Other" overflow bucket */
  const podSlots = new Map();
  /** pod name (or "Other") -> response count */
  const podCounts = new Map();

  let pingTimer = null;
  let curlSource = null;

  // ---------- theme ----------
  const themeToggle = document.getElementById("theme-toggle");
  function applyStoredTheme() {
    const stored = localStorage.getItem("whoami-ng-theme");
    if (stored === "light" || stored === "dark") {
      document.documentElement.setAttribute("data-theme", stored);
    }
  }
  themeToggle.addEventListener("click", () => {
    const current = document.documentElement.getAttribute("data-theme");
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    const currentlyDark = current ? current === "dark" : prefersDark;
    const next = currentlyDark ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("whoami-ng-theme", next);
  });
  applyStoredTheme();

  // ---------- whoami card ----------
  async function loadWhoami() {
    const res = await fetch("/api/whoami");
    const data = await res.json();

    const rows = [
      ["Pod name", data.podName || data.hostname],
      ["Hostname", data.hostname],
      ["Pod IP", data.podIP || "—"],
      ["Node", data.nodeName || "—"],
      ["Namespace", data.namespace || "—"],
      ["Local IPs", (data.ips || []).join(", ") || "—"],
      ["OS / Arch", `${data.os} / ${data.arch}`],
      ["Go version", data.goVersion],
      ["App version", data.version],
      ["Started", new Date(data.startTime).toLocaleString()],
      ["Uptime", data.uptime],
    ];

    const kv = document.getElementById("whoami-kv");
    kv.innerHTML = rows
      .map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd>${escapeHtml(String(v))}</dd>`)
      .join("");

    const headersBody = document.querySelector("#headers-table tbody");
    const headerEntries = Object.entries(data.request.headers || {});
    headersBody.innerHTML = headerEntries
      .map(([name, values]) => `<tr><td>${escapeHtml(name)}</td><td>${escapeHtml(values.join(", "))}</td></tr>`)
      .join("");

    // default the curl-mode target to this page's own whoami endpoint
    const curlTarget = document.getElementById("curl-target");
    if (!curlTarget.value) {
      curlTarget.value = `${window.location.origin}/api/whoami`;
    }
  }

  async function loadVersion() {
    try {
      const res = await fetch("/api/version");
      const data = await res.json();
      document.getElementById("version-badge").textContent = `v${data.version}`;
    } catch {
      // non-critical
    }
  }

  document.getElementById("refresh-whoami").addEventListener("click", loadWhoami);

  // ---------- tabs ----------
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((t) => {
        t.classList.remove("active");
        t.setAttribute("aria-selected", "false");
      });
      tab.classList.add("active");
      tab.setAttribute("aria-selected", "true");

      const mode = tab.dataset.mode;
      document.querySelectorAll(".gen-form").forEach((form) => {
        form.classList.toggle("hidden", form.dataset.mode !== mode);
      });
    });
  });

  // ---------- stats + chart + log ----------
  function seriesClassFor(pod) {
    const key = pod || "unknown";
    if (!podSlots.has(key)) {
      const nextSlot = podSlots.size < MAX_SERIES_SLOTS ? podSlots.size + 1 : 0;
      podSlots.set(key, nextSlot);
    }
    const slot = podSlots.get(key);
    return slot === 0 ? "series-other" : `series-${slot}`;
  }

  function bucketFor(pod) {
    const key = pod || "unknown";
    seriesClassFor(key); // ensure slot assigned before overflow decision
    return podSlots.get(key) === 0 ? "Other" : key;
  }

  function recordResult({ mode, pod, status, ok, latencyMs, error }) {
    const now = Date.now();
    stats.total += 1;
    if (ok) stats.succeeded += 1;
    else stats.failed += 1;
    stats.latencySum += latencyMs || 0;
    stats.timestamps.push(now);
    const cutoff = now - RPS_WINDOW_MS;
    while (stats.timestamps.length && stats.timestamps[0] < cutoff) stats.timestamps.shift();

    const bucket = bucketFor(pod);
    podCounts.set(bucket, (podCounts.get(bucket) || 0) + 1);

    addLogRow({ time: now, mode, pod: pod || "unknown", status, ok, latencyMs, error });
    renderStats();
    renderChart();
  }

  function renderStats() {
    document.getElementById("stat-total").textContent = stats.total.toLocaleString();
    document.getElementById("stat-success").textContent =
      stats.total > 0 ? `${Math.round((stats.succeeded / stats.total) * 100)}%` : "—";
    document.getElementById("stat-latency").textContent =
      stats.total > 0 ? `${(stats.latencySum / stats.total).toFixed(1)} ms` : "—";
    const rps = stats.timestamps.length / (RPS_WINDOW_MS / 1000);
    document.getElementById("stat-rps").textContent = rps.toFixed(1);
  }

  function renderChart() {
    const chart = document.getElementById("pod-chart");
    if (podCounts.size === 0) {
      chart.innerHTML = `<span class="bar-chart-empty">No traffic yet — start pinging or curling to see which pod answers.</span>`;
      return;
    }
    const max = Math.max(...podCounts.values());
    const entries = [...podCounts.entries()].sort((a, b) => {
      if (a[0] === "Other") return 1;
      if (b[0] === "Other") return -1;
      return b[1] - a[1];
    });

    chart.innerHTML = entries
      .map(([pod, count]) => {
        const pct = Math.max((count / max) * 100, 2);
        const cls = pod === "Other" ? "series-other" : seriesClassFor(pod);
        return `
          <div class="bar-item">
            <span class="bar-value">${count}</span>
            <div class="bar-fill ${cls}" style="height:${pct}%" title="${escapeHtml(pod)}: ${count} responses"></div>
            <span class="bar-name" title="${escapeHtml(pod)}">${escapeHtml(pod)}</span>
          </div>`;
      })
      .join("");
  }

  function statusBucket(status, error) {
    if (error || !status) return "critical";
    if (status >= 500) return "critical";
    if (status >= 400) return "serious";
    if (status >= 300) return "good";
    if (status >= 200) return "good";
    return "warning";
  }

  function addLogRow({ time, mode, pod, status, ok, latencyMs, error }) {
    const tbody = document.getElementById("log-body");
    const bucket = statusBucket(status, error);
    const statusLabel = error ? "ERR" : status;
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>${new Date(time).toLocaleTimeString()}</td>
      <td>${mode}</td>
      <td>${escapeHtml(pod)}</td>
      <td><span class="status-pill"><span class="status-dot ${bucket}"></span>${escapeHtml(String(statusLabel))}</span></td>
      <td>${latencyMs != null ? latencyMs.toFixed(1) + " ms" : "—"}</td>
    `;
    tbody.insertBefore(row, tbody.firstChild);
    while (tbody.rows.length > MAX_LOG_ROWS) tbody.deleteRow(-1);
  }

  document.getElementById("reset-stats").addEventListener("click", () => {
    stats.total = 0;
    stats.succeeded = 0;
    stats.failed = 0;
    stats.latencySum = 0;
    stats.timestamps.length = 0;
    podSlots.clear();
    podCounts.clear();
    document.getElementById("log-body").innerHTML = "";
    renderStats();
    renderChart();
  });

  // ---------- ping mode (client-side) ----------
  const pingForm = document.getElementById("ping-form");
  const pingStart = document.getElementById("ping-start");
  const pingStop = document.getElementById("ping-stop");

  async function pingOnce() {
    const start = performance.now();
    try {
      const res = await fetch("/api/whoami", { cache: "no-store" });
      const latencyMs = performance.now() - start;
      const data = await res.json().catch(() => ({}));
      recordResult({
        mode: "ping",
        pod: data.podName || data.hostname,
        status: res.status,
        ok: res.ok,
        latencyMs,
      });
    } catch (err) {
      recordResult({
        mode: "ping",
        pod: undefined,
        status: undefined,
        ok: false,
        latencyMs: performance.now() - start,
        error: String(err),
      });
    }
  }

  pingForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const intervalMs = Math.max(50, Number(new FormData(pingForm).get("intervalMs")) || 500);
    if (pingTimer) clearInterval(pingTimer);
    pingOnce();
    pingTimer = setInterval(pingOnce, intervalMs);
    pingStart.disabled = true;
    pingStop.disabled = false;
  });

  pingStop.addEventListener("click", () => {
    if (pingTimer) clearInterval(pingTimer);
    pingTimer = null;
    pingStart.disabled = false;
    pingStop.disabled = true;
  });

  // ---------- curl mode (server-side SSE) ----------
  const curlForm = document.getElementById("curl-form");
  const curlStart = document.getElementById("curl-start");
  const curlStop = document.getElementById("curl-stop");

  curlForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const fd = new FormData(curlForm);
    const params = new URLSearchParams({
      target: String(fd.get("target") || ""),
      count: String(fd.get("count") || 30),
      concurrency: String(fd.get("concurrency") || 5),
      delayMs: String(fd.get("delayMs") || 150),
    });

    if (curlSource) curlSource.close();
    curlSource = new EventSource(`/api/generate/stream?${params.toString()}`);

    curlStart.disabled = true;
    curlStop.disabled = false;

    curlSource.addEventListener("result", (evt) => {
      const r = JSON.parse(evt.data);
      recordResult({
        mode: "curl",
        pod: r.pod,
        status: r.status,
        ok: r.ok,
        latencyMs: r.latencyMs,
        error: r.error,
      });
    });

    curlSource.addEventListener("done", () => {
      stopCurl();
    });

    curlSource.onerror = () => {
      stopCurl();
    };
  });

  function stopCurl() {
    if (curlSource) curlSource.close();
    curlSource = null;
    curlStart.disabled = false;
    curlStop.disabled = true;
  }

  curlStop.addEventListener("click", stopCurl);

  // ---------- utils ----------
  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // ---------- init ----------
  loadWhoami();
  loadVersion();
  renderStats();
  renderChart();
})();
