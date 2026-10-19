// Manual, one-shot scraper for ForgeCore design pages (prinnit.com/ForgeCore/design/...).
// No login needed: every field read here is public on a logged-out page.
// Usage: node scrape.js <design-url> [<design-url> ...]
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import { downloadImage, extFor, sanitizeFolderName } from "./lib.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT_DIR = path.join(HERE, "output");

// The page's text follows a predictable shape (verified against a real
// design page), but ForgeCore is a normal SPA whose CSS class names are
// build-hashed and can change on any deploy — parsing the rendered *text*
// this way is far more resilient than chasing exact class names, at the
// cost of being a little more heuristic.
function parseDetails(bodyText) {
  const lines = bodyText.split("\n").map((l) => l.trim()).filter(Boolean);

  const title = lines[0] ?? null;
  const unlocksLine = lines.find((l) => /unlocks/i.test(l)) ?? null;
  // Weight can be in grams ("641.98g") or kilograms for larger prints
  // ("1.16kg") — verified against two real designs. Print time can include
  // a leading days component too ("2d 5h 44m"), not just hours/minutes.
  const weight = lines.find((l) => /^\d+(\.\d+)?\s*k?g$/i.test(l)) ?? null;
  const printTime = lines.find((l) => /^(?:\d+d\s*)?(?:\d+h\s*)?(?:\d+m)?$/i.test(l) && /\d/.test(l)) ?? null;
  const dimensions = lines.find((l) => /^\d+(\.\d+)?\s*[x×]\s*\d+(\.\d+)?\s*[x×]\s*\d+(\.\d+)?\s*mm$/i.test(l)) ?? null;
  const amsRequired = lines.some((l) => /AMS Required/i.test(l));

  const detailsIdx = lines.indexOf("Design Details");
  const difficulty = detailsIdx >= 0 ? lines[detailsIdx + 1] : null;

  // The "Description"/"Instructions" tab labels are two consecutive lines;
  // the description's own text (when that tab is active, which it is by
  // default on page load) immediately follows them, up to "Comments".
  const descIdx = lines.indexOf("Description");
  const commentsIdx = lines.indexOf("Comments");
  let description = null;
  if (descIdx >= 0 && commentsIdx > descIdx) {
    const afterTabs = lines[descIdx + 1] === "Instructions" ? descIdx + 2 : descIdx + 1;
    description = lines.slice(afterTabs, commentsIdx).join("\n").trim() || null;
  }

  return { title, unlocksLine, weight, printTime, dimensions, amsRequired, difficulty, description };
}

async function scrapeDesign(page, url) {
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForSelector("text=Design Details", { timeout: 30000 });

  const bodyText = await page.locator("main").innerText();
  const details = parseDetails(bodyText);

  // Gallery images live in the top carousel — matched by a *partial* class
  // name (ignoring the CSS-module hash suffix, e.g. "_carouselImage_153dj_37")
  // so this keeps working across ForgeCore front-end deploys.
  const galleryUrls = await page.$$eval('img[class*="carouselImage"]', (imgs) => [
    ...new Set(imgs.map((i) => i.src)),
  ]);

  // Community Gallery photos are lazy-loaded and only get a real `src` once
  // the section scrolls into view — a plain scrollIntoView on the heading
  // isn't enough to fire it (verified: 0 images loaded that way), but
  // jumping the whole window to the bottom is.
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await page.waitForTimeout(1500);

  // Hardware (extra parts like magnets/screws) — not every design needs any,
  // in which case this stays an empty list. Click the toggle explicitly
  // rather than assuming it's pre-rendered, matching the "Instructions" tab
  // handling below.
  let hardware = [];
  const hardwareTab = page.getByText("Hardware", { exact: true }).first();
  if (await hardwareTab.count()) {
    await hardwareTab.click();
    await page.waitForTimeout(500);
    const pillTexts = await page.evaluate(() => {
      // Same hidden-duplicate rendering quirk as "Community Gallery" above —
      // several copies of each pill exist, only one is actually visible.
      const isVisible = (el) => {
        const r = el.getBoundingClientRect();
        const style = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && style.display !== "none" && style.visibility !== "hidden";
      };
      return [...document.querySelectorAll('[class*="hardwarePill"]')]
        .filter(isVisible)
        .map((el) => el.textContent.trim());
    });
    // Each pill's text is one unseparated blob, e.g. "N52 Magnet (6 x
    // 2mm)Quantity: 8Affiliate link" — split name from quantity by regex.
    hardware = pillTexts.map((text) => {
      const m = text.match(/^(.*?)Quantity:\s*(\d+)/);
      return m ? { name: m[1].trim(), quantity: Number(m[2]) } : { name: text, quantity: null };
    });
  }

  // Instruction step images only render once that tab is active.
  const instructionsTab = page.getByText("Instructions", { exact: true }).first();
  if (await instructionsTab.count()) {
    await instructionsTab.click();
    await page.waitForTimeout(1000);
  }
  const allImageUrls = await page.$$eval('img[src*="images.prinnit.com"]', (imgs) => [
    ...new Set(imgs.map((i) => i.src)),
  ]);
  // Community Gallery photos (other printers' shots) live under a distinct
  // URL path ("community-gallery/") regardless of markup or DOM position —
  // far more reliable than the previous heading-position heuristic, which
  // depended on that section having already rendered/scrolled into view by
  // the time it ran and silently returned nothing when it hadn't.
  const usersGalleryUrls = allImageUrls.filter((src) => src.includes("community-gallery"));
  const instructionUrls = allImageUrls.filter(
    (src) => !galleryUrls.includes(src) && !usersGalleryUrls.includes(src)
  );

  // Named after the design's title (e.g. "Battery Bank") rather than the
  // opaque URL id — falls back to the id only if the title is somehow empty.
  const slug = url.split("/").filter(Boolean).pop();
  const folderName = sanitizeFolderName(details.title) || slug;
  const dir = path.join(OUT_DIR, folderName);
  await fs.mkdir(path.join(dir, "gallery"), { recursive: true });
  await fs.mkdir(path.join(dir, "users-gallery"), { recursive: true });
  await fs.mkdir(path.join(dir, "instructions"), { recursive: true });

  for (const [i, src] of galleryUrls.entries()) {
    await downloadImage(page, src, path.join(dir, "gallery", `${i + 1}${extFor(src)}`));
  }
  for (const [i, src] of usersGalleryUrls.entries()) {
    await downloadImage(page, src, path.join(dir, "users-gallery", `${i + 1}${extFor(src)}`));
  }
  for (const [i, src] of instructionUrls.entries()) {
    await downloadImage(page, src, path.join(dir, "instructions", `${i + 1}${extFor(src)}`));
  }

  const data = {
    url, scrapedAt: new Date().toISOString(), ...details, hardware,
    galleryUrls, usersGalleryUrls, instructionUrls,
  };
  await fs.writeFile(path.join(dir, "data.json"), JSON.stringify(data, null, 2));
  console.log(
    `✔ ${details.title ?? slug} → ${path.relative(HERE, dir)}/ ` +
    `(${galleryUrls.length} photos officielles, ${usersGalleryUrls.length} photos communauté, ` +
    `${instructionUrls.length} images d'instructions, ${hardware.length} pièce(s) hardware)`
  );
  return data;
}

async function main() {
  const urls = process.argv.slice(2);
  if (urls.length === 0) {
    console.error("Usage: node scrape.js <url-fiche-forgecore> [<url> ...]");
    process.exit(1);
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  let failures = 0;
  for (const url of urls) {
    try {
      await scrapeDesign(page, url);
    } catch (e) {
      failures++;
      console.error(`✘ Échec pour ${url} : ${e.message}`);
    }
  }

  await browser.close();
  if (failures > 0) process.exit(1);
}

main();
