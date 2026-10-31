# Plan: health check + Coolify template

## Where we are

- `Dockerfile` has a `HEALTHCHECK` that only checks `/state/heartbeat` was modified in the last 20 min.
- `docker-compose.yml` defines **no** healthcheck for either service, so Coolify shows no meaningful status for the stack.
- The heartbeat is touched once per *finished* pass. Two gaps:
  1. A long pass (many images x `SCAN_TIMEOUT=900`) can exceed 20 min and flip to unhealthy while working normally.
  2. A pass where Dependency-Track is down, or every upload fails, still touches the heartbeat. "Healthy" only means "loop is alive".

## Part 1: health check

**Goal:** Docker/Coolify status reflects "the agent is alive and making progress", while "uploads are failing" is visible
without restart loops.

1. **Progress signal.** Touch `/state/heartbeat` at the start and end of every `process_target`, not only per pass, so a long
   pass stays healthy.
2. **Status file.** At the end of each pass write `/state/status.json`:
   `{finished_at, dt_reachable, targets, ok, failed, backoff, consecutive_failed_passes}` (atomic write via tmp + mv).
3. **Health script** `scripts/healthcheck.sh` (replaces the inline `find`):
   - **unhealthy** if the heartbeat is older than `HEALTH_MAX_AGE` (default `3 x RECONCILE_INTERVAL + SCAN_TIMEOUT`);
   - **unhealthy** if `consecutive_failed_passes >= HEALTH_FAIL_PASSES` (default 10: DT unreachable or every target failing for ~10 min);
   - otherwise healthy. A single failing service (in backoff) must **not** make the container unhealthy.
4. **Compose.** Add an explicit `healthcheck:` to `agent` (`CMD /opt/sbom/healthcheck.sh`, interval 60s, timeout 5s,
   retries 3, start_period 120s). Needed because Coolify reads compose health, and a template should not rely on the image.
5. **Proxy.** Add a healthcheck to `docker-proxy` and `depends_on: condition: service_healthy` on the agent.
   *Unverified:* the tecnativa image's available tooling (`wget`/`nc`); check inside the container first. Fallback: TCP check
   with the shell built-in `/dev/tcp` if a shell exists, otherwise skip and keep plain `depends_on`.
6. **Tests (local, stubs as before).** Fresh heartbeat -> 0; stale -> 1; `consecutive_failed_passes=10` -> 1;
   one failing target among healthy ones -> 0; long pass (sleeping stub) keeps heartbeat fresh.
7. **Docs.** README section "Health": what healthy means, `docker inspect --format '{{json .State.Health}}'`, `status.json` fields.

**Done when:** `docker ps` shows `(healthy)` on both services in Coolify, stopping Dependency-Track for ~10 min turns the
agent `unhealthy`, and one broken image does not.

## Part 2: Coolify template

**Possible: yes. Needed: not for our own use** (the repo-based Docker Compose deployment works), but it gives one-click
deploys and a shareable compose. Reference format: `templates/compose/trigger.yaml` in coollabsio/coolify (header
comments `documentation`, `slogan`, `category`, `tags`, `logo`, `port`, then a plain compose `services:` block).

**Blockers / differences vs. our current compose**

| Topic | Today | Template |
|---|---|---|
| Image | `build: .` | Must be a prebuilt `image:` -> publish to `ghcr.io/frank-netkey/sbom-agent:<version>` first (see TODO) |
| Top-level `name:` | set | omit |
| Required vars | `${VAR:?msg}` | keep `:?` for `DTRACK_URL`, `DTRACK_API_KEY`, `HOST_ID`; verify Coolify renders them as required fields |
| Secrets | plain env | `DTRACK_API_KEY` is user-supplied (no `SERVICE_PASSWORD_*` magic var applies) |
| Port header | n/a (no web UI) | verify whether `port:` is optional for headless services |
| Limits | `deploy.resources.limits` incl. `pids` | worked in Coolify after the earlier fix; re-verify |
| Internal network | custom `internal: true` network | verify Coolify keeps it; otherwise drop it and rely on the proxy ACL |
| Docker socket | mounted in proxy only | allowed in other templates, but expect review scrutiny; keep the README explanation and link it in `documentation:` |

**Steps**

1. Finish Part 1 (health checks are required for a good template).
2. Add GitHub Action: build, tag (`vX.Y.Z` + `latest`), push to ghcr.io, make the package public. Pin base images by digest here.
3. Create `coolify-template/sbom-agent.yaml` in this repo: header comments + compose with `image:` (no `build:`).
   Test it via Coolify "Docker Compose Empty" on a real host. This is already shareable with colleagues.
4. Re-check the contribution guide in the Coolify repo (format may have changed since the example commit), then open a PR adding
   `templates/compose/sbom-agent.yaml` plus a logo. Upstream acceptance is the maintainers' call; the self-hosted template from step 3 is the fallback.

**Done when:** a fresh Coolify host can deploy the stack from the template with only the three variables filled in, and both
containers report healthy.

## Order

Part 1 (steps 1-7) -> image publishing (Part 2 step 2) -> template file (step 3) -> upstream PR (step 4).

---

# Plan 2: stable versions, project relationships, quick wins

## Problem 1: a redeploy creates a new Dependency-Track project

Versioning already works (version = image ID, `isLatest=true`). The new projects come from **identities that change per
deployment**. Seen in DT: `n8n01/docker-image-<uuid>/<uuid>-20261024T112144` (Coolify "Docker Image" resource: the compose
service label carries a `-YYYYMMDDTHHMMSS` deploy timestamp). The current strip regex only removes `-<12+ digits>`, and only from
the container name, not from the compose service.

**Fix (identities.jq):** one `normalize` function applied to every identity segment (container name *and* compose service):
strip trailing `-<12+ digits>` and `-YYYYMMDDTHHMMSS(Z)`. Keep the Coolify resource UUID (it is stable per resource).
`sbom.name` stays the explicit override. Old timestamped projects stay in DT; deleting them is a manual step for the user.

## Problem 2: no relationship between containers of one Coolify resource

Use DT parent/child projects. Group = the stack the container belongs to (`coolify.resourceName`, else compose project),
overridable with label `sbom.parent`; containers without a group get no parent.

- Parent project `<HOST_ID>/<group>` with a fixed version (`PARENT_VERSION`, default `current`).
- Parent is created with least privilege: upload a minimal (zero-component) CycloneDX BOM with `autoCreate=true`
  (same BOM_UPLOAD + PROJECT_CREATION_UPLOAD permissions), once per group, recorded in `/state/parents/`.
- Children are uploaded with `parentName`/`parentVersion`. If the parent step fails, the child is uploaded without a parent
  and a WARN is logged (never block SBOM uploads on the relationship).
- Feature flag `DTRACK_PARENTS` (default `true`). Unverified against DT 5.2: exact parent parameter names/behaviour.
- Optional manual step in DT UI: mark parents as collection projects (aggregate latest child versions).

## Quick wins from TODO

- **Publish workflow** `.github/workflows/publish.yml`: build + push `ghcr.io/frank-netkey/sbom-agent`, triggered only by
  `v*` tags and manual dispatch (nothing is published until a tag is pushed).
- **Pin base images by digest** in the Dockerfile (tags kept as comments); report the socket-proxy digest for the compose file.
- **Stub test harness** `tests/run.sh` (fake docker/syft/curl/timeout) so behaviour changes are tested repeatably.
- TODO cleanup: the `docker-image-*` projects are not ephemeral builds (Problem 1); the dependency-graph-root item is done.

## Execution

Two parallel workers with disjoint files:
- **A**: `scripts/identities.jq`, `scripts/reconcile.sh`, `scripts/lib.sh`, `docker-compose.yml` (env only), `README.md`, `tests/`.
- **B**: `.github/workflows/`, `Dockerfile`.
Then review, run tests, update TODO, commit.
