#!/bin/sh

# Internal module sourced by setup.sh.

base_packages_run() {
    apk update
    apk add \
        gawk \
        grep \
        sed \
        coreutils-sort \
        nano
}
