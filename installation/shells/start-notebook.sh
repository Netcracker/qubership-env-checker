#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
#
# Modified by NetCracker Technology Corporation, 2024-2025
# Original file from: https://github.com/jupyter/docker-stacks

set -e

# The Jupyter command to launch JupyterLab by default
DOCKER_STACKS_JUPYTER_CMD="${DOCKER_STACKS_JUPYTER_CMD:=lab}"

# initialize params for Jupyter Server start: set UI access token
NOTEBOOK_ARGS="--ServerApp.token=$(printenv ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN)"

# shellcheck disable=SC1091,SC2086
exec /usr/local/bin/start.sh jupyter ${DOCKER_STACKS_JUPYTER_CMD} ${NOTEBOOK_ARGS} "$@"
