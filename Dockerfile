# syntax=docker/dockerfile:1
FROM oven/bun:1.4.2 AS base
WORKDIR /app

FROM base AS deps
WORKDIR /app
COPY package.json bun.lock ./
COPY bun-patches ./bun-patches
COPY packages/ui/package.json ./packages/ui/
COPY packages/web/package.json ./packages/web/
COPY packages/electron/package.json ./packages/electron/
COPY packages/vscode/package.json ./packages/vscode/
COPY packages/mobile/package.json ./packages/mobile/
COPY packages/sdk/package.json ./packages/sdk/
RUN bun install --frozen-lockfile --ignore-scripts

FROM deps AS builder
WORKDIR /app
COPY . .
# The server imports @openchamber/sdk at runtime, and deps installed with
# --ignore-scripts, so the root postinstall never built it. Build it here
# so the runtime stage can copy the output.
RUN bun run --cwd packages/sdk build
RUN bun run build:web

FROM oven/bun:1.4.2 AS runtime
WORKDIR /home/openchamber

# Package postinstalls must not try to start services during the build: there
# is no init system in the image.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  curl \
  # >>> docker-in-docker (sysbox): the inner daemon needs iptables to build
  # the network for the containers it starts.
  iptables \
  git \
  less \
  nodejs \
  npm \
  openssh-client \
  python3 \
  sudo \
  && rm -rf /var/lib/apt/lists/*

# >>> docker-in-docker (sysbox): install the Docker ENGINE (dockerd), not just
# the CLI, following Docker's official Debian instructions
# (https://docs.docker.com/engine/install/debian/). This container runs its own
# daemon and never mounts the host's docker socket. On a Sysbox host that
# daemon is confined to this container's user namespace, so no --privileged is
# needed on the host side.
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
       "$(. /etc/os-release && echo "\$VERSION_CODENAME")" \
       "$(dpkg --print-architecture)" \
       > /etc/apt/sources.list.d/docker.sources \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
       docker-ce \
       docker-ce-cli \
       containerd.io \
       docker-buildx-plugin \
       docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/* \
  && rm -f /usr/sbin/policy-rc.d

# Replace the base image's 'bun' user (UID 1000) with 'openchamber'
# so mounted volumes with 1000:1000 ownership work correctly.
RUN userdel bun \
  && groupadd -g 1000 openchamber \
  && useradd -u 1000 -g 1000 -m -s /bin/bash openchamber \
  && chown -R openchamber:openchamber /home/openchamber

# >>> docker-in-docker (sysbox): let openchamber use the INNER dockerd's
# socket. dockerd creates /var/run/docker.sock as root:docker, so join the
# 'docker' group. docker-ce already created it, so pin its GID (982).
RUN if getent group docker >/dev/null; then groupmod -g 982 docker; else groupadd -g 982 docker; fi \
  && usermod -aG docker openchamber

# Allow the openchamber user to install packages and write outside $HOME.
# !requiretty keeps it working for non-interactive tool invocations.
RUN printf '%s\n' \
  'Defaults:openchamber !requiretty' \
  'openchamber ALL=(ALL) NOPASSWD:ALL' \
  > /etc/sudoers.d/openchamber \
  && chmod 0440 /etc/sudoers.d/openchamber \
  && chown root:root /etc/sudoers.d/openchamber \
  && visudo -cf /etc/sudoers.d/openchamber

# Switch to openchamber user
USER openchamber

ENV NPM_CONFIG_PREFIX=/home/openchamber/.npm-global
ENV PATH=${NPM_CONFIG_PREFIX}/bin:${PATH}
# >>> docker-in-docker (sysbox): the client talks to the daemon running in THIS
# container (started below), not to the host's.
# ENV DOCKER_HOST=unix:///var/run/docker.sock

RUN npm config set prefix /home/openchamber/.npm-global && mkdir -p /home/openchamber/.npm-global && \
  mkdir -p /home/openchamber/.local /home/openchamber/.config /home/openchamber/.ssh && \
  npm install -g @opencode/cli@2.0.18

# cloudflared 2026.3.0 - update digest explicitly when upgrading
COPY --from=cloudflare/cloudflared@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

ENV NODE_ENV=production
# The base image ships with the POSIX locale, which makes bash readline treat
# every byte of a multibyte character separately in the built-in terminal.
ENV LANG=C.UTF-8

COPY scripts/docker-entrypoint.sh /home/openchamber/openchamber-entrypoint.sh

# >>> docker-in-docker (sysbox): wrapper ENTRYPOINT. It starts the inner
# dockerd (via sudo, inside the container's user namespace), waits for it to
# answer, then hands off to the normal OpenChamber entrypoint unchanged.
RUN cat > /home/openchamber/dind-entrypoint.sh <<'SCRIPT'
#!/bin/sh
set -eu

sudo dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver="vfs" \
  >/tmp/dockerd.log 2>&1 &

tries=0
until docker info >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "inner dockerd did not become ready; last log lines:" >&2
    tail -n 50 /tmp/dockerd.log >&2 || true
    exit 1
  fi
  sleep 1
done

exec sh /home/openchamber/openchamber-entrypoint.sh "$@"
SCRIPT

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages/web/node_modules ./packages/web/node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/packages/web/package.json ./packages/web/package.json
COPY --from=builder /app/packages/sdk/package.json ./packages/sdk/package.json
COPY --from=builder /app/packages/sdk/dist ./packages/sdk/dist
COPY --from=builder /app/packages/web/bin ./packages/web/bin
COPY --from=builder /app/packages/web/server ./packages/web/server
COPY --from=builder /app/packages/web/dist ./packages/web/dist

EXPOSE 3000

ENTRYPOINT ["sh", "/home/openchamber/dind-entrypoint.sh"]

