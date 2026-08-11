# Rootless, read-only-friendly Calibre-Web image built from scratch.
# - Calibre-Web installed from PyPI (`calibreweb`) with every optional extra, so
#   the full feature set (LDAP, OAuth, GDrive, Gmail, Kobo sync, comics,
#   metadata providers) is usable without rebuilding
# - Calibre binaries bundled at build time so ebook conversion works WITHOUT the
#   linuxserver universal-calibre DOCKER_MOD (which cannot run rootless/read-only)
# - kepubify bundled for Kobo kepub conversion, ImageMagick + Ghostscript for
#   PDF cover extraction, unar for comic archives
# - At runtime the process writes only to /config, /books and /tmp, so the root
#   filesystem can be mounted read-only.
#
# Multi-arch publishing is handled in CI (.github/workflows/publish.yaml).
# Local build:
#   podman build -t ghcr.io/<owner>/calibre-web:local .

ARG PYTHON_VERSION=3.12

# ---------------------------------------------------------------------------
# Stage 1: fetch and unpack the bundled binaries. curl/xz-utils live only here
# so they stay out of the final image.
# ---------------------------------------------------------------------------
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS binaries

# Provided automatically for the target platform (amd64 | arm64).
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-releases depName=calibre packageName=kovidgoyal/calibre
ARG CALIBRE_VERSION=9.13.0

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

# renovate: datasource=github-releases depName=kepubify packageName=pgaskin/kepubify
ARG KEPUBIFY_VERSION=4.0.4

# Calibre-Web only auto-detects /opt/kepubify/kepubify-linux-64bit, so the arm64
# build has to be installed under that name too (see cps/config_sql.py).
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) kep_asset=kepubify-linux-64bit ;; \
        arm64) kep_asset=kepubify-linux-arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/kepubify; \
    curl -fSL -o /opt/kepubify/kepubify-linux-64bit \
        "https://github.com/pgaskin/kepubify/releases/download/v${KEPUBIFY_VERSION}/${kep_asset}"; \
    chmod 0755 /opt/kepubify/kepubify-linux-64bit; \
    /opt/kepubify/kepubify-linux-64bit --version

# ---------------------------------------------------------------------------
# Stage 2: build the Python environment. python-ldap has no wheels, so it needs
# a compiler plus the LDAP/SASL headers — none of which reach the final image.
# ---------------------------------------------------------------------------
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm AS pydeps

# renovate: datasource=pypi packageName=calibreweb
ARG CALIBRE_WEB_VERSION=0.6.27

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libldap2-dev \
        libsasl2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir \
        "calibreweb[comics,gdrive,gmail,goodreads,kobo,ldap,metadata,oauth]==${CALIBRE_WEB_VERSION}"

# ---------------------------------------------------------------------------
# Stage 3: runtime image.
# ---------------------------------------------------------------------------
FROM docker.io/library/python:${PYTHON_VERSION}-slim-bookworm

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
    PATH="/opt/venv/bin:/opt/calibre:${PATH}"

# System libraries:
# - libmagic1                 python-magic (file type detection)
# - libldap/libsasl + modules LDAP authentication
# - libmagickwand             Wand, i.e. PDF and comic cover extraction
# - ghostscript               ImageMagick's PDF delegate
# - unar                      CBR comic archives. rarfile prefers `unrar`, but
#                             that is non-free and unrar-free fails rarfile's
#                             tool check; unar reads RAR3 and RAR5 and rarfile
#                             falls back to it on its own.
# The remaining libs are what Calibre's bundled Qt needs for headless
# conversion; libasound2 in particular is a hard requirement of QtWebEngine,
# without which PDF output fails to load.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libmagic1 \
        libldap-2.5-0 \
        libsasl2-2 \
        libsasl2-modules \
        libmagickwand-6.q16-6 \
        ghostscript \
        unar \
        libfontconfig1 \
        libgl1 \
        libglx-mesa0 \
        libegl1 \
        libopengl0 \
        libnss3 \
        libglib2.0-0 \
        libasound2 \
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

# Debian ships ImageMagick with the Ghostscript-backed coders disabled, which
# also blocks the PDF read Calibre-Web needs for cover extraction. Only PDF is
# re-enabled, and read-only: PS/EPS/XPS stay off.
RUN sed -i '/pattern="PDF"/d' /etc/ImageMagick-6/policy.xml \
    && sed -i 's|</policymap>|  <policy domain="coder" rights="read" pattern="PDF" />\n</policymap>|' \
        /etc/ImageMagick-6/policy.xml

# Calibre-Web plus its optional dependencies.
COPY --from=pydeps /opt/venv /opt/venv

# Bundled Calibre for ebook-convert and kepubify for Kobo kepub conversion.
# Both stay in /opt (read-only at runtime) where Calibre-Web auto-detects them.
COPY --from=binaries /opt/calibre /opt/calibre
COPY --from=binaries /opt/kepubify /opt/kepubify

# Fixed non-root user; ownership of the mounts is handled at runtime via fsGroup.
RUN groupadd -g 1000 calibre \
    && useradd -u 1000 -g 1000 -d /config -s /usr/sbin/nologin calibre \
    && mkdir -p /config /books \
    && chown -R 1000:1000 /config /books

USER 1000:1000
WORKDIR /config
EXPOSE 8083
VOLUME ["/config", "/books"]

# calibre-web binds 0.0.0.0:$CALIBRE_PORT by default.
ENTRYPOINT ["cps"]
