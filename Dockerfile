FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

# ==========================================
# SYSTEM BINARIES & EXTERNAL CLI TOOLS
# Installed BEFORE source COPY so these layers are cached independently
# of source code changes. A git pull that only touches .ts files won't
# re-download any of these binaries.
# ==========================================

# Optional extra apt packages (for custom deployments)
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
  fi

# 1. Media tools, Python, and Calendar CLI
RUN apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ffmpeg \
  imagemagick \
  python3 \
  gcalcli \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. GitHub CLI (gh)
RUN mkdir -p -m 755 /etc/apt/keyrings && \
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# 3. yt-dlp (social media video downloader)
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && \
  chmod a+rx /usr/local/bin/yt-dlp

# 4. gog CLI (Google Workspace: Gmail, Calendar, Drive)
ARG GOG_VERSION=0.11.0
ARG TARGETARCH=amd64
RUN curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin/ gog \
  && chmod +x /usr/local/bin/gog

# 5. goplaces CLI (Google Maps / Places)
ARG GOPLACES_VERSION=0.3.0
RUN curl -fsSL "https://github.com/steipete/goplaces/releases/download/v${GOPLACES_VERSION}/goplaces_${GOPLACES_VERSION}_linux_${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin/ \
  && chmod +x /usr/local/bin/goplaces

# ==========================================
# NODE DEPENDENCIES
# Cached unless package.json / lockfile changes — not busted by source edits.
# ==========================================
COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
RUN pnpm install --frozen-lockfile

# ==========================================
# OPTIONAL: Chromium + Playwright (browser automation)
# Build with: docker compose build --build-arg OPENCLAW_INSTALL_BROWSER=1
# Placed after pnpm install (needs playwright-core in node_modules) but
# BEFORE full source COPY, so source changes don't bust this layer.
# ==========================================
ARG OPENCLAW_INSTALL_BROWSER=""
USER root
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
  mkdir -p /home/node/.cache/ms-playwright && \
  PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
  node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
  chown -R node:node /home/node/.cache/ms-playwright && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
  fi

# ==========================================
# APP BUILD
# Only invalidated when source files change. Everything above stays cached.
# ==========================================
USER node
COPY --chown=node:node . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Security hardening: run as non-root
# The node:22-bookworm image includes a 'node' user (uid 1000)
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
