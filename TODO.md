# TODO

## Open

- [ ] **Coolify one-click service template.** Coolify service templates are compose files with metadata header comments
      (documentation, slogan, tags, logo) in the Coolify repo under `templates/compose/`, contributed via PR. Check the
      current contribution guide first (format may have changed); there is no separate documentation step, the `documentation:`
      header just links to this README. Needs: a prebuilt image (ghcr.io), since templates can't build from source.
- [ ] **Publish the image to ghcr.io** with a GitHub Action (prerequisite for the template; also removes the on-server build).
- [ ] **Verify first Coolify deploy on a real host:** socket proxy ACL with Syft image export (maybe `INFO=1`), non-root +
      read-only rootfs, scoped DT API key permissions.
- [ ] **Dependency-Track vulnerability sources:** confirm OSV + GitHub Advisories have mirrored, then re-analyse and check
      findings. Optionally script the extension config (`PUT /extension-points/vuln-data-source/extensions/{osv,github}/config`)
      once the request bodies are captured from the UI.
- [ ] **CPE filter:** strip `.cpe` only for language-ecosystem PURLs (golang, npm, pypi, maven, ...), keep it on apk/deb/rpm,
      if OS packages show no findings with PURL-only matching.
- [ ] **Skip ephemeral build images** (`docker-image-<uuid>/...` projects) via a name pattern.
- [ ] Investigate "metadata.component not in dependency graph" warning (probably from `--source-name`).
- [ ] Optional: `docker events` trigger for faster scans after deployments.
- [ ] Pin Syft / Docker CLI / Alpine / socket-proxy by digest.
