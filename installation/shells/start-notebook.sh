#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
#
# Modified by NetCracker Technology Corporation, 2024-2025
# Original file from: https://github.com/jupyter/docker-stacks

set -e

# The Jupyter command to launch JupyterLab by default
DOCKER_STACKS_JUPYTER_CMD="${DOCKER_STACKS_JUPYTER_CMD:=lab}"

# Set the UI access token through the environment instead of the command line:
# start.sh logs its own arguments, which would print the token at every start.
JUPYTER_TOKEN="$(printenv ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN)"
export JUPYTER_TOKEN

# shellcheck disable=SC1091,SC2086
exec /usr/local/bin/start.sh jupyter ${DOCKER_STACKS_JUPYTER_CMD} "$@"
