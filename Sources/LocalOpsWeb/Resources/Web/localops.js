"use strict";

const state = { overview: null, filter: "all", query: "" };
const $ = (id) => document.getElementById(id);
const statusText = { healthy: "健康", degraded: "性能下降", unhealthy: "异常", unknown: "未检查" };
const sourceText = { registered: "已登记 · 只读展示", discovered: "待登记 · 只读", history: "最近掉线 · 只读" };
const thermalText = { nominal: "正常", fair: "偏热", serious: "严重", critical: "临界", unknown: "未知" };

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
  if (days) return `${days} 天 ${hours} 小时`;
  if (hours) return `${hours} 小时 ${minutes % 60} 分钟`;
  return `${minutes} 分钟`;
}

function serviceCard(service) {
  const card = element("article", "service-card");
  const head = element("div", "card-head");
  const title = element("div");
  title.append(element("h3", "", service.name), element("p", "description", service.description || service.group));
  head.append(title, element("span", `status ${service.health}`, statusText[service.health] || service.health));
  card.append(head);

  const meta = element("div", "meta");
  meta.append(element("span", "", service.group));
  if (service.pid) meta.append(element("span", "", `PID ${service.pid}`));
  if (service.latency_ms !== null && service.latency_ms !== undefined) meta.append(element("span", "", `${service.latency_ms} ms`));
  if (service.memory_mb) meta.append(element("span", "", `${service.memory_mb} MB`));
  const endpoint = service.endpoints && service.endpoints[0];
  if (endpoint) {
    try { meta.append(element("span", "", `:${new URL(endpoint.url).port || (new URL(endpoint.url).protocol === "https:" ? "443" : "80")}`)); }
    catch (_) { /* malformed entries are shown without a port */ }
  }
  card.append(meta);
  if (service.message) card.append(element("p", "message", service.message));

  const actions = element("div", "card-actions");
  actions.append(element("span", "source", sourceText[service.source] || "只读"));
  if (endpoint && /^https?:\/\//.test(endpoint.url)) {
    const link = element("a", "endpoint", `打开${endpoint.name ? " " + endpoint.name : ""} ↗`);
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
  const { summary, system, services, events, refreshed_at: refreshedAt, error } = state.overview;
  $("total").textContent = summary.total;
  $("healthy").textContent = summary.healthy;
  $("attention").textContent = summary.attention;
  $("discovered").textContent = summary.discovered;
  $("memory").textContent = system.memory_total_gb ? `${system.memory_used_gb}/${system.memory_total_gb} GB` : "—";
  $("disk").textContent = system.disk_total_gb ? `${system.disk_free_gb}/${system.disk_total_gb} GB` : "—";
  $("thermal").textContent = thermalText[system.thermal_state] || "未知";
  $("thermal").className = `thermal-${system.thermal_state || "unknown"}`;
  $("cpu-load").textContent = `${Number(system.cpu_load_one_minute || 0).toFixed(2)} / ${system.logical_processor_count || "—"} 核`;
  $("uptime").textContent = formatUptime(system.uptime_seconds);
  $("refresh-state").textContent = `更新于 ${formatDate(refreshedAt)}`;
  $("error").hidden = !error;
  $("error").textContent = error || "";

  const query = state.query.toLowerCase();
  const visible = services.filter((service) => {
    const filterMatches = state.filter === "all" || service.source === state.filter;
    const haystack = `${service.name} ${service.group} ${service.description} ${JSON.stringify(service.endpoints || [])}`.toLowerCase();
    return filterMatches && haystack.includes(query);
  });
  const container = $("services");
  container.replaceChildren(...visible.map(serviceCard));
  $("empty").hidden = visible.length !== 0;

  const eventNodes = (events || []).slice(0, 12).map((event) => {
    const row = element("div", "event");
    const time = element("time", "", formatDate(event.occurred_at));
    const service = element("span", "event-service", event.service_name);
    row.append(time, service, element("span", "", event.message));
    return row;
  });
  $("events").replaceChildren(...eventNodes);
  if (!eventNodes.length) $("events").append(element("div", "event", "暂无状态变化。"));
}

async function refresh() {
  try {
    const response = await fetch("/api/v1/overview", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.overview = await response.json();
    render();
  } catch (error) {
    $("refresh-state").textContent = "LocalOps 暂时无法连接";
    $("error").hidden = false;
    $("error").textContent = error.message;
  }
}

$("filters").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-filter]");
  if (!button) return;
  state.filter = button.dataset.filter;
  document.querySelectorAll("#filters button").forEach((item) => item.classList.toggle("active", item === button));
  render();
});
$("search").addEventListener("input", (event) => { state.query = event.target.value.trim(); render(); });

refresh();
setInterval(refresh, 15000);
