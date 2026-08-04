"use strict";

const state = { overview: null, filter: "all", query: "", lastError: null };
const $ = (id) => document.getElementById(id);
const statusText = { healthy: "健康", degraded: "需关注", unhealthy: "异常", unknown: "未检查" };
const sourceText = { registered: "已登记", discovered: "待登记", history: "最近掉线" };
const thermalText = { nominal: "正常", fair: "偏热", serious: "严重", critical: "临界", unknown: "未知" };
const stateText = {
  fresh: "状态最新", partial: "部分信息待确认", stale: "数据已过期",
  empty: "目录已就绪", core_error: "目录暂不可用", coreError: "目录暂不可用",
  starting: "正在准备目录"
};

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function formatDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit"
  }).format(date);
}

function formatUptime(value) {
  const minutes = Math.max(0, Math.floor(Number(value || 0) / 60));
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  if (days) return days + " 天 " + hours + " 小时";
  if (hours) return hours + " 小时 " + (minutes % 60) + " 分钟";
  return minutes + " 分钟";
}

function formatAge(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds < 0) return "数据年龄未知";
  if (seconds < 60) return "数据年龄 " + Math.floor(seconds) + " 秒";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return "数据年龄 " + minutes + " 分钟";
  return "数据年龄 " + Math.floor(minutes / 60) + " 小时";
}

function snapshotAgeSeconds(overview, typedState) {
  const metadata = overview.metadata || {};
  const timestamp = Date.parse(metadata.successful_at || overview.refreshed_at || "");
  if (Number.isFinite(timestamp)) {
    return Math.max(0, (Date.now() - timestamp) / 1000);
  }
  const fallback = Number(typedState.age_seconds);
  return Number.isFinite(fallback) && fallback >= 0 ? fallback : null;
}

function serviceKind(service) {
  return (service.typed_state && service.typed_state.kind) ||
    (service.lifecycle === "stopped" ? "offline" : service.health || "unknown");
}

function serviceCard(service) {
  const card = element("article", "service-card");
  const head = element("div", "card-head");
  const title = element("div");
  title.append(
    element("h3", "", service.name),
    element("p", "description", service.description || service.group)
  );
  const kind = serviceKind(service);
  head.append(title, element("span", "status " + kind, statusText[service.health] || kind));
  card.append(head);

  const meta = element("div", "meta");
  meta.append(element("span", "", service.group || "其他"));
  meta.append(element("span", "", sourceText[service.source] || "只读"));
  if (service.pid) meta.append(element("span", "", "PID " + service.pid));
  if (service.latency_ms !== null && service.latency_ms !== undefined) {
    meta.append(element("span", "", service.latency_ms + " ms"));
  }
  const endpoint = service.endpoints && service.endpoints[0];
  if (endpoint) {
    try {
      const url = new URL(endpoint.url);
      meta.append(element("span", "", ":" + (url.port || (url.protocol === "https:" ? "443" : "80"))));
    } catch (_) { /* malformed entries are shown without a port */ }
  }
  if (service.observation && service.observation.freshness &&
      service.observation.freshness !== "fresh") {
    meta.append(element("span", "", service.observation.freshness === "stale" ? "已过期" : "部分"));
  }
  card.append(meta);
  if (service.message) card.append(element("p", "message", service.message));

  const actions = element("div", "card-actions");
  actions.append(element("span", "source", "检查于 " + formatDate(service.checked_at)));
  if (endpoint && /^https?:\/\//.test(endpoint.url)) {
    const link = element("a", "endpoint", "打开" + (endpoint.name ? " " + endpoint.name : "") + " ↗");
    link.href = endpoint.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    actions.append(link);
  }
  card.append(actions);
  return card;
}

function render() {
  if (!state.overview) return;
  const overview = state.overview;
  const summary = overview.summary;
  const system = overview.system;
  const services = overview.services || [];
  const events = overview.events || [];
  const metadata = overview.metadata || {};
  const typedState = overview.typed_state || {};
  const rawKind = typedState.kind || metadata.freshness || "unknown";
  const kind = rawKind === "coreError" ? "core_error" : rawKind;
  const ageSeconds = snapshotAgeSeconds(overview, typedState);
  const staleAfterSeconds = Number(typedState.stale_after_seconds);
  const pastThreshold = Number.isFinite(staleAfterSeconds)
    && staleAfterSeconds >= 0
    && Number.isFinite(ageSeconds)
    && ageSeconds > staleAfterSeconds;
  const disconnected = Boolean(state.lastError);
  const stale = disconnected || kind === "stale" || pastThreshold;
  const displayKind = stale ? "stale" : kind;
  const title = disconnected
    ? "连接不可用"
    : stateText[displayKind] || stateText[rawKind] || "目录状态";
  const projectionError = state.lastError || typedState.error || overview.error;
  const ageText = formatAge(ageSeconds);
  $("state-title").textContent = title;
  $("state-detail").textContent = disconnected
    ? "LocalOps Web 连接不可用，保留上次结果。 · " + ageText
    : (
      displayKind === "stale" ? "保留上次结果，等待 LocalOps 下一次成功检查。" :
      displayKind === "core_error" ? "LocalOps 尚未完成初始化。" :
      displayKind === "empty" ? "还没有已登记或待登记的服务。" : "最近一次本机检查已完成。"
    ) + " · " + ageText;
  $("state-card").dataset.state = displayKind;
  $("total").textContent = summary.total;
  $("healthy").textContent = summary.healthy;
  $("attention").textContent = summary.attention;
  $("discovered-note").textContent = summary.discovered
    ? summary.discovered + " 个待登记监听项" : "没有待登记监听项";
  $("memory").textContent = system.memory_total_gb ? system.memory_used_gb + "/" + system.memory_total_gb + " GB" : "—";
  $("disk").textContent = system.disk_total_gb ? system.disk_free_gb + "/" + system.disk_total_gb + " GB" : "—";
  $("thermal").textContent = thermalText[system.thermal_state] || "未知";
  $("thermal").className = "thermal-" + (system.thermal_state || "unknown");
  $("cpu-load").textContent = Number(system.cpu_load_one_minute || 0).toFixed(2) +
    " / " + (system.logical_processor_count || "—") + " 核";
  $("uptime").textContent = formatUptime(system.uptime_seconds);
  $("refresh-state").textContent = disconnected
    ? "连接不可用 · " + ageText
    : displayKind === "stale"
    ? "已过期 · " + ageText
    : ageText + " · 更新于 " + formatDate(overview.refreshed_at);
  $("error").hidden = !projectionError && !state.lastError;
  $("error").textContent = projectionError || state.lastError || "";

  const query = state.query.toLowerCase();
  const visible = services.filter((service) => {
    const filterMatches = state.filter === "all" || service.source === state.filter;
    const haystack = (service.name + " " + service.group + " " + service.description +
      " " + JSON.stringify(service.endpoints || [])).toLowerCase();
    return filterMatches && haystack.includes(query);
  });
  $("services").replaceChildren(...visible.map(serviceCard));
  $("empty").hidden = visible.length !== 0;

  const eventNodes = events.slice(0, 12).map((event) => {
    const row = element("div", "event");
    row.append(
      element("time", "", formatDate(event.occurred_at)),
      element("span", "event-service", event.service_name),
      element("span", "", event.message)
    );
    return row;
  });
  $("events").replaceChildren(...eventNodes);
  if (!eventNodes.length) $("events").append(element("div", "event", "暂无状态变化。"));
}

async function refresh() {
  try {
    $("refresh-state").textContent = "正在刷新…";
    const response = await fetch("/api/v1/overview", { cache: "no-store" });
    if (!response.ok) throw new Error("HTTP " + response.status);
    state.overview = await response.json();
    state.lastError = null;
    render();
  } catch (error) {
    state.lastError = "LocalOps 暂时无法连接：" + error.message;
    if (state.overview) render();
    else $("refresh-state").textContent = "连接不可用";
    $("error").hidden = false;
    $("error").textContent = state.lastError;
  }
}

$("filters").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-filter]");
  if (!button) return;
  state.filter = button.dataset.filter;
  document.querySelectorAll("#filters button").forEach((item) => {
    const selected = item === button;
    item.classList.toggle("active", selected);
    item.setAttribute("aria-pressed", String(selected));
  });
  render();
});
$("search").addEventListener("input", (event) => {
  state.query = event.target.value.trim();
  render();
});

refresh();
setInterval(refresh, 15000);
