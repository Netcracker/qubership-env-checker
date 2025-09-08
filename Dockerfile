FROM debian:trixie-slim

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Install all OS dependencies for notebook server that starts but lacks all features (e.g., download as all possible file formats)
RUN apt-get update --yes && \
    apt-get install --yes --no-install-recommends \
    bzip2 \
    locales \
    tini \
    wget \
    ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

# Copy a script that we will use to correct permissions after running certain commands
COPY installation/shells/fix-permissions.sh /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER, ignore=SC2016
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc && \
    # Add call to conda init script see https://stackoverflow.com/a/58081608/4413446
    echo "eval \"\$(command conda shell.bash hook 2> /dev/null)\"" >> /etc/skel/.bashrc

# Create NB_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    useradd -l -m -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" && \
    mkdir -p "${CONDA_DIR}" && \
    chown "${NB_USER}:${NB_GID}" "${CONDA_DIR}" && \
    chmod g+w /etc/passwd && \
    fix-permissions "${HOME}" && \
    fix-permissions "${CONDA_DIR}"

# Pin python version here, or set it to "default"
ARG PYTHON_VERSION=3.10

# Setup work directory for backward-compatibility
RUN mkdir "/home/${NB_USER}/work" && fix-permissions "/home/${NB_USER}"

# Download and install Micromamba, and initialize Conda prefix.
#   <https://github.com/mamba-org/mamba#micromamba>
#   Similar projects using Micromamba:
#     - Micromamba-Docker: <https://github.com/mamba-org/micromamba-docker>
#     - repo2docker: <https://github.com/jupyterhub/repo2docker>
# Install Python, Mamba and jupyter_core
# Cleanup temporary files and remove Micromamba
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
COPY --chown="${NB_UID}:${NB_GID}" installation/initial-condarc.yaml "${CONDA_DIR}/.condarc"
COPY --chown="${NB_UID}:${NB_GID}" installation/initial-condarc.yaml "/home/${NB_USER}/.condarc"
WORKDIR /tmp

RUN set -x && \
    # Check architecture
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
        arch="64"; \
    fi && \
    echo "Architecture: ${arch}" && \
    # Download micromamba.tar.bz2
    if ! wget -qO /tmp/micromamba.tar.bz2 https://github.com/mamba-org/micromamba-releases/releases/download/2.0.4-0/micromamba-linux-64.tar.bz2; then \
        echo "Failed to download micromamba.tar.bz2"; \
        exit 1; \
    fi && \
    echo "Downloaded micromamba.tar.bz2 successfully" && \
    # Extract micromamba.tar.bz2
    if ! tar -xvjf /tmp/micromamba.tar.bz2 --strip-components=1 -C /tmp bin/micromamba; then \
        echo "Failed to extract micromamba.tar.bz2"; \
        exit 1; \
    fi && \
    echo "Extracted micromamba.tar.bz2 successfully" && \
    rm /tmp/micromamba.tar.bz2 && \
    # Set PYTHON_SPECIFIER
    PYTHON_SPECIFIER="python=${PYTHON_VERSION}" && \
    if [[ "${PYTHON_VERSION}" == "default" ]]; then \
        PYTHON_SPECIFIER="python"; \
    fi && \
    echo "PYTHON_SPECIFIER: ${PYTHON_SPECIFIER}" && \
    # Install packages with micromamba
    if ! /tmp/micromamba install \
        --root-prefix="${CONDA_DIR}" \
        --prefix="${CONDA_DIR}" \
        --yes \
        "${PYTHON_SPECIFIER}" \
        'mamba' \
        'conda<23.9' \
        'jupyter_core'; then \
        echo "Failed to install packages with micromamba"; \
        exit 1; \
    fi && \
    echo "Installed packages successfully" && \
    # Cleanup
    rm /tmp/micromamba && \
    # Debugging: Check if mamba list python works
    if ! mamba list python > /tmp/mamba_list_python.txt; then \
        echo "Failed to list python packages with mamba"; \
        exit 1; \
    fi && \
    echo "Listed python packages successfully" && \
    # Debugging: Print content of mamba_list_python.txt
    echo "Content of /tmp/mamba_list_python.txt:" && \
    cat /tmp/mamba_list_python.txt && \
    # Debugging: Use awk to extract the python package line
    if ! awk '/^python[[:space:]]/ {print $1, $2}' /tmp/mamba_list_python.txt > /tmp/awk_python.txt; then \
        echo "Failed to extract python packages with awk"; \
        exit 1; \
    fi && \
    echo "Extracted python packages successfully" && \
    # Write to pinned file
    if ! cat /tmp/awk_python.txt >> "${CONDA_DIR}/conda-meta/pinned"; then \
        echo "Failed to write to ${CONDA_DIR}/conda-meta/pinned"; \
        exit 1; \
    fi && \
    echo "Wrote Python version to ${CONDA_DIR}/conda-meta/pinned successfully" && \
    if ! mamba clean --all -f -y; then \
        echo "Failed to clean mamba"; \
        exit 1; \
    fi && \
    if ! fix-permissions "${CONDA_DIR}"; then \
        echo "Failed to fix permissions for ${CONDA_DIR}"; \
        exit 1; \
    fi && \
    echo "Fixed permissions for ${CONDA_DIR} successfully" && \
    if ! fix-permissions "/home/${NB_USER}"; then \
        echo "Failed to fix permissions for /home/${NB_USER}"; \
        exit 1; \
    fi && \
    echo "Fixed permissions for /home/${NB_USER} successfully"

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
WORKDIR "${HOME}"
#todo duplicate is it need?
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Download run-one file and upload to /tmp
# Unpack the file to /opt
# delete temp files
# install opentelemetry exporter
RUN wget --progress=dot:giga -O /tmp/run-one_1.17.orig.tar.gz http://security.ubuntu.com/ubuntu/pool/main/r/run-one/run-one_1.17.orig.tar.gz && \
    tar --directory=/opt -xvf /tmp/run-one_1.17.orig.tar.gz && \
    rm /tmp/run-one_1.17.orig.tar.gz

RUN pip install --no-cache-dir \
    opentelemetry-exporter-prometheus-remote-write \
    redis

# Install all OS dependencies for fully functional notebook server
RUN apt-get -o Acquire::Check-Valid-Until=false update --yes && \
    apt-get install --yes --no-install-recommends \
        fonts-liberation \
        # - pandoc is used to convert notebooks to html files
        #   it's not present in arch64 ubuntu image, so we install it here
        pandoc \
        # Common useful utilities
        curl \
        iputils-ping \
        traceroute \
        git \
        nano-tiny \
        tzdata \
        unzip \
        vim-tiny \
        # git-over-ssh
        openssh-client \
        # less is needed to run help in R
        # see: https://github.com/jupyter/docker-stacks/issues/1588
        less \
        # nbconvert dependencies
        # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
        texlive-xetex \
        texlive-fonts-recommended \
        texlive-plain-generic \
        # Enable clipboard on Linux host systems
        xclip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Jupyter Notebook, Lab, and Hub
# Generate a notebook server config
# Cleanup temporary files
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
WORKDIR /tmp
RUN mamba install --yes \
        'traitlets<5.10' \
        'notebook' \
        'jupyterlab-lsp=5.2.0' \
        'jupyter-lsp=2.2.6' \
        'jupyterhub=5.3.0' \
        'jupyterlab=4.4.5' \
    && \
    jupyter notebook --generate-config && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

ENV JUPYTER_PORT=8888
EXPOSE $JUPYTER_PORT

# Copy local files as late as possible to avoid cache busting
COPY installation/shells/start-notebook.sh installation/shells/start-singleuser.sh /usr/local/bin/
# Copy local files as late as possible to avoid cache busting
COPY installation/shells/start.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY installation/python/jupyter_server_config.py installation/python/docker_healthcheck.py /etc/jupyter/

RUN chmod +x /usr/local/bin/start-notebook.sh && \
    chmod +x /usr/local/bin/start.sh

# debug: print jupyter lab version
RUN jupyter lab --version

# Configure container startup
CMD ["/usr/local/bin/start-notebook.sh"]

# Legacy for Jupyter Notebook Server, see: [#1205](https://github.com/jupyter/docker-stacks/issues/1205)
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py && \
    fix-permissions /etc/jupyter/

# HEALTHCHECK documentation: https://docs.docker.com/engine/reference/builder/#healthcheck
# This healthcheck works well for `lab`, `notebook`, `nbclassic`, `server`, and `retro` Jupyter commands
# https://github.com/jupyter/docker-stacks/issues/915#issuecomment-1068528799
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD /etc/jupyter/docker_healthcheck.py || exit 1

WORKDIR "${HOME}"

# Disabling notifications in the UI at startup
#RUN mkdir -p /usr/local/etc/jupyter && \
#    chown -R "${NB_USER}:${NB_GID}" /usr/local/etc/jupyter && \
#    jupyter labextension disable --level=system "@jupyterlab/apputils-extension:announcements"

# Download and install kubectl
RUN KUBECTL_VERSION="$(curl -Ls https://dl.k8s.io/release/latest.txt)"; \
    wget --progress=dot:giga -O /usr/local/bin/kubectl-${KUBECTL_VERSION} https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl-${KUBECTL_VERSION} && \
    ln -sf /usr/local/bin/kubectl-${KUBECTL_VERSION} /usr/local/bin/kubectl

# Download and install yq
RUN wget --progress=dot:giga https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64.tar.gz && \
    tar -xzvf yq_linux_amd64.tar.gz -C /usr/bin/ && \
    mv /usr/bin/yq_linux_amd64 /usr/bin/yq && \
    chmod +x /usr/bin/yq && \
    rm yq_linux_amd64.tar.gz

# update apt and install go. Uncomment if someday will need to write notebooks on golang
# apt command is not recommended for installation from Dockerfile
#RUN apt -o Acquire::Check-Valid-Until=false update
#RUN apt install golang -y

# Install additional packages
RUN mamba install --yes \
    'aiohttp>=3.9.2' \
    'aiosmtplib' \
    'altair' \
    'beautifulsoup4' \
    'blas' \
    'bokeh' \
    'boto3' \
    'bottleneck' \
    'cassandra-driver' \
    'clickhouse-driver' \
    'cloudpickle' \
    'cython' \
    'dask' \
    'dill' \
    'fonttools>=4.43.0' \
    'h5py' \
    'ipympl' \
    'ipywidgets' \
    'jupyter_server>=2.0.0' \
    'kafka-python' \
    'matplotlib-base' \
    'numba' \
    'numexpr' \
    'opentelemetry-api' \
    'opentelemetry-sdk' \
    'opentelemetry-semantic-conventions' \
    'openpyxl' \
    'pandas' \
    'papermill' \
    'patsy' \
    'pika' \
    'pillow>=10.2.0' \
    'prettytable' \
    'psycopg2' \
    'pyarrow>=14.0.1' \
    'pymongo' \
    'pypdf2' \
    'pytables' \
    'python-kubernetes' \
    'python-snappy' \
    'scikit-image' \
    'scikit-learn' \
    'scipy' \
    'scrapbook' \
    'seaborn' \
    'sqlalchemy' \
    'statsmodels' \
    'sympy' \
    'urllib3>=2.0.6' \
    'widgetsnbextension' \
    'xlrd' \
    'xlsxwriter' \
    'yaml' && \
    mamba clean --all -f -y && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}/"

RUN echo "export PATH=/opt/conda/bin:\$PATH" >> /home/jovyan/.bashrc
RUN chgrp -Rf root /home/$NB_USER && chmod -Rf g+w /home/$NB_USER

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}

# Add R mimetype option to specify how the plot returns from R to the browser
COPY --chown=${NB_UID}:${NB_GID} installation/Rprofile.site /opt/conda/lib/R/etc/

# Disable notifications for JupyterLab update notifications
RUN jupyter labextension disable "@jupyterlab/apputils-extension:announcements"
