// PrintPlex Server — dashboard vanilla JS (pas de build step).
// Mirrors the macOS app's ContentView/ProjectCardView/SettingsView: sidebar
// filters (bibliothèque, Shopify, types 3D, catégories, tags, matériaux,
// créateurs), grille de projets avec visuels, panneau de détail, réglages.
"use strict";

// ───────────────────────── State ─────────────────────────

const state = {
  projects: [],           // [ProjectDTO] from /api/projects (list — no `files`)
  unsorted: [],           // [FileDTO] from /api/files/unsorted
  fileStats: null,        // {stl,threeMF,obj,step,other,unsorted} from /api/files/stats
  fileListCache: {},      // kind -> [FileDTO], lazily fetched for the "Types 3D" flat view
  shopifyProducts: [],    // [ShopifyProduct], only populated once a sync has happened
  shopifyConfigured: false,
  shopifyStoreDomain: "",
  printers: [],
  materials: [],
  view: "grid",           // "grid" | "project" | "settings"
  filter: { type: "all" },// {type:"all"|"todo"} | {type:"kind"|"shopify", value} | {type:"category"|"tag"|"material"|"creator"}
  selected: { category: new Set(), tag: new Set(), material: new Set(), creator: new Set() },
  collapsedGroups: new Set(),
  searchText: "",
  selectedId: null,       // open project id (view === "project")
  settingsTab: "library",
};

const FILTER_FIELDS = {
  category: { label: "Categories", icon: "📁", multivalued: false, rename: true,  getValues: (p) => (p.category ? [p.category] : []) },
  tag:      { label: "Tags",       icon: "🏷️", multivalued: true,  rename: false, getValues: (p) => p.tags || [] },
  material: { label: "Materiaux",  icon: "🧵", multivalued: true,  rename: true,  getValues: (p) => p.suggestedMaterials || [] },
  creator:  { label: "Createurs",  icon: "👤", multivalued: false, rename: true,  getValues: (p) => (p.creator ? [p.creator] : []) },
};

const FILE_KIND_LABELS = { stl: "STL", threeMF: "3MF", obj: "OBJ", step: "STEP" };
const FILE_KIND_ICON = { stl: "🧊", threeMF: "🧊", obj: "🔄", step: "📐" };
const FILE_ROLE_ICON = {
  modelPart: "🧊", renderImage: "🖼️", document: "📄", slicerConfig: "⚙️", other: "📦",
};
const SHOPIFY_STATUS_LABEL = { active: "En vente", draft: "Brouillon", archived: "Archivé", none: "Non synchronisé" };

// ───────────────────────── Formatting helpers ─────────────────────────

function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function formatBytes(n) {
  if (!n) return "0 o";
  const units = ["o", "Ko", "Mo", "Go"];
  let i = 0, v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function formatDate(iso) {
  if (!iso) return "jamais";
  const d = new Date(iso);
  return d.toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
}

const relativeTimeFormatter = new Intl.RelativeTimeFormat("fr", { numeric: "auto" });
const RELATIVE_UNITS = [
  ["year", 31536000], ["month", 2592000], ["week", 604800],
  ["day", 86400], ["hour", 3600], ["minute", 60],
];
function formatRelative(iso) {
  if (!iso) return "";
  const diffSec = Math.round((new Date(iso) - new Date()) / 1000);
  const abs = Math.abs(diffSec);
  for (const [unit, secs] of RELATIVE_UNITS) {
    if (abs >= secs) return relativeTimeFormatter.format(Math.round(diffSec / secs), unit);
  }
  return relativeTimeFormatter.format(diffSec, "second");
}

// PrintEstimate's formatted*/totalCostEur members are Swift *computed*
// properties — Codable synthesis only encodes stored ones, so the JSON
// response never has them. Recompute the same formatting here from the raw
// numeric fields (mirrors PrintEstimate's computed properties in PrintEstimator.swift).
function formatDuration(totalSeconds) {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  if (h > 0) return m > 0 ? `${h}h ${m}min` : `${h}h`;
  return `${Math.max(1, m)}min`;
}
function formatEur(n) { return `${n.toFixed(2)} €`; }

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: options.body ? { "Content-Type": "application/json" } : {},
    ...options,
  });
  if (!res.ok) {
    let reason = res.statusText;
    try { reason = (await res.json()).reason ?? reason; } catch (_) {}
    const err = new Error(reason);
    err.status = res.status;
    throw err;
  }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("application/json") ? res.json() : null;
}

// ───────────────────────── Status bar ─────────────────────────

async function refreshStatus() {
  const status = await api("/api/scan/status");
  document.getElementById("statProjects").textContent = status.projectCount;
  document.getElementById("statFiles").textContent = status.fileCount;
  document.getElementById("statScan").textContent = formatDate(status.lastScanDate);

  const pill = document.getElementById("scanPill");
  const btn = document.getElementById("btnScan");
  if (status.isScanning) {
    pill.textContent = "scan en cours…";
    pill.className = "pill scanning";
    btn.disabled = true;
  } else {
    pill.textContent = "inactif";
    pill.className = "pill";
    btn.disabled = false;
  }
  return status;
}

async function triggerScan() {
  document.getElementById("btnScan").disabled = true;
  document.getElementById("scanPill").textContent = "démarrage…";
  document.getElementById("scanPill").className = "pill scanning";
  try {
    await api("/api/scan", { method: "POST" });
  } catch (e) {
    logLine(`Erreur au déclenchement : ${e.message}`, "error");
  }
}

// ───────────────────────── Scan log (SSE) ─────────────────────────

function logLine(text, kind = "") {
  const log = document.getElementById("scanLog");
  if (log.querySelector(".empty")) log.innerHTML = "";
  const line = document.createElement("div");
  line.className = `log-line ${kind}`;
  const time = new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  line.textContent = `${time}  ${text}`;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
  while (log.children.length > 200) log.removeChild(log.firstChild);
}

function connectScanEvents() {
  const source = new EventSource("/api/scan/events");
  source.onmessage = (evt) => {
    let data;
    try { data = JSON.parse(evt.data); } catch (_) { return; }
    switch (data.type) {
      case "scanStarted":
        logLine(data.librariesCount > 0
          ? `Scan démarré (${data.librariesCount} bibliothèque${data.librariesCount === 1 ? "" : "s"})`
          : `Scan démarré — aucune bibliothèque configurée`, "start");
        break;
      case "libraryStarted":
        logLine(`📁 Bibliothèque : ${data.libraryName}`);
        break;
      case "projectDiscovered":
        logLine(`Projet : ${data.projectName}`);
        break;
      case "projectComplete":
        logLine(`✓ Projet terminé — ${data.filesFound} fichiers au total`);
        break;
      case "meshParsed":
        logLine(`Maillage analysé : ${data.path.split("/").pop()}`);
        break;
      case "scanCompleted":
        logLine(`Scan terminé — ${data.projectsFound} projets, ${data.filesFound} fichiers`, "done");
        refreshStatus();
        onLibraryChanged();
        break;
      case "error":
        logLine(`Erreur : ${data.message}`, "error");
        refreshStatus();
        break;
    }
  };
  source.onerror = () => {
    // EventSource auto-reconnects; just note it once.
  };
}

/// Reloads everything derived from the library and re-renders whatever is
/// currently on screen, without disturbing the user's place (selected
/// filters, open project, settings tab).
async function onLibraryChanged() {
  await loadLibrary();
  state.fileListCache = {};
  renderSidebar();
  if (state.view === "grid") renderGrid();
  else if (state.view === "project" && state.selectedId) openProject(state.selectedId);
  else if (state.view === "settings") openSettings(state.settingsTab);
}

// ───────────────────────── Data loading ─────────────────────────

async function loadLibrary() {
  const [projects, unsorted, fileStats, overview] = await Promise.all([
    api("/api/projects"), api("/api/files/unsorted"), api("/api/files/stats"), api("/api/settings"),
  ]);
  state.projects = projects;
  state.unsorted = unsorted;
  state.fileStats = fileStats;
  state.shopifyConfigured = overview.shopifyConfigured;
  state.shopifyStoreDomain = overview.shopifyStoreDomain;
  // Only fetch the product list once a sync has actually happened — otherwise
  // this GET would trigger a *lazy* first sync just from opening the dashboard.
  if (overview.shopifyConfigured && overview.shopifyLastSyncDate) {
    try { state.shopifyProducts = await api("/api/shopify/products"); }
    catch (_) { state.shopifyProducts = []; }
  } else {
    state.shopifyProducts = [];
  }
}

async function loadReferenceData() {
  [state.printers, state.materials] = await Promise.all([
    api("/api/printers"),
    api("/api/materials"),
  ]);
}

function selectOptionsHtml(items, selectedId) {
  return items.map((i) => `<option value="${i.id}" ${i.id === selectedId ? "selected" : ""}>${escapeHtml(i.name)}</option>`).join("");
}

// ───────────────────────── Derived data ─────────────────────────

function projectHasCompleteMetadata(p) {
  return Boolean(p.category) && Boolean(p.creator && p.creator.length)
    && (p.suggestedMaterials || []).length > 0 && (p.tags || []).length > 0;
}
function incompleteProjects() {
  return state.projects.filter((p) => !projectHasCompleteMetadata(p));
}
function missingMetadataLabels(p) {
  const missing = [];
  if (!p.category) missing.push("Catégorie");
  if (!p.creator || !p.creator.length) missing.push("Créateur");
  if (!(p.suggestedMaterials || []).length) missing.push("Matériaux");
  if (!(p.tags || []).length) missing.push("Tags");
  return missing;
}
function recentlyAdded() {
  return [...state.projects]
    .sort((a, b) => new Date(b.dateAdded) - new Date(a.dateAdded))
    .slice(0, 12);
}

function allFilterValues(key) {
  const cfg = FILTER_FIELDS[key];
  const set = new Set();
  for (const p of state.projects) for (const v of cfg.getValues(p)) set.add(v);
  return [...set].sort((a, b) => a.localeCompare(b));
}
function projectsMatchingFilter(key, selectedSet) {
  const cfg = FILTER_FIELDS[key];
  if (selectedSet.size === 0) return state.projects;
  return state.projects.filter((p) => {
    const values = cfg.getValues(p);
    return cfg.multivalued
      ? [...selectedSet].every((v) => values.includes(v))
      : values.some((v) => selectedSet.has(v));
  });
}
function visibleFilterValues(key) {
  const all = allFilterValues(key);
  const selected = state.selected[key];
  if (selected.size === 0) return all;
  const matching = projectsMatchingFilter(key, selected);
  const cfg = FILTER_FIELDS[key];
  const reachable = new Set(matching.flatMap(cfg.getValues));
  return all.filter((v) => selected.has(v) || reachable.has(v));
}
function countForCandidate(key, value) {
  const candidate = new Set(state.selected[key]);
  candidate.add(value);
  return projectsMatchingFilter(key, candidate).length;
}

function matchShopifyProduct(projectName, explicitId) {
  if (explicitId) {
    const idInt = parseInt(explicitId, 10);
    if (!Number.isNaN(idInt)) {
      const explicit = state.shopifyProducts.find((pr) => pr.id === idInt);
      if (explicit) return explicit;
    }
  }
  const name = (projectName || "").trim().toLowerCase();
  if (!name) return null;
  return state.shopifyProducts.find((pr) => {
    const title = pr.title.toLowerCase();
    return title.includes(name) || name.includes(title);
  }) || null;
}
function shopifyStatusOf(p) {
  const product = matchShopifyProduct(p.name, p.shopifyProductId);
  return product ? product.status : "none";
}
function projectsMatchingShopifyStatus(status) {
  return state.projects.filter((p) => shopifyStatusOf(p) === status);
}

/// Inverse of the "none" Shopify filter: products that exist on Shopify but
/// that no project in the library currently matches (by explicit assignment
/// or by name), i.e. products still needing a project on this side.
function unmatchedShopifyProducts() {
  const matchedIds = new Set();
  for (const p of state.projects) {
    const product = matchShopifyProduct(p.name, p.shopifyProductId);
    if (product) matchedIds.add(product.id);
  }
  return state.shopifyProducts.filter((pr) => !matchedIds.has(pr.id));
}

function projectMatchesSearch(p, query) {
  if (!query) return true;
  const q = query.toLowerCase();
  return p.name.toLowerCase().includes(q)
    || (p.tags || []).some((t) => t.toLowerCase().includes(q))
    || (p.category || "").toLowerCase().includes(q)
    || (p.creator || "").toLowerCase().includes(q);
}
function applySearch(projects) {
  const q = state.searchText.trim();
  return q ? projects.filter((p) => projectMatchesSearch(p, q)) : projects;
}

// ───────────────────────── Filter state transitions ─────────────────────────

function clearAllMultiSelects(except) {
  for (const k of Object.keys(FILTER_FIELDS)) {
    if (k !== except) state.selected[k].clear();
  }
}

function setSingleFilter(type, value) {
  state.filter = { type, value };
  clearAllMultiSelects(null);
  showGrid({ keepFilter: true });
}

function toggleMultiFilter(key, value) {
  const set = state.selected[key];
  if (set.has(value)) {
    set.delete(value);
    if (set.size === 0 && state.filter.type === key) state.filter = { type: "all" };
  } else {
    set.add(value);
    state.filter = { type: key };
    clearAllMultiSelects(key);
  }
  showGrid({ keepFilter: true });
}

function clearMultiFilter(key) {
  state.selected[key].clear();
  if (state.filter.type === key) state.filter = { type: "all" };
  showGrid({ keepFilter: true });
}

// ───────────────────────── Sidebar ─────────────────────────

function groupHtml(id, title, bodyHtml) {
  const collapsed = state.collapsedGroups.has(id);
  return `
    <div class="filter-group">
      <button class="filter-group-title ${collapsed ? "collapsed" : ""}" data-group="${id}">
        <span class="chevron">▾</span><span>${escapeHtml(title)}</span>
      </button>
      <div class="filter-group-body ${collapsed ? "collapsed" : ""}">${bodyHtml}</div>
    </div>`;
}

function filterItemHtml({ icon, label, count, active, action, value }) {
  return `<button class="filter-item ${active ? "active" : ""}" data-action="${action}" ${value != null ? `data-value="${escapeHtml(value)}"` : ""}>
    <span class="fi-icon">${icon}</span><span class="fi-label">${escapeHtml(label)}</span><span class="fi-count">${count}</span>
  </button>`;
}

function renderSidebar() {
  const nav = document.getElementById("filterNav");
  const todoCount = state.unsorted.length + incompleteProjects().length;

  let html = "";

  // Bibliothèque (not collapsible, mirrors the macOS sidebar's top section)
  html += `<div class="filter-group">`;
  html += filterItemHtml({ icon: "🗂️", label: "Tous les projets", count: state.projects.length, active: state.filter.type === "all", action: "all" });
  if (todoCount > 0) {
    html += filterItemHtml({ icon: "✅", label: "À faire", count: todoCount, active: state.filter.type === "todo", action: "todo" });
  }
  html += `</div>`;

  // Shopify — only once something has actually been synced
  if (state.shopifyProducts.length > 0) {
    const counts = {
      active: projectsMatchingShopifyStatus("active").length,
      draft: projectsMatchingShopifyStatus("draft").length,
      archived: projectsMatchingShopifyStatus("archived").length,
      none: projectsMatchingShopifyStatus("none").length,
    };
    let body = "";
    if (counts.active > 0) body += filterItemHtml({ icon: "✅", label: "En vente", count: counts.active, active: state.filter.type === "shopify" && state.filter.value === "active", action: "shopify", value: "active" });
    if (counts.draft > 0) body += filterItemHtml({ icon: "◌", label: "Brouillon", count: counts.draft, active: state.filter.type === "shopify" && state.filter.value === "draft", action: "shopify", value: "draft" });
    if (counts.archived > 0) body += filterItemHtml({ icon: "📦", label: "Archivé", count: counts.archived, active: state.filter.type === "shopify" && state.filter.value === "archived", action: "shopify", value: "archived" });
    body += filterItemHtml({ icon: "➖", label: "Non synchronisé", count: counts.none, active: state.filter.type === "shopify" && state.filter.value === "none", action: "shopify", value: "none" });
    body += filterItemHtml({ icon: "🧩", label: "Produits sans projet", count: unmatchedShopifyProducts().length, active: state.filter.type === "shopifyOrphans", action: "shopifyOrphans" });
    html += groupHtml("shopify", "Shopify", body);
  }

  // Types 3D
  if (state.fileStats) {
    const body = Object.keys(FILE_KIND_LABELS).map((key) =>
      filterItemHtml({
        icon: FILE_KIND_ICON[key], label: FILE_KIND_LABELS[key],
        count: state.fileStats[key] || 0,
        active: state.filter.type === "kind" && state.filter.value === key,
        action: "kind", value: key,
      })
    ).join("");
    html += groupHtml("types", "Types 3D", body);
  }

  // Categories / Tags / Materiaux / Createurs
  for (const [key, cfg] of Object.entries(FILTER_FIELDS)) {
    const values = visibleFilterValues(key);
    if (values.length === 0) continue;
    let body = values.map((v) => {
      const isSelected = state.selected[key].has(v);
      return `<button class="filter-item ${isSelected ? "active" : ""}" data-action="multi" data-key="${key}" data-value="${escapeHtml(v)}" ${cfg.rename ? 'data-rename="1"' : ""}>
        <span class="fi-icon">${cfg.icon}</span><span class="fi-label">${escapeHtml(v)}</span><span class="fi-count">${countForCandidate(key, v)}</span>
      </button>`;
    }).join("");
    if (state.selected[key].size > 0) {
      body += `<button class="filter-clear" data-action="clear" data-key="${key}">Effacer la sélection</button>`;
    }
    html += groupHtml(key, cfg.label, body);
  }

  nav.innerHTML = html;
}

function toggleGroupCollapse(id) {
  if (state.collapsedGroups.has(id)) state.collapsedGroups.delete(id);
  else state.collapsedGroups.add(id);
  renderSidebar();
}

function wireSidebarEvents() {
  const nav = document.getElementById("filterNav");
  nav.addEventListener("click", (evt) => {
    const groupTitle = evt.target.closest(".filter-group-title");
    if (groupTitle) { toggleGroupCollapse(groupTitle.dataset.group); return; }

    const btn = evt.target.closest("[data-action]");
    if (!btn) return;
    switch (btn.dataset.action) {
      case "all": setSingleFilter("all"); break;
      case "todo": setSingleFilter("todo"); break;
      case "kind": setSingleFilter("kind", btn.dataset.value); break;
      case "shopify": setSingleFilter("shopify", btn.dataset.value); break;
      case "shopifyOrphans": setSingleFilter("shopifyOrphans"); break;
      case "multi": toggleMultiFilter(btn.dataset.key, btn.dataset.value); break;
      case "clear": clearMultiFilter(btn.dataset.key); break;
    }
  });
  nav.addEventListener("contextmenu", (evt) => {
    const btn = evt.target.closest('[data-action="multi"][data-rename="1"]');
    if (!btn) return;
    evt.preventDefault();
    showContextMenu(evt.clientX, evt.clientY, btn.dataset.key, btn.dataset.value);
  });
}

// ── Rename / delete (category, material, creator — mirrors ContentView's contextMenu) ──

function closeContextMenu() {
  document.querySelectorAll(".context-menu").forEach((m) => m.remove());
}

function showContextMenu(x, y, key, value) {
  closeContextMenu();
  const menu = document.createElement("div");
  menu.className = "context-menu";
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
  menu.innerHTML = `
    <button data-act="rename">Renommer…</button>
    <button data-act="delete" class="danger">Supprimer</button>
  `;
  menu.querySelector('[data-act="rename"]').addEventListener("click", () => {
    closeContextMenu();
    const newName = prompt(`Renommer « ${value} » en :`, value);
    if (newName && newName.trim() && newName.trim() !== value) renameFilterValue(key, value, newName.trim());
  });
  menu.querySelector('[data-act="delete"]').addEventListener("click", () => {
    closeContextMenu();
    if (confirm(`Supprimer « ${value} » de tous les projets concernés ?`)) deleteFilterValue(key, value);
  });
  document.body.appendChild(menu);
  setTimeout(() => document.addEventListener("click", closeContextMenu, { once: true }), 0);
}

function patchBodyFor(key, project, { rename, remove }) {
  if (key === "material") {
    const current = project.suggestedMaterials || [];
    const updated = rename
      ? current.map((m) => (m === rename.from ? rename.to : m))
      : current.filter((m) => m !== remove);
    return { suggestedMaterials: updated };
  }
  // category/creator: empty string is the server's "clear this field" convention
  return { [key]: rename ? rename.to : "" };
}

async function renameFilterValue(key, oldValue, newValue) {
  const cfg = FILTER_FIELDS[key];
  const matching = state.projects.filter((p) => cfg.getValues(p).includes(oldValue));
  await Promise.all(matching.map((p) =>
    api(`/api/projects/${p.id}`, { method: "PATCH", body: JSON.stringify(patchBodyFor(key, p, { rename: { from: oldValue, to: newValue } })) })
  ));
  if (state.selected[key].has(oldValue)) {
    state.selected[key].delete(oldValue);
    state.selected[key].add(newValue);
  }
  await onLibraryChanged();
}

async function deleteFilterValue(key, value) {
  const cfg = FILTER_FIELDS[key];
  const matching = state.projects.filter((p) => cfg.getValues(p).includes(value));
  await Promise.all(matching.map((p) =>
    api(`/api/projects/${p.id}`, { method: "PATCH", body: JSON.stringify(patchBodyFor(key, p, { remove: value })) })
  ));
  state.selected[key].delete(value);
  if (state.selected[key].size === 0 && state.filter.type === key) state.filter = { type: "all" };
  await onLibraryChanged();
}

// ───────────────────────── Grid view ─────────────────────────

function setDetailWide(isWide) {
  document.getElementById("detail").classList.toggle("detail-wide", isWide);
}

function showGrid(opts = {}) {
  if (!opts.keepFilter) state.filter = { type: "all" };
  state.view = "grid";
  state.selectedId = null;
  setDetailWide(true);
  setSettingsButtonActive(false);
  renderSidebar();
  renderGrid();
}

function backLinkHtml() {
  return `<button class="back-link" id="btnBackToGrid">← Retour à la bibliothèque</button>`;
}
function wireBackLink() {
  document.getElementById("btnBackToGrid")?.addEventListener("click", () => showGrid({ keepFilter: true }));
}

function renderGrid() {
  const detail = document.getElementById("detail");
  setDetailWide(true);

  if (state.filter.type === "kind") {
    renderKindFileList(detail, state.filter.value);
    return;
  }
  if (state.filter.type === "shopifyOrphans") {
    renderShopifyOrphansList(detail);
    return;
  }

  let sectionsHtml = "";
  let title, projectsForGrid;

  switch (state.filter.type) {
    case "all":
      title = "Tous les projets";
      projectsForGrid = state.projects;
      break;
    case "todo":
      renderTodoView(detail);
      return;
    case "shopify":
      title = SHOPIFY_STATUS_LABEL[state.filter.value] || "Shopify";
      projectsForGrid = projectsMatchingShopifyStatus(state.filter.value);
      break;
    case "category": case "tag": case "material": case "creator": {
      const key = state.filter.type;
      title = [...state.selected[key]].sort().join(" + ") || FILTER_FIELDS[key].label;
      projectsForGrid = projectsMatchingFilter(key, state.selected[key]);
      break;
    }
    default:
      title = "Tous les projets";
      projectsForGrid = state.projects;
  }

  const results = applySearch(projectsForGrid);

  if (state.filter.type === "all") {
    if (state.unsorted.length > 0) sectionsHtml += unsortedSectionHtml();
    if (!state.searchText.trim() && recentlyAdded().length > 1) sectionsHtml += recentlyAddedSectionHtml();
  }

  // The big "no library scanned yet" empty state only applies to the truly
  // empty library — a specific filter (category, Shopify status…) with zero
  // matches instead falls through to the grid-section's own "Aucun résultat".
  const isEmptyLibrary = state.filter.type === "all" && state.projects.length === 0 && state.unsorted.length === 0;
  if (isEmptyLibrary) {
    detail.innerHTML = emptyStateHtml();
    wireEmptyState();
    return;
  }

  sectionsHtml += `
    <div class="grid-section">
      <div class="grid-section-header">
        <div class="grid-section-title">${escapeHtml(title)}</div>
        <div class="grid-section-count">${results.length}</div>
      </div>
      ${results.length === 0
        ? `<div class="empty">Aucun résultat</div>`
        : `<div class="project-grid">${results.map((p) => projectCardHtml(p)).join("")}</div>`}
    </div>`;

  detail.innerHTML = sectionsHtml;
  wireGridCardClicks(detail);
  wireHScrollCardClicks(detail);
}

function renderTodoView(detail) {
  const incomplete = incompleteProjects();
  let html = "";
  if (state.unsorted.length > 0) html += unsortedSectionHtml();
  if (incomplete.length > 0) {
    html += `
      <div class="grid-section">
        <div class="grid-section-header">
          <div class="grid-section-title">⚠️ Métadonnées incomplètes</div>
          <div class="grid-section-count">${incomplete.length}</div>
        </div>
        <div class="project-grid">${incomplete.map((p) => projectCardHtml(p, { missing: true })).join("")}</div>
      </div>`;
  }
  if (html === "") {
    detail.innerHTML = `
      <div class="empty-state">
        <div class="es-icon">✅</div>
        <h2>Tout est à jour</h2>
        <p>Aucun fichier non classé ni projet avec des métadonnées manquantes.</p>
      </div>`;
    return;
  }
  detail.innerHTML = html;
  wireGridCardClicks(detail);
  wireHScrollCardClicks(detail);
}

async function renderKindFileList(detail, kind) {
  detail.innerHTML = `<div class="placeholder">Chargement…</div>`;
  if (!state.fileListCache[kind]) {
    try {
      state.fileListCache[kind] = await api(`/api/files?kind=${encodeURIComponent(kind)}`);
    } catch (e) {
      detail.innerHTML = `<div class="message err">${escapeHtml(e.message)}</div>`;
      return;
    }
  }
  const files = state.fileListCache[kind];
  detail.innerHTML = `
    <div class="grid-section">
      <div class="grid-section-header">
        <div class="grid-section-title">${FILE_KIND_ICON[kind] || ""} ${escapeHtml(FILE_KIND_LABELS[kind] || kind)}</div>
        <div class="grid-section-count">${files.length}</div>
      </div>
      <div class="flat-file-list">
        ${files.length === 0 ? `<div class="empty">Aucun fichier</div>` : files.map((f) => flatFileRowHtml(f)).join("")}
      </div>
    </div>`;
}

function flatFileRowHtml(file) {
  const icon = FILE_ROLE_ICON[file.fileRole] ?? "📦";
  const thumbUrl = file.fileRole === "renderImage" || file.kind === "threeMF" ? `/api/files/${file.id}/thumbnail` : null;
  return `
    <div class="flat-file-row">
      <div class="thumb-box">
        ${thumbUrl ? `<img src="${thumbUrl}" onerror="this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${icon}'}))" />` : icon}
      </div>
      <span class="ff-name">${escapeHtml(file.fileName)}.${escapeHtml(file.fileExtension)}</span>
      <span class="ff-size">${formatBytes(file.fileSize)}</span>
      <a class="btn btn-sm" href="/api/files/${file.id}/download" download>⬇</a>
    </div>`;
}

// ── Shopify products with no matching project (inverse of the "none" filter) ──

function renderShopifyOrphansList(detail) {
  const orphans = unmatchedShopifyProducts();
  detail.innerHTML = `
    <div class="grid-section">
      <div class="grid-section-header">
        <div class="grid-section-title">🧩 Produits Shopify sans projet</div>
        <div class="grid-section-count">${orphans.length}</div>
      </div>
      ${orphans.length === 0
        ? `<div class="empty">Tous les produits synchronisés sont liés à un projet de la bibliothèque.</div>`
        : `<div class="flat-file-list">${orphans.map((p) => shopifyOrphanRowHtml(p)).join("")}</div>`}
    </div>`;
}

function shopifyOrphanRowHtml(product) {
  const price = shopifyLowestPrice(product);
  return `
    <div class="flat-file-row">
      <span class="dot ${product.status === "active" ? "on" : "off"}"></span>
      <span class="ff-name">${escapeHtml(product.title)}</span>
      <span class="ff-size">${escapeHtml(SHOPIFY_STATUS_LABEL[product.status] || product.status)}${price != null ? ` · ${formatEur(price)}` : ""}</span>
      <a class="btn btn-sm" href="https://${escapeHtml(state.shopifyStoreDomain)}/products/${escapeHtml(product.handle)}" target="_blank" rel="noopener">Voir</a>
    </div>`;
}

// ── Unsorted files banner ──

function unsortedSectionHtml() {
  return `
    <div class="grid-section unsorted-banner">
      <div class="grid-section-header">
        <div class="grid-section-title">📥 À trier</div>
        <div class="grid-section-count">${state.unsorted.length} fichier${state.unsorted.length === 1 ? "" : "s"} non classé${state.unsorted.length === 1 ? "" : "s"}</div>
      </div>
      <div class="h-scroll">
        ${state.unsorted.map((f) => miniFileCardHtml(f)).join("")}
      </div>
    </div>`;
}

function miniFileCardHtml(file) {
  const icon = FILE_ROLE_ICON[file.fileRole] ?? "📦";
  const thumbUrl = file.fileRole === "renderImage" || file.kind === "threeMF" ? `/api/files/${file.id}/thumbnail` : null;
  return `
    <div class="mini-card" data-download="${file.id}">
      <div class="thumb-box">
        ${thumbUrl ? `<img src="${thumbUrl}" onerror="this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${icon}'}))" />` : icon}
      </div>
      <div class="fn" title="${escapeHtml(file.fileName)}.${escapeHtml(file.fileExtension)}">${escapeHtml(file.fileName)}</div>
    </div>`;
}

function wireHScrollCardClicks(container) {
  container.querySelectorAll("[data-download]").forEach((el) => {
    el.addEventListener("click", () => {
      window.open(`/api/files/${el.dataset.download}/download`, "_blank");
    });
  });
}

// ── Recently added row ──

function recentlyAddedSectionHtml() {
  const items = recentlyAdded();
  return `
    <div class="grid-section">
      <div class="grid-section-header">
        <div class="grid-section-title">🕐 Ajouté récemment</div>
      </div>
      <div class="h-scroll recent-scroll">
        ${items.map((p) => projectCardHtml(p)).join("")}
      </div>
    </div>`;
}

// ── Project card ──

function projectCardHtml(project, opts = {}) {
  const coverUrl = project.coverFileId ? `/api/files/${project.coverFileId}/thumbnail` : null;
  const product = state.shopifyProducts.length ? matchShopifyProduct(project.name, project.shopifyProductId) : null;
  const tags = project.tags || [];
  const shownTags = tags.slice(0, 6);
  const hiddenCount = tags.length - shownTags.length;

  return `
    <div class="project-card" data-open="${project.id}">
      <div class="cover">
        ${coverUrl
          ? `<img src="${coverUrl}" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'cover-placeholder',textContent:'🧊'}))" />`
          : `<div class="cover-placeholder">🧊</div>`}
        ${product ? `<div class="shopify-badge"><span class="dot ${product.status === "active" ? "on" : "off"}"></span>${escapeHtml(SHOPIFY_STATUS_LABEL[product.status] || product.status)}</div>` : ""}
        ${opts.missing ? `<div class="missing-chips">${missingMetadataLabels(project).map((m) => `<span class="missing-chip">${escapeHtml(m)}</span>`).join("")}</div>` : ""}
      </div>
      <div class="card-body">
        <div class="card-name">${escapeHtml(project.name)}</div>
        ${project.creator ? `<div class="card-creator">${escapeHtml(project.creator)}</div>` : ""}
        <div class="card-counts">
          <span>🧊 ${project.partsCount} pièce${project.partsCount === 1 ? "" : "s"}</span>
          <span>📄 ${project.totalFileCount} fichier${project.totalFileCount === 1 ? "" : "s"}</span>
        </div>
        ${tags.length ? `<div class="card-tags">${shownTags.map((t) => `<span class="tag-chip">${escapeHtml(t)}</span>`).join("")}${hiddenCount > 0 ? `<span class="tag-chip more">+${hiddenCount}</span>` : ""}</div>` : ""}
        <div class="card-footer"><span>${formatRelative(project.lastModifiedAt)}</span></div>
      </div>
    </div>`;
}

function wireGridCardClicks(container) {
  container.querySelectorAll("[data-open]").forEach((el) => {
    el.addEventListener("click", () => openProject(el.dataset.open));
  });
}

// ── Empty state ──

function emptyStateHtml() {
  return `
    <div class="empty-state">
      <div class="es-icon">🧊</div>
      <h2>Aucun projet</h2>
      <p>Lancez un scan pour découvrir les projets d'impression 3D de la bibliothèque.</p>
      <button class="btn btn-primary btn-sm" id="btnScanFromEmpty">Lancer un scan</button>
    </div>`;
}
function wireEmptyState() {
  document.getElementById("btnScanFromEmpty")?.addEventListener("click", triggerScan);
}

// ───────────────────────── Project detail ─────────────────────────
// Mirrors ProjectDetailView.swift from the macOS app section-for-section:
// editable header (autosave), image gallery (cover-setting), metadata with
// autocomplete, tags/materials chip editors, notes, actions (web equivalents
// of Finder / slicer launch / SceneKit preview), rich Shopify section,
// per-file print estimation with a persisted manual-work level, and file
// lists grouped by role.

const FILE_ROLE_ORDER = ["modelPart", "slicerConfig", "document", "other"];
const FILE_ROLE_LABELS = {
  modelPart: "Pièces 3D", slicerConfig: "Configuration slicer", document: "Documentation", other: "Autres fichiers",
};
const MANUAL_WORK_LEVELS = ["aucun", "easy", "medium", "hard"];
const MANUAL_WORK_LABEL = { aucun: "Aucun", easy: "Facile", medium: "Moyen", hard: "Difficile" };
const MANUAL_WORK_COST_EUR = { aucun: 0, easy: 5, medium: 10, hard: 25 };
const VIEWABLE_KINDS = new Set(["stl", "threeMF", "obj"]);
const ESTIMATE_PRINTER_KEY = "printplex_estimate_printer_id";
const ESTIMATE_MATERIAL_KEY = "printplex_estimate_material_id";

// Per-project-detail-view transient UI state (which file is selected for
// estimation, per-file manual-work picks, per-file plate picks for multi-plate
// 3MF files) — reset every time a project is opened, mirrors the macOS view's @State.
let detailState = { manualWorkPerFile: {}, estimateFileId: "all", platePerFile: {} };

// ── PrintEstimator, ported to JS (mirrors PrintEstimator.swift exactly) so
// changing printer/material/manual-work/file-selection recomputes instantly
// client-side from the already-loaded meshStats, without a round trip. ──

const PRINT_SETTINGS_DEFAULT = { layerHeightMM: 0.2, shellCount: 3, infillPercent: 15, filamentDiameterMM: 1.75 };

function estimatePrint(meshStats, printer, material, manualCostEur, settings = PRINT_SETTINGS_DEFAULT) {
  const lineW = printer.nozzleDiameterMM * 1.2;
  const layerH = settings.layerHeightMM;
  const infill = settings.infillPercent / 100;

  const shellVol = meshStats.surfaceAreaMM2 * lineW * settings.shellCount;
  const coreVol = Math.max(0, meshStats.volumeMM3 - shellVol);
  const plasticMM3 = Math.min(shellVol, meshStats.volumeMM3) + coreVol * infill;

  const crossSection = Math.PI * Math.pow(settings.filamentDiameterMM / 2, 2);
  const baseLengthM = plasticMM3 / crossSection / 1000;
  const baseWeightG = (plasticMM3 / 1000) * material.densityGCM3;

  const layerCount = Math.ceil(Math.max(meshStats.depthMM, 1) / layerH);

  const pathMM = plasticMM3 / (lineW * layerH);
  const nominalSpeed = printer.perimeterSpeedMMPS * 0.30 + printer.infillSpeedMMPS * 0.70;
  const effectiveSpeed = nominalSpeed * printer.speedEfficiency;
  const basePrintSec = pathMM / effectiveSpeed;
  const layerOverheadSec = layerCount * 5.0;

  const overhead = 1.0 + printer.supportsPercent / 100 + printer.purgePercent / 100;
  const lengthM = baseLengthM * overhead;
  const weightG = baseWeightG * overhead;
  const totalSec = Math.ceil((basePrintSec + layerOverheadSec) * overhead + 120);

  const dims = [meshStats.widthMM, meshStats.heightMM, meshStats.depthMM].sort((a, b) => b - a);
  const build = [printer.buildX, printer.buildY, printer.buildZ].sort((a, b) => b - a);
  const fitsOnBed = dims.every((d, i) => d <= build[i]);

  const filamentCostEur = (weightG / 1000) * material.pricePerKg;
  const timeCostEur = (totalSec / 3600) * 2.0;

  return {
    filamentLengthM: lengthM, filamentWeightG: weightG,
    printTimeSeconds: totalSec, layerCount, fitsOnBed,
    printerName: printer.name, materialName: material.name,
    filamentCostEur, timeCostEur, manualCostEur,
  };
}

function totalEstimate(estimates) {
  return {
    filamentLengthM: estimates.reduce((s, e) => s + e.filamentLengthM, 0),
    filamentWeightG: estimates.reduce((s, e) => s + e.filamentWeightG, 0),
    printTimeSeconds: estimates.reduce((s, e) => s + e.printTimeSeconds, 0),
    layerCount: Math.max(...estimates.map((e) => e.layerCount)),
    fitsOnBed: estimates.every((e) => e.fitsOnBed),
    filamentCostEur: estimates.reduce((s, e) => s + e.filamentCostEur, 0),
    timeCostEur: estimates.reduce((s, e) => s + e.timeCostEur, 0),
    manualCostEur: estimates.reduce((s, e) => s + e.manualCostEur, 0),
  };
}

// ── Generic UI helpers: autocomplete popover + small dropdown menu ──

function attachAutocomplete(inputEl, getSuggestions, onSelect) {
  let popover = null;
  function close() { popover?.remove(); popover = null; }
  function open() {
    close();
    const suggestions = getSuggestions(inputEl.value);
    if (!suggestions.length) return;
    popover = document.createElement("div");
    popover.className = "autocomplete-popover";
    const rect = inputEl.getBoundingClientRect();
    popover.style.left = `${rect.left + window.scrollX}px`;
    popover.style.top = `${rect.bottom + window.scrollY + 4}px`;
    popover.style.width = `${Math.max(rect.width, 160)}px`;
    popover.innerHTML = suggestions.map((s) => `<button data-value="${escapeHtml(s)}">${highlightMatch(s, inputEl.value)}</button>`).join("");
    document.body.appendChild(popover);
    popover.querySelectorAll("button").forEach((btn) => {
      // mousedown (not click) fires before the input's blur, so the
      // selection registers before the popover gets torn down by blur.
      btn.addEventListener("mousedown", (evt) => {
        evt.preventDefault();
        onSelect(btn.dataset.value);
        close();
      });
    });
  }
  inputEl.addEventListener("input", open);
  inputEl.addEventListener("focus", open);
  inputEl.addEventListener("blur", () => setTimeout(close, 150));
}

function highlightMatch(text, query) {
  const q = query.trim().toLowerCase();
  if (!q) return escapeHtml(text);
  const idx = text.toLowerCase().indexOf(q);
  if (idx === -1) return escapeHtml(text);
  return `${escapeHtml(text.slice(0, idx))}<b>${escapeHtml(text.slice(idx, idx + q.length))}</b>${escapeHtml(text.slice(idx + q.length))}`;
}

function openDropdownMenu(anchorEl, items) {
  closeContextMenu();
  const rect = anchorEl.getBoundingClientRect();
  const menu = document.createElement("div");
  menu.className = "context-menu";
  menu.style.left = `${rect.left}px`;
  menu.style.top = `${rect.bottom + 4}px`;
  menu.innerHTML = items.map((it, i) => `<button data-i="${i}">${it.label}</button>`).join("");
  document.body.appendChild(menu);
  items.forEach((it, i) => {
    menu.querySelector(`[data-i="${i}"]`).addEventListener("click", () => { closeContextMenu(); it.onClick(); });
  });
  setTimeout(() => document.addEventListener("click", closeContextMenu, { once: true }), 0);
}

function updateLocalProject(id, patch) {
  const idx = state.projects.findIndex((p) => p.id === id);
  if (idx !== -1) Object.assign(state.projects[idx], patch);
}

// Debounced autosave for free-text fields (name/description/creator/category)
// — mirrors the macOS view's scheduleSave()/persistTextFields(): a pause of
// 600ms triggers a save, and losing focus always flushes immediately.
let detailSaveTimer = null;
function scheduleDetailSave(fn) {
  clearTimeout(detailSaveTimer);
  detailSaveTimer = setTimeout(fn, 600);
}
function flushDetailSave(projectId, getPatch) {
  clearTimeout(detailSaveTimer);
  api(`/api/projects/${projectId}`, { method: "PATCH", body: JSON.stringify(getPatch()) })
    .catch((e) => console.error("Échec de l'enregistrement automatique", e));
}

function getPersistedEstimatePrinterId() {
  const saved = localStorage.getItem(ESTIMATE_PRINTER_KEY);
  return (saved && state.printers.some((p) => p.id === saved)) ? saved : state.printers[0]?.id;
}
function getPersistedEstimateMaterialId() {
  const saved = localStorage.getItem(ESTIMATE_MATERIAL_KEY);
  return (saved && state.materials.some((m) => m.id === saved)) ? saved : state.materials[0]?.id;
}

async function openProject(id) {
  state.selectedId = id;
  state.view = "project";
  setDetailWide(false);
  setSettingsButtonActive(false);
  const detail = document.getElementById("detail");
  detail.innerHTML = backLinkHtml() + `<div class="placeholder">Chargement…</div>`;
  wireBackLink();
  try {
    const project = await api(`/api/projects/${id}`);
    detailState = { manualWorkPerFile: {}, estimateFileId: "all", platePerFile: {} };
    for (const f of project.files || []) {
      if (f.printParams?.manualWorkLevel) detailState.manualWorkPerFile[f.id] = f.printParams.manualWorkLevel;
    }
    renderProjectDetail(project);
  } catch (e) {
    detail.innerHTML = backLinkHtml() + `<div class="message err">Impossible de charger le projet : ${escapeHtml(e.message)}</div>`;
    wireBackLink();
  }
}

function renderProjectDetail(project) {
  const detail = document.getElementById("detail");
  const files = project.files ?? [];
  const modelParts = files.filter((f) => f.fileRole === "modelPart");
  const totalSize = files.reduce((sum, f) => sum + (f.fileSize || 0), 0);

  detail.innerHTML = backLinkHtml() + `
    <div class="detail-header">
      <div class="detail-header-top">
        <input class="detail-name-input" id="detailNameInput" value="${escapeHtml(project.name)}" placeholder="Nom du projet" />
        <span class="cloud-badge">☁️ Local</span>
      </div>
      <textarea class="detail-desc-input" id="detailDescInput" placeholder="Description…" rows="2">${escapeHtml(project.projectDescription ?? "")}</textarea>
      <div class="detail-stats-row">
        <span>🧊 ${modelParts.length} pièce${modelParts.length === 1 ? "" : "s"}</span>
        <span>📄 ${files.length} fichier${files.length === 1 ? "" : "s"}</span>
        <span>💾 ${formatBytes(totalSize)}</span>
        <span class="muted">${formatRelative(project.lastModifiedAt)}</span>
      </div>
    </div>

    ${imageStripHtml(project)}

    <div class="section">
      <div class="section-title">Métadonnées</div>
      <div class="detail-metadata-row">
        <div class="meta-field"><label>👤 Créateur</label><input id="detailCreatorInput" value="${escapeHtml(project.creator ?? "")}" placeholder="Créateur…" autocomplete="off" /></div>
        <div class="meta-field"><label>📁 Catégorie</label><input id="detailCategoryInput" value="${escapeHtml(project.category ?? "")}" placeholder="Catégorie…" autocomplete="off" /></div>
      </div>
      ${chipEditorHtml("materialsChipList", "Matériaux", "🧵", project.suggestedMaterials || [], "chip-material")}
      ${chipEditorHtml("tagsChipList", "Tags", "🏷️", project.tags || [], "chip-tag")}
    </div>

    ${notesSectionHtml(project)}

    ${actionsSectionHtml(project, modelParts)}

    ${shopifySectionHtml(project)}

    ${estimateSectionHtml(project)}

    ${fileListSectionsHtml(project)}
  `;

  wireBackLink();
  wireProjectDetailEvents(project);
}

function wireProjectDetailEvents(project) {
  wireHeaderAutosave(project);
  wireMetadataField("detailCreatorInput", "creator", project, () => state.projects.map((p) => p.creator).filter(Boolean));
  wireMetadataField("detailCategoryInput", "category", project, () => state.projects.map((p) => p.category).filter(Boolean));

  wireChipEditor("materialsChipList", project.suggestedMaterials || [],
    (list) => updateChipField(project, "suggestedMaterials", list),
    (query) => {
      const q = query.trim().toLowerCase();
      if (!q) return [];
      const all = new Set(state.projects.flatMap((p) => p.suggestedMaterials || []));
      return [...all].filter((v) => v.toLowerCase().includes(q) && !(project.suggestedMaterials || []).includes(v)).slice(0, 8);
    });
  wireChipEditor("tagsChipList", project.tags || [],
    (list) => updateChipField(project, "tags", list),
    (query) => {
      const q = query.trim().toLowerCase();
      if (!q) return [];
      const all = new Set(state.projects.flatMap((p) => p.tags || []));
      return [...all].filter((v) => v.toLowerCase().includes(q) && !(project.tags || []).includes(v)).slice(0, 8);
    });

  wireImageStrip(project);
  wireActionsSection(project, (project.files || []).filter((f) => f.fileRole === "modelPart"));
  wireShopifySection(project);
  wireEstimateSection(project);
  wireFileListEvents();
}

// ── Header (name/description autosave) ──

function wireHeaderAutosave(project) {
  const nameInput = document.getElementById("detailNameInput");
  const descInput = document.getElementById("detailDescInput");

  const saveName = () => {
    const value = nameInput.value.trim();
    if (!value) return; // never autosave an empty project name
    flushDetailSave(project.id, () => ({ name: value }));
  };
  nameInput.addEventListener("input", () => scheduleDetailSave(saveName));
  nameInput.addEventListener("blur", saveName);

  const saveDesc = () => flushDetailSave(project.id, () => ({ projectDescription: descInput.value }));
  descInput.addEventListener("input", () => scheduleDetailSave(saveDesc));
  descInput.addEventListener("blur", saveDesc);
}

// ── Metadata (creator/category, with autocomplete drawn from other projects) ──

function wireMetadataField(inputId, fieldKey, project, allValuesFn) {
  const input = document.getElementById(inputId);
  const commitAndSync = (value) => {
    flushDetailSave(project.id, () => ({ [fieldKey]: value }));
    project[fieldKey] = value || null;
    updateLocalProject(project.id, { [fieldKey]: value || null });
    renderSidebar();
  };
  input.addEventListener("input", () => scheduleDetailSave(() => flushDetailSave(project.id, () => ({ [fieldKey]: input.value.trim() }))));
  input.addEventListener("blur", () => commitAndSync(input.value.trim()));
  attachAutocomplete(input, (query) => {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    return [...new Set(allValuesFn())].filter((v) => v.toLowerCase().includes(q) && v.toLowerCase() !== q).slice(0, 8);
  }, (value) => { input.value = value; commitAndSync(value); });
}

// ── Materials / tags chip editors ──

function chipEditorHtml(containerId, label, icon, items, colorClass) {
  return `
    <div class="chip-editor">
      <label>${icon} ${escapeHtml(label)}</label>
      <div class="chip-list" id="${containerId}">
        ${items.map((v) => `<span class="chip ${colorClass}">${escapeHtml(v)}<button class="chip-remove" data-remove="${escapeHtml(v)}">×</button></span>`).join("")}
        <input class="chip-input" id="${containerId}Input" placeholder="Ajouter…" autocomplete="off" />
      </div>
    </div>`;
}

function wireChipEditor(containerId, currentItems, onChange, suggestionsFn) {
  const container = document.getElementById(containerId);
  const input = document.getElementById(`${containerId}Input`);

  container.addEventListener("click", (evt) => {
    const btn = evt.target.closest("[data-remove]");
    if (!btn) return;
    onChange(currentItems.filter((v) => v !== btn.dataset.remove));
  });

  function commit() {
    const value = input.value.trim();
    if (!value || currentItems.includes(value)) { input.value = ""; return; }
    onChange([...currentItems, value]);
  }
  input.addEventListener("keydown", (evt) => {
    if (evt.key === "Enter") { evt.preventDefault(); commit(); }
  });
  input.addEventListener("blur", () => { if (input.value.trim()) commit(); });
  if (suggestionsFn) attachAutocomplete(input, suggestionsFn, (value) => { input.value = value; commit(); });
}

async function updateChipField(project, field, newList) {
  project[field] = newList;
  renderProjectDetail(project); // optimistic re-render, mirrors SwiftUI's live binding
  try {
    await api(`/api/projects/${project.id}`, { method: "PATCH", body: JSON.stringify({ [field]: newList }) });
    updateLocalProject(project.id, { [field]: newList });
    renderSidebar();
  } catch (e) {
    alert(`Échec de la sauvegarde : ${e.message}`);
  }
}

// ── Notes ──

function notesSectionHtml(project) {
  if (!project.notes) return "";
  return `<div class="section"><div class="section-title">📝 Notes</div><p class="detail-notes">${escapeHtml(project.notes)}</p></div>`;
}

// ── Image gallery strip (natural aspect ratio, cover-setting via context menu) ──

function imageStripHtml(project) {
  const images = (project.files || []).filter((f) => f.fileRole === "renderImage");
  if (images.length === 0) return "";
  const cover = project.coverImageFileName;
  const ordered = [...images].sort((a, b) => {
    const an = `${a.fileName}.${a.fileExtension}` === cover ? 0 : 1;
    const bn = `${b.fileName}.${b.fileExtension}` === cover ? 0 : 1;
    return an - bn;
  });
  return `
    <div class="image-strip" id="imageStrip">
      ${ordered.map((f) => {
        const fname = `${f.fileName}.${f.fileExtension}`;
        const isCover = fname === cover;
        return `<div class="image-strip-item ${isCover ? "is-cover" : ""}" data-file-id="${f.id}" data-filename="${escapeHtml(fname)}">
          <img src="/api/files/${f.id}/thumbnail" onerror="this.closest('.image-strip-item').remove()" />
          ${isCover ? `<div class="cover-star" title="Image principale">⭐</div>` : ""}
        </div>`;
      }).join("")}
    </div>`;
}

function wireImageStrip(project) {
  const strip = document.getElementById("imageStrip");
  if (!strip) return;
  strip.addEventListener("contextmenu", (evt) => {
    const item = evt.target.closest(".image-strip-item");
    if (!item) return;
    evt.preventDefault();
    closeContextMenu();
    const isCover = item.classList.contains("is-cover");
    const menu = document.createElement("div");
    menu.className = "context-menu";
    menu.style.left = `${evt.clientX}px`;
    menu.style.top = `${evt.clientY}px`;
    menu.innerHTML = `<button data-act="cover" ${isCover ? "disabled" : ""}>Définir comme image principale</button>`;
    menu.querySelector('[data-act="cover"]').addEventListener("click", async () => {
      closeContextMenu();
      const filename = item.dataset.filename;
      try {
        await api(`/api/projects/${project.id}`, { method: "PATCH", body: JSON.stringify({ coverImageFileName: filename }) });
        project.coverImageFileName = filename;
        updateLocalProject(project.id, { coverImageFileName: filename, coverFileId: item.dataset.fileId });
        renderProjectDetail(project);
      } catch (e) {
        alert(`Échec : ${e.message}`);
      }
    });
    document.body.appendChild(menu);
    setTimeout(() => document.addEventListener("click", closeContextMenu, { once: true }), 0);
  });
}

// ── Actions: web-honest equivalents of Finder / slicer launch / SceneKit ──

function actionsSectionHtml(project, modelParts) {
  const downloadableFiles = (project.files || []).filter((f) => f.fileRole !== "renderImage");
  return `
    <div class="section">
      <div class="section-title">Actions</div>
      <div class="actions-row">
        <button class="btn btn-sm" id="btnCopyPath" title="${escapeHtml(project.folderPath)}">📁 Copier le chemin du dossier</button>
        ${modelParts.length ? `<button class="btn btn-sm" id="btnPreview3d">🧊 Visualiser en 3D</button>` : ""}
        ${downloadableFiles.length ? `<button class="btn btn-sm" id="btnDownloadParts">⬇ Télécharger les pièces</button>` : ""}
      </div>
      <div id="actionsMessage"></div>
    </div>`;
}

function flashActionMessage(text, isError) {
  const box = document.getElementById("actionsMessage");
  if (!box) return;
  box.innerHTML = `<div class="message ${isError ? "err" : "ok"}">${escapeHtml(text)}</div>`;
  setTimeout(() => { if (box.isConnected) box.innerHTML = ""; }, 3000);
}

function wireActionsSection(project, modelParts) {
  document.getElementById("btnCopyPath")?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(project.folderPath);
      flashActionMessage("Chemin copié dans le presse-papiers.");
    } catch (_) {
      flashActionMessage("Impossible de copier (autorisation presse-papiers refusée).", true);
    }
  });

  document.getElementById("btnPreview3d")?.addEventListener("click", (evt) => {
    if (modelParts.length === 1) {
      const f = modelParts[0];
      openViewer3D(f.id, `${f.fileName}.${f.fileExtension}`, f.kind);
      return;
    }
    openDropdownMenu(evt.currentTarget, modelParts.map((f) => ({
      label: `${escapeHtml(f.fileName)}.${escapeHtml(f.fileExtension)}`,
      onClick: () => openViewer3D(f.id, `${f.fileName}.${f.fileExtension}`, f.kind),
    })));
  });

  document.getElementById("btnDownloadParts")?.addEventListener("click", (evt) => {
    const downloadableFiles = (project.files || []).filter((f) => f.fileRole !== "renderImage");
    openDropdownMenu(evt.currentTarget, [
      { label: "Tous les fichiers", onClick: () => downloadableFiles.forEach((f) => window.open(`/api/files/${f.id}/download`, "_blank")) },
      ...downloadableFiles.map((f) => ({
        label: `${escapeHtml(f.fileName)}.${escapeHtml(f.fileExtension)}`,
        onClick: () => window.open(`/api/files/${f.id}/download`, "_blank"),
      })),
    ]);
  });
}

// ── Shopify (rich match display + manual assignment + sync) ──

function shopifyLowestPrice(product) {
  const prices = (product.variants || []).map((v) => parseFloat(v.price)).filter((n) => !Number.isNaN(n));
  return prices.length ? Math.min(...prices) : null;
}

function shopifySectionHtml(project) {
  if (!state.shopifyConfigured) {
    return `
      <div class="section">
        <div class="section-title">Shopify</div>
        <div class="empty">Non configuré — réglez la boutique dans Réglages → Shopify.</div>
      </div>`;
  }
  if (state.shopifyProducts.length === 0) {
    return `
      <div class="section">
        <div class="section-title">Shopify</div>
        <div class="empty">Aucun produit synchronisé.</div>
        <button class="btn btn-sm" id="btnShopifySync" style="margin-top:8px">🔄 Synchroniser</button>
        <div id="shopifySectionMessage"></div>
      </div>`;
  }
  const product = matchShopifyProduct(project.name, project.shopifyProductId);
  const price = product ? shopifyLowestPrice(product) : null;
  return `
    <div class="section">
      <div class="section-title">Shopify</div>
      ${product ? `
        <div class="shopify-match">
          <span class="dot ${product.status === "active" ? "on" : "off"}"></span>
          <div class="shopify-match-body">
            <div class="shopify-match-title">${escapeHtml(product.title)}</div>
            <div class="shopify-match-meta">${escapeHtml(SHOPIFY_STATUS_LABEL[product.status] || product.status)}${price != null ? ` · ${formatEur(price)}` : ""}</div>
          </div>
          <a class="btn btn-sm" href="https://${escapeHtml(state.shopifyStoreDomain)}/products/${escapeHtml(product.handle)}" target="_blank" rel="noopener">Voir</a>
        </div>` : `<div class="empty">Non publié sur Shopify.</div>`}
      <div class="field" style="margin-top:10px">
        <label>Assignation manuelle</label>
        <select id="shopifyManualSelect">
          <option value="">Auto (par nom)</option>
          ${state.shopifyProducts.map((p) => `<option value="${p.id}" ${String(p.id) === (project.shopifyProductId || "") ? "selected" : ""}>${escapeHtml(p.title)}</option>`).join("")}
        </select>
      </div>
      <button class="btn btn-sm" id="btnShopifySync" style="margin-top:8px">🔄 Resynchroniser</button>
      <div id="shopifySectionMessage"></div>
    </div>`;
}

function wireShopifySection(project) {
  document.getElementById("shopifyManualSelect")?.addEventListener("change", async (evt) => {
    const value = evt.target.value;
    const msg = document.getElementById("shopifySectionMessage");
    try {
      await api(`/api/projects/${project.id}`, { method: "PATCH", body: JSON.stringify({ shopifyProductId: value }) });
      project.shopifyProductId = value || null;
      updateLocalProject(project.id, { shopifyProductId: value || null });
      renderProjectDetail(project);
    } catch (e) {
      msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });
  document.getElementById("btnShopifySync")?.addEventListener("click", async () => {
    const msg = document.getElementById("shopifySectionMessage");
    msg.innerHTML = `<div class="hint">Synchronisation…</div>`;
    try {
      await api("/api/shopify/sync", { method: "POST" });
      await onLibraryChanged();
    } catch (e) {
      msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });
}

// ── Print estimate (per file, client-side PrintEstimator, persisted manual work) ──

function estimateSectionHtml(project) {
  // Every 3MF file is listed here, even ones a scan hasn't parsed yet (or failed to) —
  // those just render as "pas de statistiques" instead of vanishing silently.
  const threeMFFiles = (project.files || []).filter((f) => f.kind === "threeMF");
  if (threeMFFiles.length === 0) {
    return `
      <div class="section">
        <div class="section-title">Estimation d'impression</div>
        <div class="empty">Aucun fichier 3MF dans ce projet.</div>
      </div>`;
  }
  if (state.printers.length === 0 || state.materials.length === 0) {
    return `
      <div class="section">
        <div class="section-title">Estimation d'impression</div>
        <div class="empty">Configurez au moins une imprimante et un matériau dans Réglages → Matériel.</div>
      </div>`;
  }
  const printerId = getPersistedEstimatePrinterId();
  const materialId = getPersistedEstimateMaterialId();
  return `
    <div class="section">
      <div class="section-title">Estimation d'impression</div>
      <div class="form-grid">
        ${threeMFFiles.length > 1 ? `
          <div class="field">
            <label>Fichier 3MF</label>
            <select id="estimateFileSelect">
              <option value="all" ${detailState.estimateFileId === "all" ? "selected" : ""}>Tous (${threeMFFiles.length} fichiers)</option>
              ${threeMFFiles.map((f) => `<option value="${f.id}" ${detailState.estimateFileId === f.id ? "selected" : ""}>${escapeHtml(f.fileName)}.${escapeHtml(f.fileExtension)}${f.meshStats ? "" : " — pas de statistiques"}</option>`).join("")}
            </select>
          </div>` : ""}
        <div class="field"><label>Imprimante</label><select id="estimatePrinterSelect">${selectOptionsHtml(state.printers, printerId)}</select></div>
        <div class="field"><label>Matériau</label><select id="estimateMaterialSelect">${selectOptionsHtml(state.materials, materialId)}</select></div>
      </div>
      <div id="estimateResults"></div>
    </div>`;
}

/// Which plate's stats to estimate for a file: the one explicitly picked in
/// detailState.platePerFile, falling back to plate 0 (meshStats) for single-plate files
/// or when nothing's been picked yet.
function selectedPlateStats(file) {
  if (!file.plateStats || file.plateStats.length < 2) return file.meshStats || null;
  const idx = detailState.platePerFile[file.id] ?? 0;
  return file.plateStats.find((p) => p.plateIndex === idx) || file.meshStats || null;
}

function estimateUnavailableRowHtml(file) {
  return `
    <div class="estimate-card estimate-unavailable">
      <div class="estimate-file-name">${escapeHtml(file.fileName)}.${escapeHtml(file.fileExtension)}</div>
      <div class="empty">Pas de statistiques de maillage — relancez un scan.</div>
    </div>`;
}

function estimateCardHtml(file, est, stats) {
  const level = detailState.manualWorkPerFile[file.id] || "aucun";
  const totalCost = est.filamentCostEur + est.timeCostEur + est.manualCostEur;
  const hasMultiplePlates = file.plateStats && file.plateStats.length > 1;
  return `
    <div class="estimate-card">
      <div class="estimate-file-name">${escapeHtml(file.fileName)}.${escapeHtml(file.fileExtension)}</div>
      ${hasMultiplePlates ? `
        <div class="field plate-field">
          <label>Plateau (${file.plateStats.length} détectés)</label>
          <select class="plate-select" data-file-id="${file.id}">
            ${file.plateStats.map((p) => `<option value="${p.plateIndex}" ${p.plateIndex === stats.plateIndex ? "selected" : ""}>Plateau ${p.plateIndex + 1}</option>`).join("")}
          </select>
        </div>` : ""}
      <div class="segmented" data-file-id="${file.id}">
        ${MANUAL_WORK_LEVELS.map((k) => `<button class="seg-btn ${k === level ? "active" : ""}" data-level="${k}">${MANUAL_WORK_LABEL[k]}</button>`).join("")}
      </div>
      <div class="estimate-grid">
        <span>⚖️ ${est.filamentWeightG.toFixed(0)} g</span>
        <span>📏 ${est.filamentLengthM.toFixed(1)} m</span>
        <span>⏱ ${formatDuration(est.printTimeSeconds)}</span>
        <span>📚 ${est.layerCount} couches</span>
      </div>
      <div class="estimate-fit ${est.fitsOnBed ? "ok" : "bad"}">${est.fitsOnBed ? `✅ Tient sur ${escapeHtml(est.printerName)}` : `❌ Ne tient pas sur ${escapeHtml(est.printerName)}`}</div>
      <div class="cost-breakdown">
        <div class="cost-row"><span>Filament</span><span>${formatEur(est.filamentCostEur)}</span></div>
        <div class="cost-row"><span>Machine</span><span>${formatEur(est.timeCostEur)}</span></div>
        <div class="cost-row"><span>Manutention</span><span>${formatEur(est.manualCostEur)}</span></div>
        <div class="cost-row total"><span>Total</span><span>${formatEur(totalCost)}</span></div>
      </div>
    </div>`;
}

function totalEstimateCardHtml(total) {
  const totalCost = total.filamentCostEur + total.timeCostEur + total.manualCostEur;
  return `
    <div class="estimate-card estimate-total">
      <div class="estimate-file-name">Total</div>
      <div class="estimate-grid">
        <span>⚖️ ${total.filamentWeightG.toFixed(0)} g</span>
        <span>📏 ${total.filamentLengthM.toFixed(1)} m</span>
        <span>⏱ ${formatDuration(total.printTimeSeconds)}</span>
        <span>📚 ${total.layerCount} couches</span>
      </div>
      <div class="estimate-fit ${total.fitsOnBed ? "ok" : "bad"}">${total.fitsOnBed ? "✅ Toutes les pièces tiennent" : "❌ Au moins une pièce ne tient pas"}</div>
      <div class="cost-breakdown">
        <div class="cost-row"><span>Filament</span><span>${formatEur(total.filamentCostEur)}</span></div>
        <div class="cost-row"><span>Machine</span><span>${formatEur(total.timeCostEur)}</span></div>
        <div class="cost-row"><span>Manutention</span><span>${formatEur(total.manualCostEur)}</span></div>
        <div class="cost-row total"><span>Total</span><span>${formatEur(totalCost)}</span></div>
      </div>
    </div>`;
}

function renderEstimateResults(project) {
  const box = document.getElementById("estimateResults");
  if (!box) return;
  const threeMFFiles = (project.files || []).filter((f) => f.kind === "threeMF");
  const printer = state.printers.find((p) => p.id === document.getElementById("estimatePrinterSelect")?.value);
  const material = state.materials.find((m) => m.id === document.getElementById("estimateMaterialSelect")?.value);
  if (!printer || !material) { box.innerHTML = `<div class="empty">Aucune imprimante/matériau sélectionné.</div>`; return; }

  const selectedFiles = detailState.estimateFileId === "all" ? threeMFFiles : threeMFFiles.filter((f) => f.id === detailState.estimateFileId);

  const rows = [];
  const unavailable = [];
  for (const f of selectedFiles) {
    const stats = selectedPlateStats(f);
    if (!stats) { unavailable.push(f); continue; }
    const level = detailState.manualWorkPerFile[f.id] || "aucun";
    rows.push({ file: f, stats, est: estimatePrint(stats, printer, material, MANUAL_WORK_COST_EUR[level]) });
  }

  let html = rows.map(({ file, est, stats }) => estimateCardHtml(file, est, stats)).join("");
  html += unavailable.map((f) => estimateUnavailableRowHtml(f)).join("");
  if (rows.length > 1) html += totalEstimateCardHtml(totalEstimate(rows.map((r) => r.est)));
  box.innerHTML = html;
  wireEstimateResultEvents(project);
}

function wireEstimateResultEvents(project) {
  const box = document.getElementById("estimateResults");
  box.querySelectorAll(".segmented").forEach((seg) => {
    seg.addEventListener("click", (evt) => {
      const btn = evt.target.closest(".seg-btn");
      if (!btn) return;
      const fileId = seg.dataset.fileId;
      const level = btn.dataset.level;
      detailState.manualWorkPerFile[fileId] = level;
      renderEstimateResults(project);
      api(`/api/files/${fileId}`, { method: "PATCH", body: JSON.stringify({ manualWorkLevel: level }) })
        .catch((e) => console.error("Échec de la sauvegarde du niveau de travail manuel", e));
    });
  });
  box.querySelectorAll(".plate-select").forEach((sel) => {
    sel.addEventListener("change", (evt) => {
      detailState.platePerFile[sel.dataset.fileId] = Number(evt.target.value);
      renderEstimateResults(project);
    });
  });
}

function wireEstimateSection(project) {
  if (!document.getElementById("estimateResults")) return;
  document.getElementById("estimateFileSelect")?.addEventListener("change", (evt) => {
    detailState.estimateFileId = evt.target.value;
    renderEstimateResults(project);
  });
  document.getElementById("estimatePrinterSelect")?.addEventListener("change", (evt) => {
    localStorage.setItem(ESTIMATE_PRINTER_KEY, evt.target.value);
    renderEstimateResults(project);
  });
  document.getElementById("estimateMaterialSelect")?.addEventListener("change", (evt) => {
    localStorage.setItem(ESTIMATE_MATERIAL_KEY, evt.target.value);
    renderEstimateResults(project);
  });
  renderEstimateResults(project);
}

// ── File lists grouped by role (matches roleDisplayOrder in ProjectDetailView.swift) ──

function detailFileRowHtml(file) {
  const icon = FILE_ROLE_ICON[file.fileRole] ?? "📦";
  const thumbUrl = file.kind === "threeMF" ? `/api/files/${file.id}/thumbnail` : null;
  const canPreview = file.fileRole === "modelPart" && VIEWABLE_KINDS.has(file.kind);
  return `
    <div class="detail-file-row">
      <div class="thumb-box">
        ${thumbUrl ? `<img src="${thumbUrl}" onerror="this.replaceWith(Object.assign(document.createElement('span'),{textContent:'${icon}'}))" />` : icon}
      </div>
      <div class="detail-file-info">
        <div class="detail-file-name">${escapeHtml(file.fileName)}<span class="ext">.${escapeHtml(file.fileExtension)}</span></div>
        <div class="detail-file-meta">${formatBytes(file.fileSize)}</div>
      </div>
      <div class="detail-file-actions">
        ${canPreview ? `<button class="icon-btn" data-preview3d="${file.id}" data-filename="${escapeHtml(file.fileName)}.${escapeHtml(file.fileExtension)}" data-kind="${file.kind}" title="Visualiser en 3D">🧊</button>` : ""}
        <a class="icon-btn" href="/api/files/${file.id}/download" download title="Télécharger">⬇</a>
      </div>
    </div>`;
}

function fileSectionHtml(role, files) {
  return `
    <div class="section">
      <div class="section-title">${FILE_ROLE_ICON[role]} ${FILE_ROLE_LABELS[role]}</div>
      <div class="detail-file-list">${files.map((f) => detailFileRowHtml(f)).join("")}</div>
    </div>`;
}

function fileListSectionsHtml(project) {
  const files = project.files || [];
  return FILE_ROLE_ORDER.map((role) => {
    const roleFiles = files.filter((f) => f.fileRole === role);
    return roleFiles.length ? fileSectionHtml(role, roleFiles) : "";
  }).join("");
}

function wireFileListEvents() {
  document.querySelectorAll("[data-preview3d]").forEach((btn) => {
    btn.addEventListener("click", () => openViewer3D(btn.dataset.preview3d, btn.dataset.filename, btn.dataset.kind));
  });
}

// ───────────────────────── Settings (menu Réglages) ─────────────────────────
// Mirrors the macOS app's Settings window (SettingsView.swift): Bibliothèque
// (scan), Matériel (imprimantes/matériaux), Shopify, À propos.

const SETTINGS_TABS = [
  { id: "library", label: "Bibliothèque" },
  { id: "hardware", label: "Matériel" },
  { id: "shopify", label: "Shopify" },
  { id: "about", label: "À propos" },
];

function setSettingsButtonActive(active) {
  document.getElementById("btnSettings").classList.toggle("active", active);
}

async function openSettings(tab) {
  state.view = "settings";
  state.selectedId = null;
  setDetailWide(false);
  if (tab) state.settingsTab = tab;
  renderSidebar();
  setSettingsButtonActive(true);

  const detail = document.getElementById("detail");
  detail.innerHTML = backLinkHtml() + `<div class="placeholder">Chargement des réglages…</div>`;
  wireBackLink();
  try {
    const overview = await api("/api/settings");
    renderSettings(overview);
  } catch (e) {
    detail.innerHTML = backLinkHtml() + `<div class="message err">Impossible de charger les réglages : ${escapeHtml(e.message)}</div>`;
    wireBackLink();
  }
}

function renderSettings(overview) {
  const detail = document.getElementById("detail");
  detail.innerHTML = backLinkHtml() + `
    <h1 class="project-title">Réglages</h1>
    <div class="settings-tabs">
      ${SETTINGS_TABS.map((t) => `<button class="settings-tab ${t.id === state.settingsTab ? "active" : ""}" data-tab="${t.id}">${t.label}</button>`).join("")}
    </div>
    <div id="settingsBody"></div>
  `;
  wireBackLink();
  for (const tabBtn of detail.querySelectorAll(".settings-tab")) {
    tabBtn.addEventListener("click", () => {
      state.settingsTab = tabBtn.dataset.tab;
      renderSettings(overview);
    });
  }
  const body = document.getElementById("settingsBody");
  switch (state.settingsTab) {
    case "library": body.innerHTML = renderLibraryTabHtml(overview); wireLibraryTab(overview); break;
    case "hardware": body.innerHTML = renderHardwareTabHtml(); wireHardwareTab(); break;
    case "shopify": body.innerHTML = renderShopifyTabHtml(overview); wireShopifyTab(overview); break;
    case "about": body.innerHTML = renderAboutTabHtml(overview); break;
  }
}

// ── Bibliothèque tab ──

function renderLibraryTabHtml(overview) {
  return `
    <div class="section">
      <div class="section-title">Média</div>
      <div class="setting-row">
        <div><div class="label">Répertoire média</div><div class="hint">Point de montage générique, fixé au démarrage du conteneur (PRINTPLEX_MEDIA_PATH)</div></div>
        <span class="value">${escapeHtml(overview.mediaPath)}</span>
      </div>
      <div class="setting-row">
        <div><div class="label">Données du serveur</div><div class="hint">Base SQLite et cache de vignettes</div></div>
        <span class="value">${escapeHtml(overview.dataPath)}</span>
      </div>
    </div>

    <div class="section">
      <div class="section-title">Bibliothèques <button class="btn btn-sm" id="btnAddLibrary">+ Ajouter</button></div>
      <div class="hint" style="margin-bottom:10px">Dossiers sous le répertoire média à scanner — comme les bibliothèques Plex.</div>
      <div class="entity-list" id="libraryList"><div class="empty">Chargement…</div></div>
    </div>

    <div class="section">
      <div class="section-title">Scan</div>
      <div class="setting-row">
        <div class="label">Scan automatique</div>
        <input type="checkbox" class="toggle" id="toggleAutoScan" ${overview.autoScanEnabled ? "checked" : ""} />
      </div>
      <div class="setting-row" id="intervalRow" style="${overview.autoScanEnabled ? "" : "display:none"}">
        <div class="label">Intervalle</div>
        <select id="selectInterval">
          <option value="30" ${overview.scanIntervalMinutes === 30 ? "selected" : ""}>30 minutes</option>
          <option value="60" ${overview.scanIntervalMinutes === 60 ? "selected" : ""}>1 heure</option>
          <option value="120" ${overview.scanIntervalMinutes === 120 ? "selected" : ""}>2 heures</option>
          <option value="360" ${overview.scanIntervalMinutes === 360 ? "selected" : ""}>6 heures</option>
        </select>
      </div>
      <div class="setting-row">
        <div>
          <div class="label">Surveillance en temps réel (FSEvents)</div>
          <div class="hint">Non applicable en mode serveur (Linux) — remplacée par le scan périodique ci-dessus.</div>
        </div>
        <input type="checkbox" class="toggle" disabled />
      </div>
      <div class="setting-row">
        <div class="label">Dernier scan</div>
        <span class="value" id="settingsLastScan">–</span>
      </div>
      <button class="btn btn-primary btn-sm" id="btnScanFromSettings" style="margin-top:8px">Scanner maintenant</button>
    </div>
    <div id="scanSettingsMessage"></div>
  `;
}

function wireLibraryTab(overview) {
  api("/api/scan/status").then((s) => {
    document.getElementById("settingsLastScan").textContent = formatDate(s.lastScanDate);
  }).catch(() => {});

  renderLibraryList();
  document.getElementById("btnAddLibrary").addEventListener("click", () => openLibraryModal());

  const toggle = document.getElementById("toggleAutoScan");
  const intervalRow = document.getElementById("intervalRow");
  const select = document.getElementById("selectInterval");
  const msg = document.getElementById("scanSettingsMessage");

  async function saveScanSettings(patch) {
    try {
      await api("/api/settings/scan", { method: "PATCH", body: JSON.stringify(patch) });
      msg.innerHTML = `<div class="message ok">Enregistré.</div>`;
    } catch (e) {
      msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  }

  toggle.addEventListener("change", () => {
    intervalRow.style.display = toggle.checked ? "" : "none";
    saveScanSettings({ autoScanEnabled: toggle.checked });
  });
  select.addEventListener("change", () => {
    saveScanSettings({ scanIntervalMinutes: Number(select.value) });
  });
  document.getElementById("btnScanFromSettings").addEventListener("click", triggerScan);
}

// ── Bibliothèques (Plex-style folder list, under the "Bibliothèque" tab) ──

function libraryRowHtml(lib) {
  const pathLabel = lib.relativePath ? `/${lib.relativePath}` : "(racine du répertoire média)";
  return `
    <div class="entity-row" data-id="${lib.id}">
      <div style="flex:1">
        <div class="entity-name">${escapeHtml(lib.name)}</div>
        <div class="entity-meta">${escapeHtml(pathLabel)}</div>
      </div>
      <button class="icon-btn btn-delete-library" title="Supprimer">🗑</button>
    </div>`;
}

async function renderLibraryList() {
  const listEl = document.getElementById("libraryList");
  if (!listEl) return;
  try {
    const libraries = await api("/api/libraries");
    listEl.innerHTML = libraries.length
      ? libraries.map(libraryRowHtml).join("")
      : `<div class="empty">Aucune bibliothèque — ajoutez un dossier pour commencer le scan.</div>`;
    for (const row of listEl.querySelectorAll(".entity-row")) {
      row.querySelector(".btn-delete-library").addEventListener("click", () => deleteLibrary(row.dataset.id));
    }
  } catch (e) {
    listEl.innerHTML = `<div class="message err">${escapeHtml(e.message)}</div>`;
  }
}

async function deleteLibrary(id) {
  if (!confirm("Supprimer cette bibliothèque ? Ses projets seront retirés de l'index au prochain scan (les fichiers sur disque ne sont pas touchés).")) return;
  try {
    await api(`/api/libraries/${id}`, { method: "DELETE" });
    await renderLibraryList();
  } catch (e) {
    alert(`Échec : ${e.message}`);
  }
}

/// Folder-picker modal for adding a library — mirrors Plex's "browse for
/// folder" dialog: breadcrumb navigation over the media root via
/// GET /api/libraries/browse, plus a manual path field for typing directly.
function openLibraryModal() {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal">
      <h2>Nouvelle bibliothèque</h2>
      <div class="field" style="margin-bottom:10px">
        <label>Nom</label>
        <input id="libNameInput" value="Nouvelle bibliothèque" />
      </div>
      <label class="hint">Dossier</label>
      <div id="libBrowserBreadcrumb" style="margin:4px 0 8px; font-size:12px"></div>
      <div id="libBrowserList" class="entity-list" style="max-height:200px; overflow-y:auto; margin-bottom:10px"></div>
      <div class="field">
        <label>Chemin sélectionné (relatif au répertoire média)</label>
        <input id="libPathInput" value="" />
      </div>
      <div id="libraryModalMessage"></div>
      <div class="modal-actions">
        <button type="button" class="btn btn-sm" id="btnCancelLibrary">Annuler</button>
        <button type="button" class="btn btn-primary btn-sm" id="btnConfirmLibrary">Ajouter</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  async function loadBrowse(path) {
    const listEl = document.getElementById("libBrowserList");
    const msgBox = document.getElementById("libraryModalMessage");
    msgBox.innerHTML = "";
    try {
      const browse = await api(`/api/libraries/browse?path=${encodeURIComponent(path)}`);
      document.getElementById("libPathInput").value = browse.path;

      const segments = browse.path ? browse.path.split("/") : [];
      let crumbHtml = `<button class="btn btn-sm browse-crumb" data-path="">Racine</button>`;
      segments.forEach((seg, i) => {
        const segPath = segments.slice(0, i + 1).join("/");
        crumbHtml += ` / <button class="btn btn-sm browse-crumb" data-path="${escapeHtml(segPath)}">${escapeHtml(seg)}</button>`;
      });
      document.getElementById("libBrowserBreadcrumb").innerHTML = crumbHtml;

      listEl.innerHTML = browse.directories.length
        ? browse.directories.map((d) => {
            const childPath = browse.path ? `${browse.path}/${d}` : d;
            return `<button class="entity-row browse-dir" data-path="${escapeHtml(childPath)}" style="width:100%; text-align:left; cursor:pointer">
              <span style="flex:1">📁 ${escapeHtml(d)}</span>
            </button>`;
          }).join("")
        : `<div class="empty">Aucun sous-dossier</div>`;

      for (const btn of overlay.querySelectorAll(".browse-dir, .browse-crumb")) {
        btn.addEventListener("click", () => loadBrowse(btn.dataset.path));
      }
    } catch (e) {
      msgBox.innerHTML = `<div class="message err">${escapeHtml(e.message)}</div>`;
    }
  }
  loadBrowse("");

  overlay.querySelector("#btnCancelLibrary").addEventListener("click", () => overlay.remove());
  overlay.addEventListener("click", (evt) => { if (evt.target === overlay) overlay.remove(); });

  overlay.querySelector("#btnConfirmLibrary").addEventListener("click", async () => {
    const name = document.getElementById("libNameInput").value.trim();
    const relativePath = document.getElementById("libPathInput").value.trim();
    const msgBox = document.getElementById("libraryModalMessage");
    if (!name) {
      msgBox.innerHTML = `<div class="message err">Le nom est obligatoire.</div>`;
      return;
    }
    try {
      await api("/api/libraries", { method: "POST", body: JSON.stringify({ name, relativePath }) });
      overlay.remove();
      await renderLibraryList();
    } catch (e) {
      msgBox.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });
}

// ── Matériel tab ──

function renderHardwareTabHtml() {
  return `
    <div class="section">
      <div class="section-title">Imprimantes <button class="btn btn-sm" id="btnAddPrinter">+ Ajouter</button></div>
      <div class="entity-list" id="printerList"></div>
    </div>
    <div class="section">
      <div class="section-title">Matériaux disponibles</div>
      <div class="entity-list" id="materialList"></div>
    </div>
    <div id="hardwareMessage"></div>
  `;
}

function printerRowHtml(printer) {
  return `
    <div class="entity-row" data-id="${printer.id}">
      <div style="flex:1">
        <div class="entity-name">${escapeHtml(printer.name)}</div>
        <div class="entity-meta">${Math.round(printer.buildX)}×${Math.round(printer.buildY)}×${Math.round(printer.buildZ)} mm · buse ${printer.nozzleDiameterMM.toFixed(1)} mm</div>
      </div>
      <button class="icon-btn btn-edit-printer" title="Modifier">✏️</button>
      <button class="icon-btn btn-delete-printer" title="Supprimer">🗑</button>
    </div>`;
}

function materialRowHtml(material) {
  return `
    <div class="entity-row" data-id="${material.id}">
      <div style="flex:1">
        <div class="entity-name">${escapeHtml(material.name)}</div>
        <div class="entity-meta">${material.densityGCM3.toFixed(2)} g/cm³</div>
      </div>
      <input class="price-input material-price" type="number" step="0.5" value="${material.pricePerKg.toFixed(2)}" />
      <span class="entity-meta">€/kg</span>
    </div>`;
}

async function renderPrinterAndMaterialLists() {
  document.getElementById("printerList").innerHTML =
    state.printers.map(printerRowHtml).join("") || `<div class="empty">Aucune imprimante</div>`;
  document.getElementById("materialList").innerHTML =
    state.materials.map(materialRowHtml).join("") || `<div class="empty">Aucun matériau</div>`;

  for (const row of document.querySelectorAll("#printerList .entity-row")) {
    const id = row.dataset.id;
    row.querySelector(".btn-edit-printer").addEventListener("click", () => openPrinterModal(state.printers.find((p) => p.id === id)));
    row.querySelector(".btn-delete-printer").addEventListener("click", () => deletePrinter(id));
  }
  for (const row of document.querySelectorAll("#materialList .entity-row")) {
    const id = row.dataset.id;
    row.querySelector(".material-price").addEventListener("change", (evt) => updateMaterialPrice(id, evt.target));
  }
}

function wireHardwareTab() {
  renderPrinterAndMaterialLists();
  document.getElementById("btnAddPrinter").addEventListener("click", () => openPrinterModal(null));
}

async function updateMaterialPrice(id, input) {
  const value = parseFloat(String(input.value).replace(",", "."));
  const msg = document.getElementById("hardwareMessage");
  if (!(value > 0)) {
    msg.innerHTML = `<div class="message err">Le prix doit être positif.</div>`;
    return;
  }
  try {
    await api(`/api/materials/${id}`, { method: "PATCH", body: JSON.stringify({ pricePerKg: value }) });
    await loadReferenceData();
    msg.innerHTML = `<div class="message ok">Prix mis à jour.</div>`;
  } catch (e) {
    msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
  }
}

async function deletePrinter(id) {
  if (!confirm("Supprimer cette imprimante ?")) return;
  const msg = document.getElementById("hardwareMessage");
  try {
    await api(`/api/printers/${id}`, { method: "DELETE" });
    await loadReferenceData();
    renderPrinterAndMaterialLists();
    msg.innerHTML = `<div class="message ok">Imprimante supprimée.</div>`;
  } catch (e) {
    msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
  }
}

// Add/edit printer modal — mirrors PrinterFormSheet in the macOS app.
function openPrinterModal(printer) {
  const isEdit = !!printer;
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal">
      <h2>${isEdit ? "Modifier l'imprimante" : "Nouvelle imprimante"}</h2>
      <form id="printerForm">
        <div class="form-grid">
          <div class="field" style="grid-column:1/-1"><label>Nom</label><input name="name" value="${escapeHtml(printer?.name ?? "Imprimante")}" required /></div>
          <div class="field"><label>X (mm)</label><input name="buildX" type="number" value="${printer?.buildX ?? 256}" required /></div>
          <div class="field"><label>Y (mm)</label><input name="buildY" type="number" value="${printer?.buildY ?? 256}" required /></div>
          <div class="field"><label>Z (mm)</label><input name="buildZ" type="number" value="${printer?.buildZ ?? 256}" required /></div>
          <div class="field"><label>Vitesse périmètres (mm/s)</label><input name="perimeterSpeedMMPS" type="number" value="${printer?.perimeterSpeedMMPS ?? 200}" required /></div>
          <div class="field"><label>Vitesse remplissage (mm/s)</label><input name="infillSpeedMMPS" type="number" value="${printer?.infillSpeedMMPS ?? 300}" required /></div>
          <div class="field"><label>Diamètre buse (mm)</label>
            <select name="nozzleDiameterMM">
              ${[0.2, 0.4, 0.6, 0.8].map((v) => `<option value="${v}" ${((printer?.nozzleDiameterMM ?? 0.4) === v) ? "selected" : ""}>${v.toFixed(1)} mm</option>`).join("")}
            </select>
          </div>
          <div class="field"><label>Supports (%)</label><input name="supportsPercent" type="number" value="${printer?.supportsPercent ?? 20}" /></div>
          <div class="field"><label>Purge (%)</label><input name="purgePercent" type="number" value="${printer?.purgePercent ?? 5}" /></div>
          <div class="field"><label>Efficacité vitesse (0–1)</label><input name="speedEfficiency" type="number" step="0.05" min="0.1" max="1" value="${printer?.speedEfficiency ?? 0.35}" /></div>
        </div>
        <div id="printerModalMessage"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-sm" id="btnCancelPrinter">Annuler</button>
          <button type="submit" class="btn btn-primary btn-sm">Enregistrer</button>
        </div>
      </form>
    </div>`;
  document.body.appendChild(overlay);

  overlay.querySelector("#btnCancelPrinter").addEventListener("click", () => overlay.remove());
  overlay.addEventListener("click", (evt) => { if (evt.target === overlay) overlay.remove(); });

  overlay.querySelector("#printerForm").addEventListener("submit", async (evt) => {
    evt.preventDefault();
    const fd = new FormData(evt.target);
    const payload = {
      name: fd.get("name"),
      buildX: parseFloat(fd.get("buildX")),
      buildY: parseFloat(fd.get("buildY")),
      buildZ: parseFloat(fd.get("buildZ")),
      perimeterSpeedMMPS: parseFloat(fd.get("perimeterSpeedMMPS")),
      infillSpeedMMPS: parseFloat(fd.get("infillSpeedMMPS")),
      nozzleDiameterMM: parseFloat(fd.get("nozzleDiameterMM")),
      defaultLayerHeightMM: printer?.defaultLayerHeightMM ?? 0.2,
      supportsPercent: parseFloat(fd.get("supportsPercent")),
      purgePercent: parseFloat(fd.get("purgePercent")),
      speedEfficiency: parseFloat(fd.get("speedEfficiency")),
    };
    const msgBox = overlay.querySelector("#printerModalMessage");
    try {
      if (isEdit) {
        await api(`/api/printers/${printer.id}`, { method: "PATCH", body: JSON.stringify(payload) });
      } else {
        await api("/api/printers", { method: "POST", body: JSON.stringify(payload) });
      }
      await loadReferenceData();
      renderPrinterAndMaterialLists();
      overlay.remove();
    } catch (e) {
      msgBox.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });
}

// ── Shopify tab ──

function renderShopifyTabHtml(overview) {
  return `
    <div class="section">
      <div class="section-title">Shopify</div>
      <form id="shopifyForm" class="form-grid">
        <div class="field"><label>Boutique</label><input name="storeDomain" placeholder="ma-boutique.myshopify.com" value="${escapeHtml(overview.shopifyStoreDomain)}" /></div>
        <div class="field"><label>Token d'accès admin</label><input name="accessToken" type="password" placeholder="token d'accès (read_products)" /></div>
      </form>
      <button class="btn btn-primary btn-sm" id="btnSaveShopify">Enregistrer</button>
      <button class="btn btn-sm" id="btnSyncShopify" ${overview.shopifyConfigured ? "" : "disabled"}>🔄 Synchroniser</button>
      <div class="setting-row" style="border:none">
        <span class="hint">
          ${overview.shopifyProductCount > 0 ? `${overview.shopifyProductCount} produits` : "Aucune synchronisation"}
          ${overview.shopifyLastSyncDate ? ` · ${formatDate(overview.shopifyLastSyncDate)}` : ""}
        </span>
      </div>
      ${overview.shopifySyncError ? `<div class="message err">${escapeHtml(overview.shopifySyncError)}</div>` : ""}
      <div id="shopifySettingsMessage"></div>
      <p class="hint" style="margin-top:12px">Shopify Admin → Paramètres → Apps → Développer des apps. Accordez la permission read_products.</p>
    </div>
  `;
}

function wireShopifyTab(overview) {
  // Prefill the token separately (kept out of the initial HTML for clarity —
  // it's still plaintext over the local API, same trust model as the app).
  api("/api/settings/shopify").then((s) => {
    document.querySelector('#shopifyForm [name="accessToken"]').value = s.accessToken;
  }).catch(() => {});

  document.getElementById("btnSaveShopify").addEventListener("click", async () => {
    const fd = new FormData(document.getElementById("shopifyForm"));
    const msg = document.getElementById("shopifySettingsMessage");
    try {
      await api("/api/settings/shopify", {
        method: "PUT",
        body: JSON.stringify({ storeDomain: fd.get("storeDomain"), accessToken: fd.get("accessToken") }),
      });
      msg.innerHTML = `<div class="message ok">Enregistré.</div>`;
      openSettings("shopify");
    } catch (e) {
      msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });

  document.getElementById("btnSyncShopify").addEventListener("click", async () => {
    const msg = document.getElementById("shopifySettingsMessage");
    msg.innerHTML = `<div class="hint">Synchronisation…</div>`;
    try {
      await api("/api/shopify/sync", { method: "POST" });
      await onLibraryChanged();
      openSettings("shopify");
    } catch (e) {
      msg.innerHTML = `<div class="message err">Échec : ${escapeHtml(e.message)}</div>`;
    }
  });
}

// ── À propos tab ──

function renderAboutTabHtml(overview) {
  return `
    <div class="section">
      <div class="setting-row"><div class="label">PrintPlex Server</div><span class="value">v${escapeHtml(overview.serverVersion)}</span></div>
      <div class="setting-row"><div class="label">Répertoire média</div><span class="value">${escapeHtml(overview.mediaPath)}</span></div>
    </div>
  `;
}

// ───────────────────────── Boot ─────────────────────────

async function boot() {
  document.getElementById("btnScan").addEventListener("click", triggerScan);
  document.getElementById("btnSettings").addEventListener("click", () => openSettings());
  document.getElementById("searchInput").addEventListener("input", (evt) => {
    state.searchText = evt.target.value;
    if (state.view === "grid") renderGrid();
  });
  wireSidebarEvents();

  connectScanEvents();
  await Promise.all([loadLibrary(), loadReferenceData()]);
  await refreshStatus();
  renderSidebar();
  renderGrid();
  setInterval(refreshStatus, 10000);
}

boot().catch((e) => console.error("Boot failed", e));
