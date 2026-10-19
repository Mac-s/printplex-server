// Bridges the PrintPlex dashboard's source-import section (ForgeCore, Budwin,
// ...) to this machine: polls the server for projects the dashboard has
// marked as awaiting a scrape (paste URL + click "Lancer le scraping" in the
// project detail view), picks the right scraper from the pasted URL's domain
// (scrape.js for prinnit.com/ForgeCore, scrape-makerworld.js for makerworld.com
// — neither needs a login), and posts the result back so
// the server writes the photos and metadata into the project folder and
// clears the pending status.
//
// Runs as the `scraper` service of the server's docker-compose.yml; the
// dashboard button just marks a project as "waiting" and this picks it up.
//
// Usage: node relay.js [url-du-serveur-printplex] [--interval=20] [--api-key=ppx_...]
// (or PRINTPLEX_URL / PRINTPLEX_RELAY_INTERVAL / PRINTPLEX_API_KEY). The API
// key comes from the web dashboard, Réglages → Compte.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";

const execFileAsync = promisify(execFile);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT_DIR = path.join(HERE, "output");

function parseArgs() {
  const args = process.argv.slice(2);
  const serverUrl = args.find((a) => !a.startsWith("--")) || process.env.PRINTPLEX_URL;
  const intervalArg = args.find((a) => a.startsWith("--interval="));
  const intervalSeconds = intervalArg ? Number(intervalArg.split("=")[1]) : Number(process.env.PRINTPLEX_RELAY_INTERVAL || 20);
  const apiKeyArg = args.find((a) => a.startsWith("--api-key="));
  const apiKey = (apiKeyArg ? apiKeyArg.split("=")[1] : process.env.PRINTPLEX_API_KEY) || "";
  if (!serverUrl || !Number.isFinite(intervalSeconds) || intervalSeconds <= 0) {
    console.error("Usage: node relay.js <url-du-serveur-printplex> [--interval=20] [--api-key=ppx_...]  (ou PRINTPLEX_URL / PRINTPLEX_API_KEY)");
    process.exit(1);
  }
  return { serverUrl: serverUrl.replace(/\/$/, ""), intervalSeconds, apiKey };
}

function formatHardwareLine(item) {
  return item.quantity == null ? item.name : `${item.name} × ${item.quantity}`;
}

// Picks the scraper script from the pasted URL's domain — this is the one
// place that knows which sites are supported. Add a new site by adding an
// entry here (and its own scrape-<site>.js, matching the others' output
// shape: output/<name>/{data.json, gallery/, users-gallery/, instructions/}).
function scraperForUrl(sourceUrl) {
  let hostname;
  try {
    hostname = new URL(sourceUrl).hostname;
  } catch {
    return null;
  }
  if (hostname.endsWith("prinnit.com")) {
    return { script: "scrape.js", args: [], tag: "forgecore" };
  }
  if (hostname.endsWith("makerworld.com")) {
    // 0 community photos by default — a busy design can have dozens, and
    // nothing in the current workflow asks for them.
    return { script: "scrape-makerworld.js", args: ["--community-photos=0"], tag: "makerworld" };
  }
  return null;
}

async function fetchPending(serverUrl, apiKey) {
  const res = await fetch(`${serverUrl}/api/forgecore/pending`, {
    headers: { "X-API-Key": apiKey },
  });
  if (!res.ok) throw new Error(`GET /api/forgecore/pending → HTTP ${res.status}`);
  return res.json();
}

async function postResult(serverUrl, apiKey, projectId, result) {
  const res = await fetch(`${serverUrl}/api/projects/${projectId}/forgecore-import-result`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-Key": apiKey },
    body: JSON.stringify(result),
  });
  if (!res.ok) {
    console.error(`  ✘ Échec de l'envoi du résultat au serveur : HTTP ${res.status}`);
  }
}

async function readPhotos(dir, prefix) {
  let entries;
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }
  const photos = [];
  for (const entry of entries) {
    const bytes = await fs.readFile(path.join(dir, entry));
    photos.push({ filename: `${prefix}-${entry}`, dataBase64: bytes.toString("base64") });
  }
  return photos;
}

// scrape.js names its output folder after the design's title, which isn't
// known ahead of time — find whichever folder holds a data.json whose own
// `url` field matches, rather than guessing the folder name.
async function findScrapedDir(sourceUrl) {
  let entries;
  try {
    entries = await fs.readdir(OUT_DIR, { withFileTypes: true });
  } catch {
    throw new Error(`Dossier de sortie introuvable (${OUT_DIR})`);
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    try {
      const data = JSON.parse(await fs.readFile(path.join(OUT_DIR, entry.name, "data.json"), "utf8"));
      if (data.url === sourceUrl) return path.join(OUT_DIR, entry.name);
    } catch {
      continue;
    }
  }
  throw new Error(`Dossier scrapé introuvable pour ${sourceUrl}`);
}

async function scrapeAndReport(serverUrl, apiKey, project) {
  console.log(`→ ${project.name} : scraping de ${project.sourceUrl}…`);
  const scraper = scraperForUrl(project.sourceUrl);
  if (!scraper) {
    const message = `Site non pris en charge pour le moment : ${project.sourceUrl}`;
    console.error(`  ✘ ${message}`);
    await postResult(serverUrl, apiKey, project.id, { success: false, error: message });
    return;
  }

  try {
    await execFileAsync("node", [path.join(HERE, scraper.script), project.sourceUrl, ...scraper.args], { cwd: HERE });
  } catch (e) {
    console.error(`  ✘ ${scraper.script} a échoué : ${e.message}`);
    await postResult(serverUrl, apiKey, project.id, { success: false, error: `${scraper.script} a échoué : ${e.message}` });
    return;
  }

  try {
    const scrapedDir = await findScrapedDir(project.sourceUrl);
    const data = JSON.parse(await fs.readFile(path.join(scrapedDir, "data.json"), "utf8"));
    const result = {
      success: true,
      description: data.description || undefined,
      sourceHardware: data.hardware?.length ? data.hardware.map(formatHardwareLine) : undefined,
      sourceEstimatedWeight: data.weight || undefined,
      sourceEstimatedPrintTime: data.printTime || undefined,
      galleryPhotos: await readPhotos(path.join(scrapedDir, "gallery"), `${scraper.tag}-gallery`),
      communityPhotos: await readPhotos(path.join(scrapedDir, "users-gallery"), `${scraper.tag}-communaute`),
      instructionPhotos: await readPhotos(path.join(scrapedDir, "instructions"), `${scraper.tag}-instructions`),
    };
    await postResult(serverUrl, apiKey, project.id, result);
    console.log(`  ✔ ${project.name} importé.`);
  } catch (e) {
    console.error(`  ✘ ${e.message}`);
    await postResult(serverUrl, apiKey, project.id, { success: false, error: e.message });
  }
}

async function tick(serverUrl, apiKey) {
  let pending;
  try {
    pending = await fetchPending(serverUrl, apiKey);
  } catch (e) {
    console.error(`✘ Impossible de contacter le serveur (${serverUrl}) : ${e.message}`);
    return;
  }
  // One at a time — a single shared Playwright browser per design keeps
  // resource use predictable and isolates failures to one project at a time.
  for (const project of pending) {
    await scrapeAndReport(serverUrl, apiKey, project);
  }
}

let tickInFlight = false;
async function safeTick(serverUrl, apiKey) {
  if (tickInFlight) return; // previous tick still running — don't overlap
  tickInFlight = true;
  try {
    await tick(serverUrl, apiKey);
  } finally {
    tickInFlight = false;
  }
}

async function main() {
  const { serverUrl, intervalSeconds, apiKey } = parseArgs();
  // Chicken-and-egg on first `docker compose up`: the API key is generated
  // from the dashboard (Réglages → Compte), which doesn't exist yet. Idle
  // and say so rather than exiting into a restart loop.
  if (!apiKey) {
    console.log("PRINTPLEX_API_KEY absente — copie la clé depuis Réglages → Compte, mets-la dans .env puis `docker compose up -d`. En attente…");
    setInterval(() => {}, 1 << 30);
    return;
  }
  console.log(`Relais de scraping démarré — vérifie ${serverUrl} toutes les ${intervalSeconds}s.`);
  await safeTick(serverUrl, apiKey);
  setInterval(() => safeTick(serverUrl, apiKey), intervalSeconds * 1000);
}

main();
