# --- Stage 1: build the hey CLI -------------------------------------------
FROM golang:1.26-bookworm AS hey-build

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/basecamp/hey-cli .

RUN CGO_ENABLED=0 go build -trimpath -o /out/hey ./cmd/hey \
    || CGO_ENABLED=0 go build -trimpath -o /out/hey .

# --- Stage 2: runtime ------------------------------------------------------
FROM ruby:4.0.6-slim-bookworm

RUN useradd --create-home --uid 10001 heyuser \
    && apt-get update \
    && apt-get install -y --no-install-recommends gosu curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hey-build /out/hey /usr/local/bin/hey

WORKDIR /app
COPY Gemfile Gemfile.lock ./
# build-essential is needed to compile native extensions (bigdecimal, nio4r,
# puma), then purged. Bundler is upgraded to match Gemfile.lock (BUNDLED WITH).
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && gem install bundler --no-document \
    && bundle config set --local deployment false \
    && bundle config set --local without development \
    && bundle install --jobs 4 \
    && apt-get purge -y --auto-remove build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY hey_client.rb server.rb oauth_provider.rb entrypoint.sh ./
COPY skills ./skills
RUN chmod +x /app/entrypoint.sh

ENV HOME=/home/heyuser \
    HEY_NO_KEYRING=1 \
    MCP_TRANSPORT=http \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8765

EXPOSE 8765

# Start as root so entrypoint can chown the named volume, then drop to heyuser.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "server.rb"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS http://127.0.0.1:8765/healthz > /dev/null || exit 1
