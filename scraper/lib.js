// Helpers shared by every per-site scraper (scrape.js, scrape-makerworld.js, ...).
import fs from "node:fs/promises";
import path from "node:path";

export async function downloadImage(page, src, destPath) {
  const bytes = await page.evaluate(async (url) => {
    const res = await fetch(url);
    return Array.from(new Uint8Array(await res.arrayBuffer()));
  }, src);
  await fs.writeFile(destPath, Buffer.from(bytes));
}

export function extFor(src) {
  const ext = path.extname(new URL(src).pathname);
  return ext || ".webp";
}

// Strips characters that are illegal (or just awkward) in folder names on
// macOS/Windows, collapses whitespace, and caps the length so an unusually
// long title can't blow past filesystem path limits. Falls back to null on
// an empty/whitespace-only title so the caller can use the URL slug instead.
export function sanitizeFolderName(title) {
  if (!title) return null;
  const cleaned = title
    .replace(/[\/\\:*?"<>|]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 100);
  return cleaned || null;
}
