# TODO

Detailed plan for the health check and the Coolify template: see [PLAN.md](PLAN.md).

## Open

- [ ] **Coolify one-click service template.** Coolify service templates are compose files with metadata header comments
      (documentation, slogan, tags, logo) in the Coolify repo under `templates/compose/`, contributed via PR. Check the
      current contribution guide first (format may have changed); there is no separate documentation step, the `documentation:`
      header just links to this README. Needs: a prebuilt image (ghcr.io), since templates can't build from source.
- [ ] **Publish the image to ghcr.io:** workflow exists (`.github/workflows/publish.yml`, runs on `v*` tags). First release: push a
      tag (e.g. `v0.1.0`), make the ghcr package public, then point Coolify at `ghcr.io/frank-netkey/sbom-agent:<version>`.
- [ ] **Verify first Coolify deploy on a real host:** socket proxy ACL with Syft image export (maybe `INFO=1`), non-root +
      read-only rootfs, scoped DT API key permissions.
- [ ] **Dependency-Track vulnerability sources:** confirm OSV + GitHub Advisories have mirrored, then re-analyse and check
      findings. Optionally script the extension config (`PUT /extension-points/vuln-data-source/extensions/{osv,github}/config`)
      once the request bodies are captured from the UI.
- [ ] **CPE filter:** strip `.cpe` only for language-ecosystem PURLs (golang, npm, pypi, maven, ...), keep it on apk/deb/rpm,
      if OS packages show no findings with PURL-only matching.
- [ ] **After deploying identity normalization:** delete the old per-deploy projects in DT (e.g. `n8n01/docker-image-*/*-2026…T…`),
      and check that parent projects appear (DT 5.2 parent behaviour is unverified).
- [ ] Optional: bump Syft (pinned v1.14.0, latest v1.55.0), Docker CLI (27.3.1 -> 29.9.2) and Alpine (3.20.3 -> 3.24.3); retest after.
- [ ] Optional: `docker events` trigger for faster scans after deployments.

## Done

- [x] Stable identities across redeploys (deploy timestamps stripped) and parent/child projects per Coolify resource.
- [x] Dependency graph root for the image component.
- [x] Base images and socket proxy pinned by digest; CI (`bash -n`, shellcheck, tests) and publish workflows.
- [x] Stub test harness: `bash tests/run.sh`.
