# ================================ Build ================================
FROM swift:6.1-noble AS build
WORKDIR /build

COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build -c release --product PrintPlexServerApp

# ================================ Run ==================================
FROM swift:6.1-noble-slim

# gosu: lets the entrypoint start as root (to fix up the printplex user's
# UID/GID against PUID/PGID) and then drop privileges before exec'ing the
# server, instead of baking a fixed UID into the image at build time.
# Downloaded as the official static binary (not reliably packaged as a distro
# apt package) — matches TARGETARCH, which buildx sets per-platform even when
# building linux/amd64 and linux/arm64 from the same Dockerfile.
ARG TARGETARCH
ENV GOSU_VERSION=1.17
# libvips-tools: provides `vipsthumbnail`, used to generate compressed cover
# thumbnails for the project grid (kept as a runtime apt package rather than
# a Swift dependency since it's a native image codec, not something the
# iOS/macOS client targets need). It lives in Ubuntu's "universe" component,
# which isn't guaranteed enabled by default on every base image variant —
# add-apt-repository turns it on explicitly rather than assuming.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update && apt-get install -y --no-install-recommends libvips-tools \
    && curl -fsSL -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${TARGETARCH}" \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version \
    && apt-get purge -y --auto-remove curl software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home printplex
WORKDIR /app
COPY --from=build /build/.build/release/PrintPlexServerApp /app/
COPY Public /app/Public
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && chown -R printplex:printplex /app

EXPOSE 8080

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["./PrintPlexServerApp", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
