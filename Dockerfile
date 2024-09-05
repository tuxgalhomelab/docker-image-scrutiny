# syntax=docker/dockerfile:1

ARG BASE_IMAGE_NAME
ARG BASE_IMAGE_TAG
ARG GO_IMAGE_NAME
ARG GO_IMAGE_TAG
FROM ${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG} AS with-scripts

COPY scripts/start-scrutiny.sh /scripts/

FROM ${GO_IMAGE_NAME}:${GO_IMAGE_TAG} AS builder-base

COPY patches /patches

ARG SCRUTINY_VERSION

# hadolint ignore=DL4006,SC3044
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && homelab install build-essential git \
    # Download scrutiny repo. \
    && homelab download-git-repo \
        https://github.com/AnalogJ/scrutiny/ \
        ${SCRUTINY_VERSION:?} \
        /root/scrutiny-build \
    && pushd /root/scrutiny-build \
    # Apply the patches. \
    && (find /patches -iname *.diff -print0 | sort -z | xargs -0 -r -n 1 patch -p2 -i) \
    && popd

FROM builder-base AS builder-backend-base

# hadolint ignore=SC3044
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && pushd /root/scrutiny-build \
    # Set up the build and dependencies. \
    && STATIC=1 GOOS=linux make binary-clean binary-dep \
    && popd

FROM builder-base AS builder-ui-frontend

ARG NVM_VERSION
ARG NVM_SHA256_CHECKSUM
ARG IMAGE_NODEJS_VERSION

# hadolint ignore=SC3044
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && homelab install-node \
        ${NVM_VERSION:?} \
        ${NVM_SHA256_CHECKSUM:?} \
        ${IMAGE_NODEJS_VERSION:?} \
    && source /opt/nvm/nvm.sh \
    && pushd /root/scrutiny-build \
    && make binary-frontend \
    && popd \
    # Copy the build artifacts. \
    && mkdir -p /output \
    && cp -rf /root/scrutiny-build/dist /output/

FROM builder-backend-base AS builder-ui-backend

# hadolint ignore=SC3044
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && pushd /root/scrutiny-build \
    # Build scrutiny collector. \
    && STATIC=1 GOOS=linux make binary-web \
    && popd \
    # Copy the build artifacts. \
    && mkdir -p /output/bin \
    && cp /root/scrutiny-build/scrutiny-web-linux /output/bin/scrutiny-web

FROM builder-backend-base AS builder-collector

# hadolint ignore=SC3044
RUN \
    set -E -e -o pipefail \
    && export HOMELAB_VERBOSE=y \
    && pushd /root/scrutiny-build \
    # Build scrutiny collector. \
    && STATIC=1 GOOS=linux make binary-collector \
    && popd \
    # Copy the build artifacts. \
    && mkdir -p /output/bin \
    && cp /root/scrutiny-build/scrutiny-collector-metrics-linux /output/bin/scrutiny-collector

FROM ${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}

ARG USER_NAME
ARG GROUP_NAME
ARG USER_ID
ARG GROUP_ID
ARG PACKAGES_TO_INSTALL
ARG SCRUTINY_VERSION

# hadolint ignore=DL4006,SC2086,SC3009
RUN \
    --mount=type=bind,target=/collector-build,from=builder-collector,source=/output \
    --mount=type=bind,target=/ui-frontend-build,from=builder-ui-frontend,source=/output \
    --mount=type=bind,target=/ui-backend-build,from=builder-ui-backend,source=/output \
    --mount=type=bind,target=/scripts,from=with-scripts,source=/scripts \
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
    && cp -rf /ui-frontend-build/dist /opt/scrutiny-${SCRUTINY_VERSION:?}/web \
    && cp /ui-backend-build/bin/scrutiny-web /opt/scrutiny-${SCRUTINY_VERSION:?}/bin \
    && cp /collector-build/bin/scrutiny-collector /opt/scrutiny-${SCRUTINY_VERSION:?}/bin \
    && ln -sf /opt/scrutiny-${SCRUTINY_VERSION:?} /opt/scrutiny \
    && ln -sf /opt/scrutiny/bin/scrutiny-web /opt/bin/scrutiny-web \
    && ln -sf /opt/scrutiny/bin/scrutiny-collector /opt/bin/scrutiny-collector \
    # Copy the start-scrutiny.sh script. \
    && cp /scripts/start-scrutiny.sh /opt/scrutiny/ \
    && ln -sf /opt/scrutiny/start-scrutiny.sh /opt/bin/start-scrutiny \
    # Set up the permissions. \
    && chown -R ${USER_NAME:?}:${GROUP_NAME:?} /opt/scrutiny-${SCRUTINY_VERSION:?} /opt/scrutiny /opt/bin/scrutiny-collector /data/scrutiny \
    # Clean up. \
    && homelab cleanup

# Expose the HTTP/HTTPS server port used by Scrutiny web UI.
EXPOSE 8080

ENV USER=${USER_NAME}
USER ${USER_NAME}:${GROUP_NAME}
WORKDIR /home/${USER_NAME}

CMD ["start-scrutiny"]
STOPSIGNAL SIGTERM
