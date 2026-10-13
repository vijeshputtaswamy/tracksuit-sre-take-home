# ---- Stage 1: build the single-file server binary ----
FROM denoland/deno:debian-2.4.2 AS build
WORKDIR /app
COPY deno.json deno.lock ./
COPY client/deno.json ./client/deno.json
COPY lib ./lib
COPY server ./server
RUN cd server && deno task build

# ---- Stage 2: minimal runtime image ----
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r app && useradd -r -g app -u 10001 app \
 && mkdir /data && chown app:app /data
COPY --from=build /app/server/build/server /usr/local/bin/server

ENV SERVER_PORT=8080 \
    DENO_SQLITE_PATH=/usr/lib/x86_64-linux-gnu/libsqlite3.so.0

WORKDIR /data
USER app
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
  CMD curl -fsS http://127.0.0.1:8080/_health || exit 1
ENTRYPOINT ["/usr/local/bin/server"]
