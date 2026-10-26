# syntax=docker/dockerfile:1
# Pin by tag here; for reproducible builds replace each tag with @sha256:<digest>
# (docker buildx imagetools inspect <image>:<tag>).
ARG ALPINE_VERSION=3.20.3
ARG SYFT_VERSION=v1.14.0
ARG DOCKER_CLI_VERSION=27.3.1

FROM anchore/syft:${SYFT_VERSION} AS syft
FROM docker:${DOCKER_CLI_VERSION}-cli AS dockercli

FROM alpine:${ALPINE_VERSION}

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
