# syntax=docker/dockerfile:1
# Base images are pinned by multi-arch index digest (amd64 + arm64) for reproducible builds.
# To bump: change the tag AND its digest together, e.g.
#   docker buildx imagetools inspect alpine:<new-tag>   (use the top-level "Digest:")
# Keep the tag in front of the digest so the version stays readable.
ARG ALPINE_IMAGE=alpine:3.20.3@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
ARG SYFT_IMAGE=anchore/syft:v1.14.0@sha256:f73604d3dc671f09772684b45f35b6646022f0ace6dff42d18fe4c528c098918
ARG DOCKER_CLI_IMAGE=docker:27.3.1-cli@sha256:328eb399a065780c2cebe9224de003aa14084cf69efae882ac27430f921819b7

FROM ${SYFT_IMAGE} AS syft
FROM ${DOCKER_CLI_IMAGE} AS dockercli

FROM ${ALPINE_IMAGE}

RUN apk add --no-cache bash jq curl ca-certificates tini \
 && adduser -D -u 10001 -h /state sbom \
 && install -d -o sbom -g sbom -m 0700 /state

COPY --from=syft      /syft                     /usr/local/bin/syft
COPY --from=dockercli /usr/local/bin/docker     /usr/local/bin/docker
COPY scripts/ /opt/sbom/
RUN chmod 0755 /opt/sbom/*.sh

ENV HOME=/state/home \
    TMPDIR=/state/tmp \
    XDG_CACHE_HOME=/state/cache \
    SYFT_CHECK_FOR_APP_UPDATE=false \
    SYFT_LOG_LEVEL=warn

USER sbom
WORKDIR /state
VOLUME /state

HEALTHCHECK --interval=60s --timeout=5s --start-period=120s --retries=3 \
  CMD ["/opt/sbom/healthcheck.sh"]

ENTRYPOINT ["/sbin/tini", "--", "/opt/sbom/entrypoint.sh"]
