#!/usr/bin/env bash
set -E -e -o pipefail

# Load the helpers to set up the context.
script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source /opt/homelab/scripts/all

scrutiny_config="/data/scrutiny/config/scrutiny.yaml"

set_umask() {
    # Configure umask to allow write permissions for the group by default
    # in addition to the owner.
    umask 0002
}

run_scrutiny_collector() {
    scrutiny-collector run --config ${scrutiny_config:?}
}

run_scrutiny_collector_loop() {
    local interval="${1:?}"
    while true; do
        local nextEpoch=$(offsetEpoch "+${interval:?}")
        run_scrutiny_collector
        sleepUntil "${nextEpoch:?}"
    done
}

start_scrutiny_collector() {
    logInfo "Starting Scrutiny Collector ..."

    if [ -z "$1" ]; then
        logErr "Interval argument must be specified!"
        logErr "Valid interval values are '10sec', '1min', '1hour', '1day', etc."
        exit 1
    fi
    local interval="${1:?}"

    logInfo "Checking for existing Scrutiny Collector config ..."
    if [ -f "${scrutiny_config:?}" ]; then
        logInfo "Existing Scrutiny Collector configuration \"${scrutiny_config:?}\" found"
    else
        logInfo "Generating Scrutiny Collector configuration at ${scrutiny_config:?}"
        cat << EOF > ${scrutiny_config:?}
version: 1
host:
  id: dummy-host
api:
  endpoint: http://127.0.0.1:8080
EOF
    fi

    run_scrutiny_collector_loop "${interval:?}"
}

start_scrutiny_ui() {
    logInfo "Starting Scrutiny UI ..."

    logInfo "Checking for existing Scrutiny UI config ..."
    if [ -f "${scrutiny_config:?}" ]; then
        logInfo "Existing Scrutiny UI configuration \"${scrutiny_config:?}\" found"
    else
        logInfo "Generating Scrutiny UI configuration at ${scrutiny_config:?}"
        cat << EOF > ${scrutiny_config:?}
version: 1
web:
  listen:
    port: 8080
    host: 0.0.0.0
    basepath: ''
  database:
    location: /data/scrutiny/data/scrutiny.db
  src:
    frontend:
      path: /opt/scrutiny/web
  influxdb:
    scheme: http
    host: 127.0.0.1
    port: 8086
EOF
    fi

    exec scrutiny-web start --config ${scrutiny_config:?}
}

start_scrutiny() {
    if [ -z "$1" ]; then
        logErr "Mode argument must be specified as either 'collector' or 'ui' !"
        exit 1
    fi

    local mode="${1:?}"
    shift
    if [[ "${mode:?}" == "collector" ]]; then
        start_scrutiny_collector "$@"
    elif [[ "${mode:?}" == "ui" ]]; then
        start_scrutiny_ui "$@"
    else
        logErr "Unsupported mode: ${mode:?}"
        exit 1
    fi
}

set_umask
start_scrutiny "$@"
