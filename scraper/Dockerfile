# Official Playwright image: Chromium + every system lib it needs already
# baked in. The tag MUST match the exact playwright version pinned in
# package.json / package-lock.json, or Playwright can't find its browser.
FROM mcr.microsoft.com/playwright:v1.62.1-noble

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY relay.js scrape.js scrape-makerworld.js lib.js ./

# Scraped photos are re-sent to the server then never needed again.
ENV PRINTPLEX_URL=http://printplex:8080
CMD ["node", "relay.js"]
