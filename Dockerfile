# --- Stage 1: build the hey CLI -------------------------------------------
FROM golang:1.26-bookworm AS hey-build

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/basecamp/hey-cli .

RUN CGO_ENABLED=0 go build -trimpath -o /out/hey ./cmd/hey \
    || CGO_ENABLED=0 go build -trimpath -o /out/hey .

# --- Stage 2: runtime ------------------------------------------------------
FROM python:3.12-slim-bookworm

RUN useradd --create-home --uid 10001 heyuser \
    && apt-get update \
    && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hey-build /out/hey /usr/local/bin/hey

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY hey_client.py server.py oauth_provider.py entrypoint.sh ./
COPY skills ./skills
RUN chmod +x /app/entrypoint.sh

ENV HOME=/home/heyuser \
    HEY_NO_KEYRING=1 \
    MCP_TRANSPORT=http \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8765 \
    PYTHONUNBUFFERED=1

EXPOSE 8765

# Start as root so entrypoint can chown the named volume, then drop to heyuser.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "server.py"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/healthz', timeout=3).status==200 else 1)"
