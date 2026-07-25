# ================================ Build ================================
FROM swift:6.1-noble AS build
WORKDIR /build

COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build -c release --product PrintPlexServerApp

# ================================ Run ==================================
FROM swift:6.1-noble-slim

RUN useradd --create-home printplex
WORKDIR /app
COPY --from=build /build/.build/release/PrintPlexServerApp /app/
COPY Public /app/Public

RUN chown -R printplex:printplex /app
USER printplex
EXPOSE 8080

ENTRYPOINT ["./PrintPlexServerApp"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
