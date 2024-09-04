# syntax=docker/dockerfile:1

ARG BASE_IMAGE_NAME
ARG BASE_IMAGE_TAG

ARG GO_IMAGE_NAME
ARG GO_IMAGE_TAG
FROM ${GO_IMAGE_NAME}:${GO_IMAGE_TAG} AS builder

ARG NVM_VERSION
ARG NVM_SHA256_CHECKSUM
ARG IMAGE_NODEJS_VERSION
ARG SCRUTINY_VERSION

COPY scripts/start-scrutiny.sh /scripts/
COPY patches /patches

# hadolint ignore=DL4006,SC3009,SC3040
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && homelab install build-essential git \
    && homelab install-node \
        ${NVM_VERSION:?} \
        ${NVM_SHA256_CHECKSUM:?} \
        ${IMAGE_NODEJS_VERSION:?} \
    # Download scrutiny repo. \
    && homelab download-git-repo \
        https://github.com/AnalogJ/scrutiny/ \
        ${SCRUTINY_VERSION:?} \
        /root/scrutiny-build \
    && pushd /root/scrutiny-build \
    # Apply the patches. \
    && (find /patches -iname *.diff -print0 | sort -z | xargs -0 -r -n 1 patch -p2 -i) \
    && source /opt/nvm/nvm.sh \
    # Build scrutiny. \
    && STATIC=1 GOOS=linux make binary-clean binary-collector \
    && popd \
    # Copy the build artifacts. \
    && mkdir -p /output/{bin,scripts} \
    && cp /root/scrutiny-build/scrutiny-collector-metrics-linux /output/bin/scrutiny-collector-metrics \
    && cp /scripts/* /output/scripts

FROM ${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}

ARG USER_NAME
ARG GROUP_NAME
ARG USER_ID
ARG GROUP_ID
ARG PACKAGES_TO_INSTALL
ARG SCRUTINY_VERSION

# hadolint ignore=DL4006,SC2086,SC3009
RUN --mount=type=bind,target=/scrutiny-build,from=builder,source=/output \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    # Create the user and the group. \
    && homelab add-user \
        ${USER_NAME:?} \
        ${USER_ID:?} \
        ${GROUP_NAME:?} \
        ${GROUP_ID:?} \
        --create-home-dir \
    # Install dependencies. \
    && homelab install $PACKAGES_TO_INSTALL \
    && mkdir -p /opt/scrutiny-${SCRUTINY_VERSION:?}/bin /data/scrutiny/{config,data} \
    && cp /scrutiny-build/bin/scrutiny-collector-metrics /opt/scrutiny-${SCRUTINY_VERSION:?}/bin \
    && ln -sf /opt/scrutiny-${SCRUTINY_VERSION:?} /opt/scrutiny \
    && ln -sf /opt/scrutiny/bin/scrutiny-collector-metrics /opt/bin/scrutiny-collector-metrics \
    # Copy the start-scrutiny.sh script. \
    && cp /scrutiny-build/scripts/start-scrutiny.sh /opt/scrutiny/ \
    && ln -sf /opt/scrutiny/start-scrutiny.sh /opt/bin/start-scrutiny \
    # Set up the permissions. \
    && chown -R ${USER_NAME:?}:${GROUP_NAME:?} /opt/scrutiny-${SCRUTINY_VERSION:?} /opt/scrutiny /opt/bin/scrutiny-collector-metrics /data/scrutiny \
    # Clean up. \
    && homelab cleanup

# Expose the HTTP server port used by Prometheus.
EXPOSE 9093

# Use the healthcheck command part of scrutiny as the health checker.
HEALTHCHECK \
    --start-period=15s --interval=30s --timeout=3s \
    CMD homelab healthcheck-service http://localhost:9093/-/healthy

ENV USER=${USER_NAME}
USER ${USER_NAME}:${GROUP_NAME}
WORKDIR /home/${USER_NAME}

CMD ["start-scrutiny"]
STOPSIGNAL SIGTERM
