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

if [[ -n "${JUPYTERHUB_API_TOKEN}" ]]; then
    echo "WARNING: using start-singleuser.sh instead of start-notebook.sh to start a server associated with JupyterHub."
    exec /usr/local/bin/start-singleuser.sh "${NOTEBOOK_ARGS}" "$@"
fi

wrapper=""
if [[ "${RESTARTABLE}" == "yes" ]]; then
    wrapper="run-one-constantly"
fi

# Start fortnight tests
# Get value for ENVIRONMENT_CHECKER_SELF_CHECK_ENABLED deployment variable
#SELF_CHECK_ENABLED=$(printenv ENVIRONMENT_CHECKER_SELF_CHECK_ENABLED)

#if [ "$SELF_CHECK_ENABLED" = "true" ]; then
# Awaiting Jupyter lab starting
#sleep 30
#jupyter execute tests/CompositeUnitTestNotebook.ipynb
#fi

# shellcheck disable=SC1091,SC2086
exec /usr/local/bin/start.sh ${wrapper} jupyter ${DOCKER_STACKS_JUPYTER_CMD} ${NOTEBOOK_ARGS} "$@"
