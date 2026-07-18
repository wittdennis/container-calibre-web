# Rootless, read-only-friendly Calibre-Web image built from scratch.
# - Calibre-Web installed from PyPI (`calibreweb`)
# - Calibre binaries bundled at build time so ebook conversion works WITHOUT the
#   linuxserver universal-calibre DOCKER_MOD (which cannot run rootless/read-only)
# - At runtime the process writes only to /config, /books and /tmp, so the root
#   filesystem can be mounted read-only.
#
# Multi-arch publishing is handled in CI (.github/workflows/publish.yaml).
# Local build:
#   podman build -t ghcr.io/<owner>/calibre-web:0.6.26 .

ARG PYTHON_VERSION=3.12

# ---------------------------------------------------------------------------
# Stage 1: fetch and unpack Calibre. curl/xz-utils live only here so they stay
# out of the final image; only /opt/calibre is carried forward.
# ---------------------------------------------------------------------------
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS calibre

# renovate: datasource=github-releases depName=calibre packageName=kovidgoyal/calibre
ARG CALIBRE_VERSION=9.11.0
# Provided automatically for the target platform (amd64 | arm64).
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) cal_arch=x86_64 ;; \
        arm64) cal_arch=arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/calibre /config; \
    curl -fSL -o /tmp/calibre.txz \
        "https://download.calibre-ebook.com/${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}-${cal_arch}.txz"; \
    tar xf /tmp/calibre.txz -C /opt/calibre; \
    rm /tmp/calibre.txz; \
    # HOME must exist so postinstall's desktop-integration probe doesn't error;
    # the remaining desktop-integration warnings are harmless.
    HOME=/config /opt/calibre/calibre_postinstall || true

# ---------------------------------------------------------------------------
# Stage 2: runtime image.
# ---------------------------------------------------------------------------
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm

# renovate: datasource=pypi packageName=calibreweb
ARG CALIBRE_WEB_VERSION=0.6.26

ENV \
    # Calibre-Web: settings db (app.db), cache and port. Defaults for these point
    # inside the read-only site-packages dir, so they MUST be redirected.
    CALIBRE_DBPATH=/config \
    CACHE_DIRECTORY=/config/cache \
    CALIBRE_PORT=8083 \
    # Calibre (ebook-convert) writes config/cache under $HOME and temp under here.
    HOME=/config \
    CALIBRE_TEMP_DIR=/tmp \
    # Run Qt headless; no X server in the container.
    QT_QPA_PLATFORM=offscreen \
    # Don't attempt to write .pyc into the read-only site-packages.
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/calibre:${PATH}"

# System libraries: calibre-web runtime + the shared libs Calibre's bundled Qt
# needs for headless conversion (mirrors the universal-calibre mod's package list).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libmagic1 \
        libldap-2.5-0 \
        libsasl2-2 \
        libfontconfig1 \
        libgl1 \
        libglx-mesa0 \
        libegl1 \
        libopengl0 \
        libnss3 \
        libglib2.0-0 \
        libxcb-cursor0 \
        libxkbcommon0 \
        libxkbfile1 \
        libxdamage1 \
        libxrandr2 \
        libxcomposite1 \
        libxtst6 \
        libxi6 \
        libxrender1 \
        libxext6 \
        libx11-xcb1 \
    && rm -rf /var/lib/apt/lists/*

# Calibre-Web itself.
RUN pip install --no-cache-dir "calibreweb==${CALIBRE_WEB_VERSION}"

# Bundled Calibre for ebook-convert. Kept in /opt/calibre (read-only at runtime).
COPY --from=calibre /opt/calibre /opt/calibre

# Fixed non-root user; ownership of the mounts is handled at runtime via fsGroup.
RUN groupadd -g 1000 abc \
    && useradd -u 1000 -g 1000 -d /config -s /usr/sbin/nologin abc \
    && mkdir -p /config /books \
    && chown -R 1000:1000 /config /books

USER 1000:1000
WORKDIR /config
EXPOSE 8083
VOLUME ["/config", "/books"]

# calibre-web binds 0.0.0.0:$CALIBRE_PORT by default.
ENTRYPOINT ["cps"]
