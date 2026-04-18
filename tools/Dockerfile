# =============================================================================
# BAUER GROUP XPD-RPIImage - tools container
#
# Portable dev/test runtime: validate JSON configs, render CustomPiOS module
# artifacts and orchestrate full image builds on any host with Docker.
#
# This container is NOT privileged. The actual image build launches
# guysoft/custompios as a sibling container via the host docker.sock.
# =============================================================================
FROM python:3.14-slim-trixie

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONUTF8=1 \
    FORCE_COLOR=1 \
    PIP_NO_CACHE_DIR=1

# Base tooling + docker apt repo
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash make jq git curl ca-certificates gnupg lsb-release xz-utils \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Python deps - baked at build time. The launcher mirrors the canonical
# ../scripts/requirements.txt into ./tools/requirements.txt just before this
# COPY runs (gitignored; Docker COPY cannot reach outside the build context).
# Rebuild with `run.* --build` after editing scripts/requirements.txt.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

WORKDIR /workspace

# A friendly shell prompt so the user knows they're inside the container.
RUN printf '%s\n' \
    'export PS1="\[\e[1;36m\](bgRPIImage-tools)\[\e[0m\] \w \$ "' \
    'alias ll="ls -la"' \
    > /etc/profile.d/bgRPIImage.sh

CMD ["/bin/bash", "-l"]
