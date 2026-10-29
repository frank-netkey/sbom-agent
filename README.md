# sbom-agent

Per-Docker-host scanner container: every `RECONCILE_INTERVAL` seconds it lists running containers, scans each
**exact deployed image ID** with Syft, strips redundant CPEs, and uploads the CycloneDX SBOM to Dependency-Track.

## Layout

| File | Purpose |
|---|---|
| `Dockerfile` | Alpine + bash, jq, curl, tini, Syft, Docker CLI (versions are build args; pin by digest for release) |
| `docker-compose.yml` | `docker-proxy` (only thing with the socket) + `agent` (read-only rootfs, non-root, caps dropped, limits) |
| `scripts/entrypoint.sh` | Loop, heartbeat, signal handling |
| `scripts/reconcile.sh` | One pass: discover → scan → filter → upload → marker; `--list` is a dry run |
| `scripts/identities.jq` | Container → stable service identity |
| `scripts/filter-sbom.jq` | Drop `.cpe` only where `.purl` is non-empty |

## Behaviour

- **Version = first 12 hex of the image ID**, project = `<HOST_ID>/<identity>`, uploaded with `autoCreate=true&isLatest=true`.
  Redeploying the same image does nothing; a new image ID creates a new version and marks it latest.
- **Identity** (first match): label `sbom.name` → `coolify.resourceName[/compose service]` → `compose project/service` →
  container name minus Coolify's trailing `-<12+ digit timestamp>`. Run `docker exec <agent> /opt/sbom/reconcile.sh --list`
  and check the names look right **before** the first real upload; set `sbom.name` on anything that doesn't.
- **Per-container labels:** `sbom.scan=false` (skip), `sbom.dtrack.project=<uuid>` (upload to that existing project instead
  of name/version), `sbom.tags=a,b` (extra tags).
- **State in `/state`:** `markers/` (what was uploaded: image ID + config fingerprint), `sboms/<imageid>.cdx.json`
  (reused if an upload failed, or two services share an image; garbage-collected once no marker references it and it is >1 day old),
  `failures/` (exponential backoff 1 min → 1 h per service), `heartbeat` (healthcheck).
- **Retries:** curl retries network errors / 5xx 4× within a pass; a failed service is then retried on later passes with backoff.
  DT being down skips the pass.
- The API key is written to a tmpfs header file, so it never shows up in `ps`.

## Provenance and hashes

Each SBOM is annotated before upload (`scripts/annotate-sbom.jq`):
- `metadata.properties`: `sbom-agent:image-id`, `image-ref`, `host`, `generated-at`.
- `metadata.component.hashes`: the image's repo (manifest) digest as SHA-256, when the image has one (locally built images don't).

The SHA-256 of the stored SBOM is kept next to it (`/state/sboms/<id>.cdx.json.sha256`) and in the upload marker (`sbom_sha256`).
A cached SBOM whose hash no longer matches is discarded and rescanned instead of uploaded. Dependency-Track may not display
`metadata.properties`; the data is in the SBOM and in `/state`. Hashes of individual components/files are not added (large SBOMs, slower scans).

Further enrichment (`annotate-sbom.jq`), following the "essential elements" in the NCSC/TNO SBOM starter guide:
- `metadata.authors` (`SBOM_AUTHOR`, default `sbom-agent (<HOST_ID>)`) and `metadata.lifecycles` (`operations`, CycloneDX >= 1.5 only).
- A root entry in `dependencies` for the image component (components nobody depends on become its direct dependencies), so the
  dependency graph has a root.

Quality summary (`quality-sbom.jq`): per SBOM the agent logs and stores in the marker the share of components with a PURL, a version
and a hash, plus components with no identifier at all. A warning is logged when the PURL share is below `QUALITY_MIN_PURL_PCT` (default 80).
It is informational only; the SBOM is still uploaded.

## Deploy (Coolify)

1. Put this directory in a Git repo; create a **Docker Compose** resource on the target server (build from the repo), or
   build/push the image yourself and replace `build:` with `image:`.
2. Set `DTRACK_API_KEY` (required), and optionally `DTRACK_URL`, `HOST_ID`, `DEFAULT_TAGS`, `RECONCILE_INTERVAL`.
3. In Dependency-Track create a team (e.g. `sbom-agents`) with only **BOM_UPLOAD** and **PROJECT_CREATION_UPLOAD**
   and generate its API key. Add `PORTFOLIO_MANAGEMENT` only if DT rejects the upload when setting tags/`isLatest` on an
   existing project (I could not verify the exact 5.2 requirement). Do not use an admin key.
4. Deploy one stack per Docker host with a distinct `HOST_ID`.

## Health

Both services have a compose `healthcheck`, so Coolify and `docker ps` show `(healthy)`. The agent starts only after the proxy is healthy.

The agent is **healthy** when it is alive and making progress. It is **unhealthy** when:

- `/state/heartbeat` is older than `HEALTH_MAX_AGE` (default `3 x RECONCILE_INTERVAL + SCAN_TIMEOUT`). The heartbeat is touched
  around every target, so a long pass stays healthy; or
- `consecutive_failed_passes` in `/state/status.json` reaches `HEALTH_FAIL_PASSES` (default 10, about 10 minutes). A pass counts as
  failed when Dependency-Track is unreachable or no target is in a good state. One broken image (in backoff) does not.

```bash
docker inspect --format '{{json .State.Health}}' <agent-container>
docker exec <agent-container> cat /state/status.json
```

`status.json` fields: `finished_at`, `dt_reachable`, `targets`, `ok`, `failed`, `backoff`, `consecutive_failed_passes`.
Tests: `bash tests/healthcheck.sh`.

## About the Docker socket

Anything that can talk to `/var/run/docker.sock` is effectively root on the host: it can start a privileged container with `/`
mounted. **`:ro` on the mount does not help.** It only stops the socket *file* from being modified; every API call
(`POST /containers/create`, `exec`, …) still works. The scanner also parses untrusted image contents, so it is the
component most worth isolating. That is why the socket goes only to `docker-proxy`, which allows `GET` on
`/containers` and `/images` (`POST=0` blocks everything else), and the agent reaches it over an `internal` network.
Remaining exposure: the proxy still runs as root with the socket, and read access to container inspect data exposes env vars
(secrets) of every container to the agent. Treat the agent's compromise as "can read all container env + image contents".

## Verification status

**Tested** (Docker 29.8.2, image built, fake Dependency-Track endpoint, Docker socket mounted directly, run as root):
- Image builds; contains Syft 1.14.0, Docker CLI 27.3.1, jq 1.7.1.
- Discovers a running container, scans its exact image ID with real Syft, uploads the ~228 KB SBOM to `/api/v1/bom`
  with `X-Api-Key`, names the project from the `sbom.name` label.
- No component in the uploaded SBOM has both `purl` and `cpe`.
- A second pass uploads nothing (markers work).

**Not tested yet:**
- The socket proxy's read-only filter with Syft's image export (most likely to need a tweak, e.g. `INFO=1`).
- The hardened runtime (non-root, read-only rootfs, dropped capabilities).
- A real Dependency-Track 5.2 instance (including the exact API-key permissions needed).

First-run checklist after deploying:

```bash
docker logs -f <agent>                                # look for "uploaded <host>/<name> @ <version>"
docker exec <agent> /opt/sbom/reconcile.sh --list     # identities
```

If Syft fails through the proxy, the log shows which endpoint was denied (403); enable the matching proxy flag.
Syft/Docker CLI/Alpine versions in the Dockerfile are build args; bump to current and pin digests for releases.

## Optional: event trigger

Later, add a background `docker events --filter type=container --filter event=start` that wakes the loop early. The
minute poll is idempotent, so this is purely latency.
