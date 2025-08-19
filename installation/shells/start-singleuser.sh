#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
#
# Modified by NetCracker Technology Corporation, 2024-2025
# Original file from: https://github.com/jupyter/docker-stacks

set -e

NOTEBOOK_ARGS=$1
# set default ip to 0.0.0.0
if [[ "${NOTEBOOK_ARGS} $*" != *"--ip="* ]]; then
    NOTEBOOK_ARGS="--ip=0.0.0.0 ${NOTEBOOK_ARGS}"
fi

# shellcheck disable=SC1091,SC2086
. /usr/local/bin/start.sh jupyterhub-singleuser "${NOTEBOOK_ARGS}" "$@"
