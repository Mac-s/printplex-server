// Manual, one-shot scraper for MakerWorld design pages (makerworld.com/*/models/...).
// Unlike ForgeCore, MakerWorld pages are fully public — no login/session needed.
// Usage: node scrape-makerworld.js <design-url> [<design-url> ...] [--community-photos=N]
//   --community-photos=N : download at most N community (comment/review) photos
//                           per design. Omitted or 0 (the default) skips the
//                           community gallery entirely — on a busy design it
//                           can otherwise mean dozens of extra downloads.
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import { downloadImage, extFor, sanitizeFolderName } from "./lib.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT_DIR = path.join(HERE, "output");

function formatWeight(grams) {
  if (grams == null) return null;
  return grams >= 1000 ? `${(grams / 1000).toFixed(2)}kg` : `${grams}g`;
}

// MakerWorld gives print time as a prediction in seconds — reformatted to
// match the "2d 5h 44m" style already used by the ForgeCore scraper.
function formatDuration(seconds) {
  if (seconds == null) return null;
  let totalMinutes = Math.round(seconds / 60);
  const days = Math.floor(totalMinutes / 1440);
  totalMinutes %= 1440;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  const parts = [];
  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (minutes || parts.length === 0) parts.push(`${minutes}m`);
  return parts.join(" ");
}

// The model's numeric id is the leading digits of the URL slug
// ("/models/2889593-mmpr-red-ranger-helmet" → 2889593) — used both to
// sanity-check the page loaded the right design and to query the public
// comments API for community photos.
function designIdFromUrl(url) {
  const m = url.match(/\/models\/(\d+)/);
  return m ? m[1] : null;
}

async function scrapeDesign(page, url, { maxCommunityPhotos }) {
  const designId = designIdFromUrl(url);
  if (!designId) throw new Error(`URL MakerWorld inattendue (pas d'id de modèle) : ${url}`);

  await page.goto(url, { waitUntil: "domcontentloaded" });
  // The page's data is a client-hydrated Next.js payload, not present in the
  // raw HTML — wait for React to attach it rather than for any DOM element.
  await page.waitForFunction(() => window.__NEXT_DATA__?.props?.pageProps?.design, { timeout: 30000 });

  const extracted = await page.evaluate(() => {
    const d = window.__NEXT_DATA__.props.pageProps.design;

    // MakerWorld's description is rich-text HTML — convert through a real
    // DOM element (handles entities and nested tags correctly) rather than
    // regex-stripping tags by hand.
    function htmlToText(html) {
      if (!html) return null;
      const div = document.createElement("div");
      div.innerHTML = html.replace(/<\/p>/gi, "\n\n").replace(/<br\s*\/?>/gi, "\n");
      const text = div.textContent.replace(/ /g, " ").replace(/\n{3,}/g, "\n\n").trim();
      return text || null;
    }

    const ext = d.designExtension ?? {};
    const galleryUrls = [...new Set((ext.design_pictures ?? []).map((p) => p.url))];
    // Each print profile also carries its own "real print" photos from the
    // designer (as opposed to the polished renders above) — folded into the
    // same official gallery, deduped against it.
    const instancePhotoUrls = [
      ...new Set(d.instances.flatMap((i) => (i.pictures ?? []).map((p) => p.url))),
    ].filter((u) => !galleryUrls.includes(u));

    const printProfiles = d.instances.map((i) => ({
      title: i.title,
      weight: i.weight != null ? (i.weight >= 1000 ? `${(i.weight / 1000).toFixed(2)}kg` : `${i.weight}g`) : null,
      needAms: !!i.needAms,
      plateCount: i.extention?.modelInfo?.plates?.length ?? null,
      filaments: (i.instanceFilaments ?? []).map((f) => ({ type: f.type, color: f.color, usedGrams: Number(f.usedG) })),
      // printTime formatted Node-side (formatDuration isn't available here).
      printTimeSeconds: i.prediction ?? null,
    }));

    const defaultInstance = d.instances.find((i) => i.isDefault) ?? d.instances[0] ?? {};

    return {
      title: d.title ?? null,
      designer: d.designCreator?.name ?? null,
      license: d.license ?? null,
      tags: d.tags ?? [],
      description: htmlToText(d.summary),
      weightGrams: defaultInstance.weight ?? null,
      printTimeSeconds: defaultInstance.prediction ?? null,
      amsRequired: !!defaultInstance.needAms,
      hardware: (ext.boms ?? []).map((b) => ({
        name: b.parentTitle || b.title,
        quantity: b.quantity ?? null,
        url: b.url ?? null,
      })),
      filamentsNeeded: (ext.boms_of_filaments ?? []).map((f) => f.title).filter(Boolean),
      printProfiles,
      galleryUrls: [...galleryUrls, ...instancePhotoUrls],
    };
  });

  // Community photos live on comments/ratings, fetched from the public API
  // MakerWorld's own front-end uses. Skipped entirely unless the caller
  // asked for some — a busy design can have dozens of these, and fetching/
  // downloading them all on every run made the scraper needlessly slow.
  const usersGalleryUrls = maxCommunityPhotos > 0
    ? await page.evaluate(async (designId) => {
        const res = await fetch(
          `/api/v1/comment-service/commentandrating?designId=${designId}&limit=500&msgId=0&msgType=0`
        );
        const data = await res.json();
        const urls = [];
        const collect = (entry) => {
          if (!entry) return;
          if (entry.images) urls.push(...entry.images);
          if (entry.commentReply) entry.commentReply.forEach(collect);
        };
        for (const hit of data.hits ?? []) {
          collect(hit.comment);
          collect(hit.ratingItem);
        }
        return [...new Set(urls)];
      }, designId).then((urls) => urls.slice(0, maxCommunityPhotos))
    : [];

  const weight = formatWeight(extracted.weightGrams);
  const printTime = formatDuration(extracted.printTimeSeconds);
  const printProfiles = extracted.printProfiles.map((p) => ({
    ...p,
    printTime: formatDuration(p.printTimeSeconds),
    printTimeSeconds: undefined,
  }));

  const folderName = sanitizeFolderName(extracted.title) || designId;
  const dir = path.join(OUT_DIR, folderName);
  await fs.mkdir(path.join(dir, "gallery"), { recursive: true });
  await fs.mkdir(path.join(dir, "users-gallery"), { recursive: true });
  await fs.mkdir(path.join(dir, "instructions"), { recursive: true });

  for (const [i, src] of extracted.galleryUrls.entries()) {
    await downloadImage(page, src, path.join(dir, "gallery", `${i + 1}${extFor(src)}`));
  }
  for (const [i, src] of usersGalleryUrls.entries()) {
    await downloadImage(page, src, path.join(dir, "users-gallery", `${i + 1}${extFor(src)}`));
  }
  // MakerWorld has no separate "assembly instructions" concept/tab —
  // instructions/ stays empty, kept only so import.js's folder layout
  // (gallery/users-gallery/instructions) works unchanged across sources.

  const data = {
    url,
    scrapedAt: new Date().toISOString(),
    title: extracted.title,
    designer: extracted.designer,
    license: extracted.license,
    tags: extracted.tags,
    description: extracted.description,
    weight,
    printTime,
    dimensions: null, // not published by MakerWorld
    amsRequired: extracted.amsRequired,
    difficulty: null, // not published by MakerWorld
    hardware: extracted.hardware,
    filamentsNeeded: extracted.filamentsNeeded,
    printProfiles,
    galleryUrls: extracted.galleryUrls,
    usersGalleryUrls,
    instructionUrls: [],
  };
  await fs.writeFile(path.join(dir, "data.json"), JSON.stringify(data, null, 2));
  console.log(
    `✔ ${extracted.title ?? designId} → ${path.relative(HERE, dir)}/ ` +
    `(${extracted.galleryUrls.length} photos officielles, ${usersGalleryUrls.length} photos communauté, ` +
    `${extracted.hardware.length} pièce(s) hardware, ${printProfiles.length} profil(s) d'impression)`
  );
  return data;
}

async function main() {
  const urls = [];
  let maxCommunityPhotos = 0;
  for (const arg of process.argv.slice(2)) {
    const m = arg.match(/^--community-photos=(\d+)$/);
    if (m) {
      maxCommunityPhotos = Number(m[1]);
    } else {
      urls.push(arg);
    }
  }
  if (urls.length === 0) {
    console.error(
      "Usage: node scrape-makerworld.js <url-fiche-makerworld> [<url> ...] [--community-photos=N]"
    );
    process.exit(1);
  }

  // MakerWorld sits behind Cloudflare bot detection that stalls Playwright's
  // default headless Chromium on a "Just a moment..." challenge forever —
  // a realistic user agent plus hiding the automation flag is enough to
  // pass it (verified against a real design page).
  const browser = await chromium.launch({
    headless: true,
    args: ["--disable-blink-features=AutomationControlled"],
  });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    viewport: { width: 1280, height: 800 },
    locale: "fr-FR",
  });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => undefined });
  });
  const page = await context.newPage();

  let failures = 0;
  for (const url of urls) {
    try {
      await scrapeDesign(page, url, { maxCommunityPhotos });
    } catch (e) {
      failures++;
      console.error(`✘ Échec pour ${url} : ${e.message}`);
    }
  }

  await browser.close();
  if (failures > 0) process.exit(1);
}

main();
