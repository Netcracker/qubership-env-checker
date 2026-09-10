#!/usr/bin/env python3
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
#
# Modified by NetCracker Technology Corporation, 2024-2025
# Original file from: https://github.com/jupyter/docker-stacks

# PYTHON_MYPY and PYTHON_PYLINT was disabled because linter require to specify an import for the get_config
# function, but in the case of creating a jupyterhub server, this is an auto-generated value
# more info here: https://github.com/jupyterhub/jupyterhub/issues/4850#issuecomment-2283971306
# pylint: skip-file
# mypy: ignore-errors

"""
Jupyter server settings.
"""

import logging
import os
import stat
import subprocess
import sys

from jupyter_core.paths import jupyter_data_dir

# The shared NDJSON formatter ships with the check runner, not with Jupyter.
sys.path.append("/home/jovyan/utils")
import structured_log  # noqa: E402

c = get_config()  # noqa: F821
c.ServerApp.ip = "0.0.0.0"
c.ServerApp.open_browser = False
c.NotebookApp.allow_origin = "*"
c.NotebookApp.allow_remote_access = True
c.NotebookApp.allow_root = True
# c.NotebookApp.ip = 'localhost'
c.NotebookApp.port = 8888
c.NotebookApp.trust_xheaders = True
# The level follows ENVIRONMENT_CHECKER_LOG_LEVEL, which the Helm chart sets.
# It used to be pinned to DEBUG here, which both drowned the log and printed
# request paths and tokens in a production image.
_LOG_LEVEL = structured_log.resolve_level()
c.NotebookApp.log_level = _LOG_LEVEL
c.Application.log_level = _LOG_LEVEL

# Emit NDJSON on stderr: one JSON object per line with time, level and message.
# ENVIRONMENT_CHECKER_LOG_FORMAT=text selects the legacy text format instead.
c.Application.logging_config = structured_log.logging_config(
    "ServerApp", "NotebookApp", "tornado.access", "tornado.application",
    "tornado.general",
)
# traitlets installs its own handler after this file is read, so re-apply the
# formatter over the loggers the dictConfig above already covers.
try:
    structured_log.install_on(
        "ServerApp", "NotebookApp", "tornado.access", "tornado.application",
        "tornado.general",
    )
except Exception:  # never let logging setup stop the server from booting
    logging.exception("Could not install the structured log formatter")
# to output both image/svg+xml and application/pdf plot formats in the notebook file
c.InlineBackend.figure_formats = {"png", "jpeg", "svg", "pdf"}
# https://github.com/jupyter/notebook/issues/3130
c.FileContentsManager.delete_to_trash = False

# Generate a self-signed certificate
OPENSSL_CONFIG = """\
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
"""

if "GEN_CERT" in os.environ:
    dir_name = jupyter_data_dir()
    pem_file = os.path.join(dir_name, "notebook.pem")
    os.makedirs(dir_name, exist_ok=True)

    # Generate an openssl.cnf file to set the distinguished name
    cnf_file = os.path.join(os.getenv("CONDA_DIR", "/usr/lib"), "ssl", "openssl.cnf")
    if not os.path.isfile(cnf_file):
        with open(cnf_file, "w", encoding="utf-8") as fh:
            fh.write(OPENSSL_CONFIG)

    # Generate a certificate if one doesn't exist on disk
    subprocess.check_call(
        [
            "openssl",
            "req",
            "-new",
            "-newkey=rsa:2048",
            "-days=365",
            "-nodes",
            "-x509",
            "-subj=/C=XX/ST=XX/L=XX/O=generated/CN=generated",
            f"-keyout={pem_file}",
            f"-out={pem_file}",
        ]
    )

    # Restrict access to the file
    os.chmod(pem_file, stat.S_IRUSR | stat.S_IWUSR)
    c.ServerApp.certfile = pem_file

# Change default umask for all subprocesses of the notebook server if set in
# the environment
if "NB_UMASK" in os.environ:
    os.umask(int(os.environ["NB_UMASK"], 8))
