ARG BUILDPLATFORM
FROM --platform=$BUILDPLATFORM debian:trixie-slim@sha256:4bcb9db66237237d03b55b969271728dd3d955eaaa254b9db8a3db94550b1885

ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Install all OS dependencies for notebook server (basic minimum) that starts but lacks all features
# (e.g., download as all possible file formats). Include next dependencies:
#   bzip2 - archiver/decompressor for .bz2 format. Needed to unpack micromamba .tar.bz2 during image build
#   locales - localization packages to generate UTF-8 locale
#   tini - minimal init process that handles signals and zombie processes correctly. Used as container ENTRYPOINT
#   wget - HTTP/HTTPS file downloader. Required to fetch micromamba, run-one, kubectl, yq. Can be replaced with curl
#   ca-certificates - root certificates for TLS, needed by all HTTP/HTTPS requests
#   locale-gen - configure and generate locale
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
        MAMBA_ARCH="linux-64"; \
    elif [ "${arch}" = "aarch64" ]; then \
        MAMBA_ARCH="linux-aarch64"; \
    else \
        echo "Unsupported architecture: ${arch}"; exit 1; \
    fi && \
    # Download micromamba.tar.bz2
    if ! wget -qO /tmp/micromamba.tar.bz2 https://github.com/mamba-org/micromamba-releases/releases/download/2.0.4-0/micromamba-${MAMBA_ARCH}.tar.bz2; then \
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
    if ! awk '/^[[:space:]]*python[[:space:]]/ {print $1, $2}' /tmp/mamba_list_python.txt > /tmp/awk_python.txt; then \
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

# install opentelemetry exporter
RUN pip install --no-cache-dir \
    opentelemetry-exporter-prometheus-remote-write \
    redis

# Install all OS dependencies for fully functional notebook server:
#   fonts-liberation - used by nbconvert (PDF/HTML export)
#   pandoc - document converter for notebooks, used for HTML/Markdown/partial PDF
#   curl - used to obtain kubectl version and in Jupyter UI terminal
#   iputils-ping - network diagnostics for network/Service/Pod (ping)
#   traceroute - show route (nodes/gateways/overlay) from the Pod to the target and where packets are lost
#   git - VCS client, needed for GIT integration (pull notebooks)
#   tzdata - time zones
#   unzip - unpack .zip
#   texlive-xetex, texlive-fonts-recommended, texlive-plain-generic - required to build PDFs from nbconvert
RUN apt-get -o Acquire::Check-Valid-Until=false update --yes && \
    apt-get install --yes --no-install-recommends \
        fonts-liberation \
        pandoc \
        curl \
        iputils-ping \
        traceroute \
        git \
        tzdata \
        unzip \
        texlive-xetex \
        texlive-fonts-recommended \
        texlive-plain-generic && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Dependencies by mamba:
#   traitlets - required by jupyterlab. Without the library, the JupyterLab/Notebook/Server configuration
#   will be broken. Using a version less than 5.10 to avoid conflicts with jupyter packages.
#   notebook - required by jupyterlab (UI start)
#   jupyterlab-lsp – jupyterLab frontend extension (UI: error highlighting, autocompletion, go to definition, etc.).
#   jupyter-lsp – jupyter server extension for proxying Language Server Protocol.
#   jupyterlab - required for UI start
# Generate a notebook server config
# Cleanup temporary files
WORKDIR /tmp
RUN mamba install --yes \
        'traitlets<5.10' \
        'notebook' \
        'jupyterlab-lsp=5.2.0' \
        'jupyter-lsp=2.2.6' \
        #'jupyterhub=5.3.0' \
        'jupyterlab=4.4.5' \
        'nodejs=24.8.0' \
    && \
    jupyter notebook --generate-config && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "${CONDA_DIR}"

ENV JUPYTER_PORT=8888
EXPOSE $JUPYTER_PORT

# Copy local files as late as possible to avoid cache busting
COPY --chmod=0755 installation/shells/start.sh installation/shells/start-notebook.sh /usr/local/bin/
# Currently need to have jupyter_server_config to support jupyterlab
COPY installation/python/jupyter_server_config.py /etc/jupyter/
# Copy user's working files (relative path from context)
COPY --chown="${NB_UID}:${NB_GID}" jovyan/ "/home/${NB_USER}/"
# Use the script for set permissions on a directory
RUN fix-permissions "/home/${NB_USER}"

# Configure container startup
CMD ["/usr/local/bin/start-notebook.sh"]

# Legacy for Jupyter Notebook Server, see: [#1205](https://github.com/jupyter/docker-stacks/issues/1205)
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py && \
    fix-permissions /etc/jupyter/

WORKDIR "${HOME}"

# Autodiscovery the latest version of kubectl, downloads and install it
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
        KUBE_ARCH="amd64"; \
    elif [ "${arch}" = "aarch64" ]; then \
        KUBE_ARCH="arm64"; \
    else \
        echo "Unsupported architecture: ${arch}"; exit 1; \
    fi && \
    KUBECTL_VERSION="$(curl -Ls https://dl.k8s.io/release/latest.txt)"; \
    wget --progress=dot:giga -O /usr/local/bin/kubectl-${KUBECTL_VERSION} https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/${KUBE_ARCH}/kubectl && \
    chmod +x /usr/local/bin/kubectl-${KUBECTL_VERSION} && \
    ln -sf /usr/local/bin/kubectl-${KUBECTL_VERSION} /usr/local/bin/kubectl

# Download and install yq
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
        YQ_ARCH="amd64"; \
    elif [ "${arch}" = "aarch64" ]; then \
        YQ_ARCH="arm64"; \
    else \
        echo "Unsupported architecture: ${arch}"; exit 1; \
    fi && \
    wget --progress=dot:giga https://github.com/mikefarah/yq/releases/download/v4.47.2/yq_linux_${YQ_ARCH}.tar.gz && \
    tar -xzvf yq_linux_${YQ_ARCH}.tar.gz -C /usr/bin/ && \
    mv /usr/bin/yq_linux_${YQ_ARCH} /usr/bin/yq && \
    chmod +x /usr/bin/yq && \
    rm yq_linux_${YQ_ARCH}.tar.gz

# update apt and install go. Uncomment if someday will need to write notebooks on golang
# apt command is not recommended for installation from Dockerfile
#RUN apt -o Acquire::Check-Valid-Until=false update
#RUN apt install golang -y

# Install additional packages:
#   aiohttp - async HTTP library
#   beautifulsoup4 (bs4) -  HTML/XML parsing
#   boto3 - AWS SDK for Python
#   bottleneck - accelerator for numeric arrays with missing values (NaN). Can used automatically by pandas
#   jupyter_server - backend mandatory to start jupyterlab. Serves the kernel, file system, terminals, REST API and extensions
#   opentelemetry-api/opentelemetry-sdk/opentelemetry-semantic-conventions - telemetry API/SDK, resources, and metrics
#   pandas - data storage and processing (tabular analysis)
#   papermill - parameterization and programmatic launch of Jupyter notebooks
#   python-kubernetes: Python client library for the Kubernetes API
#   scrapbook - saving notebook artifacts and metadata
#   urllib3 - low-level HTTP client
#   widgetsnbextension: Jupyter Notebook extension that enables interactive widgets in notebook cells (sliders, buttons, text boxes).
RUN mamba install --yes \
    'aiohttp>=3.9.2' \
    'beautifulsoup4' \
    'boto3' \
    'bottleneck' \
    'jupyter_server>=2.0.0' \
    'jupyterlab-git' \
    'opentelemetry-api' \
    'opentelemetry-sdk' \
    'opentelemetry-semantic-conventions' \
    'pandas' \
    'papermill' \
    'python-kubernetes' \
    'python-lsp-server' \
    'scrapbook' \
    'urllib3>=2.0.6' \
    'widgetsnbextension' \
    # 'aiosmtplib' \ - async SMTP email sending
    # 'altair' \     - interactive data visualization in JupyterLab. Describe a chart → compiled to Vega‑Lite → Jupyter frontend renders it interactively
    # 'blas' \       - low-level linear algebra routines (vectors, matrices, solving systems). Pulled in transitively by NumPy/SciPy/scikit‑learn/statsmodels
    # 'bokeh' \      - interactive web visualizations (plots/UI widgets) in browser/Jupyter
    # 'dask' \       - framework for parallel and distributed computing. Can help with parsing heavy files
    # 'ipympl' \     - renders Matplotlib as a widget; enables interactive editing and toolbar in notebooks
    # 'ipywidgets' \ - a set of interactive widgets for Jupyter (sliders, selects, checkboxes, buttons, etc.)
    # 'matplotlib-base' \ - plotting library (lines, points, bars, histograms, heatmaps) with full styling control (axes, legends, annotations, styles) and export to PNG/SVG/PDF.
    # 'openpyxl' \ - read/write Excel XLSX files; create sheets, write cells, styles, formulas, charts, images, data validation.
    # 'pillow>=10.2.0' \ - standard image processing/manipulation library for Python (PNG/JPEG/WebP/TIFF…)
    # 'prettytable' \ - printing neat signs in terminal/log
    # 'pyarrow>=14.0.1' \ - columnar in‑memory tables, fast storage formats (Parquet, Feather), I/O and memory efficiency; interoperates with pandas/NumPy
    # 'pypdf2' \ - PDF manipulation — read/merge/split, rotate/crop/number, encrypt/decrypt, watermarks. Does not render or redraw pages
    # 'pytables' \ - high‑level HDF5 wrapper for tabular/hierarchical data. Use for large on‑disk tables with fast filters/indexes and row‑wise appends
    # 'sqlalchemy' \ - RDBMS access library (PostgreSQL, MySQL, SQLite); provides SQL execution tools and an ORM for working with databases.
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
