# Hermes Agent Railway SaaS — Dockerfile
# Installs hermes-agent from GitHub + Node.js for gateway runtimes

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ENV HOME=/data \
    HERMES_HOME=/data/.hermes \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js (required by some gateway runtimes)
RUN apt-get update && \
    apt-get install -y --no-install-recommends gnupg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get purge -y --auto-remove gnupg && \
    rm -rf /var/lib/apt/lists/*

RUN node --version && npm --version

# Install hermes-agent from source
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent && \
    cd /tmp/hermes-agent && \
    uv pip install --system --no-cache -e ".[all]" && \
    rm -rf /tmp/hermes-agent/.git

# Install honcho for memory persistence (SQLite-backed)
RUN pip install --no-cache-dir honcho

WORKDIR /app

# Copy application files
COPY server.py /app/server.py
COPY start.sh /app/start.sh
COPY requirements.txt /app/requirements.txt
COPY templates/ /app/templates/

# Install Python app dependencies
RUN pip install --no-cache-dir -r /app/requirements.txt

RUN chmod +x /app/start.sh

# Create data volume mount point (Railway volume mounted at runtime)
RUN mkdir -p /data && chmod 777 /data

EXPOSE ${PORT:-8080}

CMD ["/app/start.sh"]
