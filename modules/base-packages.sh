#!/bin/sh

# Internal module sourced by setup.sh.

base_packages_run() {
    # Retries absorb transient mirror/QEMU user-net failures (wget exit 4 /
    # "Operation not permitted") without changing the successful apk command set.
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        apk update &&
            apk add \
                gawk \
                grep \
                sed \
                ss \
                coreutils-sort \
                nano &&
            return 0
        sleep $((attempt * 2))
    done
    die 'failed to install base packages'
}
