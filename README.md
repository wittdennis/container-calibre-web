# calibre-web

A rootless, read-only-friendly [Calibre-Web](https://github.com/janeczku/calibre-web)
container image with Calibre's `ebook-convert` bundled in — so ebook conversion
works **without** the linuxserver `universal-calibre` DOCKER_MOD, which cannot run
rootless or on a read-only root filesystem.

## Features

- **Rootless** — runs as UID/GID `1000`, never root.
- **Read-only root filesystem** — the process only writes to `/config`, `/books`
  and `/tmp`, so the rootfs can be mounted read-only.
- **Bundled Calibre** — `ebook-convert` runs headless (`QT_QPA_PLATFORM=offscreen`),
  no X server required.
- **Multi-arch** — `linux/amd64` and `linux/arm64`.

## Images

| Registry | Reference |
|----------|-----------|
| GitHub Container Registry | `ghcr.io/wittdennis/calibre-web` |
| Docker Hub | `docker.io/denniswitt/calibre-web` |

## Usage

```sh
podman run -d \
  --name calibre-web \
  -p 8083:8083 \
  -v calibre-config:/config \
  -v /path/to/books:/books \
  ghcr.io/wittdennis/calibre-web:latest
```

Then open <http://localhost:8083>. On first run point Calibre-Web at the library
under `/books`.

### Read-only root filesystem

`/config` must stay writable (it holds `app.db` and the cache); `/tmp` is only
needed for conversion scratch space and can be a `tmpfs`:

```sh
podman run -d \
  --name calibre-web \
  --read-only \
  --tmpfs /tmp \
  -p 8083:8083 \
  -v calibre-config:/config \
  -v /path/to/books:/books \
  ghcr.io/wittdennis/calibre-web:latest
```

### Kubernetes

Mount `/config` and `/books` as writable volumes and set a matching security
context. `fsGroup` fixes up mount ownership at runtime:

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  readOnlyRootFilesystem: true
```

Provide an `emptyDir` for `/tmp` when the rootfs is read-only.

## Configuration

Defaults are set in the image; override via environment variables if needed.

| Variable | Default | Purpose |
|----------|---------|---------|
| `CALIBRE_DBPATH` | `/config` | Location of the settings db (`app.db`). |
| `CACHE_DIRECTORY` | `/config/cache` | Calibre-Web cache directory. |
| `CALIBRE_PORT` | `8083` | Port Calibre-Web binds on `0.0.0.0`. |
| `HOME` | `/config` | Where Calibre writes its config/cache. |
| `CALIBRE_TEMP_DIR` | `/tmp` | Conversion scratch space. |
| `QT_QPA_PLATFORM` | `offscreen` | Headless Qt for `ebook-convert`. |

The defaults point config, cache and temp away from the read-only site-packages
directory, which is what makes the read-only rootfs work.

## Volumes

| Path | Contents |
|------|----------|
| `/config` | Settings db, cache — persist this. |
| `/books` | Calibre library. |

## Building

```sh
podman build -t ghcr.io/wittdennis/calibre-web:local .
```

Bundled versions (Python base image, Calibre and Calibre-Web) are pinned in the
`Dockerfile` and kept up to date by [Renovate](https://docs.renovatebot.com/).

## License

[MIT](LICENSE)
