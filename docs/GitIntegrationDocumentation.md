# Git Integration Documentation

## Overview

The Git integration system provides multiple ways to fetch and execute files from Git repositories within the Jupyter
environment. This system is designed to support automated testing, continuous integration, and flexible notebook
execution workflows.

## Integration Methods

### 1. Jupyter UI Integration

The primary integration method uses the Jupyter UI with built-in buttons and interface elements that allow users to:
- Configure Git repository settings through the UI
- Fetch repositories with a single click
- Execute fetched notebooks directly from the interface
- Manage authentication credentials through environment variables

**Usage**: Access through the Jupyter notebook interface using the provided UI components.

### 2. Programmatic Integration

This interaction method allows you to pull a repository (a folder or an individual notebook/.yaml file), as well as to
perform an instant single or bulk execution of the downloaded files.

## Git Integration Methods

### Method 1: New Method (Recommended) - Environment Variables

**Status**: ✅ **Recommended** - This is the current preferred method.

This method uses environment variables for configuration and provides better flexibility and security.

#### Through `run.sh` Orchestrator
```bash
bash run.sh --git /path/to/notebook.ipynb
```

**How it works:**
1. Set required environment variables (`GIT_REPOSITORY_URL`, `GIT_TARGET_PATH`, etc.)
2. Use `--git` flag (without value) in `run.sh`
3. The system fetches the repository using `utils/integration/git_helper.py`
4. Files are downloaded to `<GIT_TARGET_PATH>/<GIT_SUBFOLDER>/...`
5. The specified notebook is executed after fetching

**Advantages:**
- More secure (credentials via environment variables)
- Better integration with Kubernetes/Helm deployments
- Supports sparse checkout for efficient fetching
- More flexible configuration

**Example:**
```bash
export GIT_REPOSITORY_URL="https://github.com/owner/repo.git"
export GIT_TARGET_PATH="/home/jovyan/target"
export GIT_SPARSE_PATH="notebooks/"
export GIT_BRANCH="main"
export GIT_USERNAME="user"
export GIT_TOKEN="token"

bash run.sh --git notebooks/test.ipynb
```

### Method 2: Legacy Method (Deprecated)

**Status**: ⚠️ **DEPRECATED** - Maintained for backward compatibility only. Use Method 1 for new implementations.

This method uses the `--git=URL` format and is maintained for systems that already use this approach.

#### Legacy Method: Through `run.sh` Orchestrator
```bash
bash run.sh --git=https://git.example.com/prod.cse.ssm/env-checker-notebooks.git notebooks/GraylogClusterChecks.ipynb
```

**How it works:**
1. Pass Git repository URL directly in the `--git=URL` flag
2. The system uses `shells/git_helper.sh` (deprecated script)
3. Repository is cloned/pulled to `/home/jovyan/<repo-name>/`
4. File paths are automatically adjusted with `relative_path` prefix
5. The specified notebook is executed

**Limitations:**
- Not available in PRODUCTION_MODE=true
- Less flexible than the new method
- Requires credentials via environment variables (`ENVCHECKER_GIT_USERNAME`, `ENVCHECKER_GIT_TOKEN`) or files (`/etc/git/git-user`, `/etc/git/git-token`)
- Always clones entire repository (no sparse checkout)
- Domain configuration: Uses `ENVCHECKER_GIT_DOMAIN` if set, otherwise extracts from URL. **Domain is required** - error will be shown if not specified.

**Example:**
```bash
bash run.sh --git=https://git.example.com/prod.cse.ssm/env-checker-notebooks.git notebooks/GraylogClusterChecks.ipynb
```

**Migration Guide:**
To migrate from the deprecated method to the new method:
1. Set environment variables instead of using `--git=URL`
2. Replace `--git=URL` with `--git` flag
3. Update file paths if needed (new method doesn't add `relative_path` prefix automatically)

#### Direct Python Method Calls
```python
from git_helper import run_fetch

# Fetch repository and files
success = run_fetch(
    repo_url="https://github.com/owner/repo.git",
    target_path="/home/jovyan/target",
    sparse_path="path/to/file.ipynb",
    branch="main",
    subfolder="optional/subfolder"
)
```

## Configuration

### Environment Variables (New Method)

These environment variables are used by the new Git integration method (`--git` flag):

| Variable             | Description                                                          | Required  | Default   |
|----------------------|----------------------------------------------------------------------|-----------|-----------|
| `GIT_REPOSITORY_URL` | URL of the Git repository                                            | Yes       | -         |
| `GIT_TARGET_PATH`    | Local directory for fetched files                                    | Yes       | -         |
| `GIT_SPARSE_PATH`    | Path to fetch from repository                                        | No        | All files |
| `GIT_BRANCH`         | Branch to fetch from                                                 | No        | `main`    |
| `GIT_SUBFOLDER`      | Subfolder for file organization                                      | No        | Empty     |
| `GIT_USERNAME`       | Git username for authentication (mandatory for private repositories) | No        | -         |
| `GIT_TOKEN`          | Git token for authentication (mandatory for private repositories)    | No        | -         |

### Legacy Configuration (Deprecated Method)

The deprecated `--git=URL` method supports two ways to provide credentials:

#### Option 1: Environment Variables (Recommended for Kubernetes)
- `ENVCHECKER_GIT_USERNAME` - Git username (passed via Kubernetes Secret)
- `ENVCHECKER_GIT_TOKEN` - Git token/password (passed via Kubernetes Secret)
- `ENVCHECKER_GIT_DOMAIN` - Git domain (e.g., `git.example.com`). If empty, will be extracted from repository URL. **Required** - error will be shown if domain cannot be determined.

These variables are automatically populated from the `env-checker-git-secret` Kubernetes Secret when deployed via Helm.

#### Option 2: Files on Disk (Legacy Fallback)
- Git credentials from `/etc/git/git-user` and `/etc/git/git-token` files (base64 encoded)
- Used as fallback if environment variables are not set
- Maintained for backward compatibility with older deployments

**Priority**: Environment variables are checked first, then files are used as fallback.

**Other configuration:**
- Repository URL passed directly in the `--git=URL` flag
- Files are cloned to `/home/jovyan/<repo-name>/` directory

**Debug Output:**
The script outputs debug information including:
- Full Git repository URL (with masked credentials)
- Authentication URL (with masked credentials)
- Domain being used for authentication

### Command Line Usage

#### New Method - Python Script (Recommended)

**Basic Usage:**
```bash
# Using environment variables (recommended)
python git_helper.py

# With explicit arguments
python git_helper.py <repo_url> <target_path> <sparse_path> [branch] [subfolder]
```

**Examples:**
```bash
# Using environment variables
export GIT_REPOSITORY_URL="https://github.com/owner/repo.git"
export GIT_TARGET_PATH="/home/jovyan/target"
export GIT_SPARSE_PATH="notebooks/test.ipynb"
export GIT_BRANCH="main"
python git_helper.py

# With explicit arguments - fetch single file
python git_helper.py \
  "https://github.com/owner/repo.git" \
  "/home/jovyan/target" \
  "notebooks/test.ipynb" \
  "main"

# With explicit arguments - fetch entire folder
python git_helper.py \
  "https://github.com/owner/repo.git" \
  "/home/jovyan/target" \
  "notebooks/" \
  "develop" \
  "project/subfolder"
```

#### Legacy Method - Bash Script (Deprecated)

**Basic Usage:**
```bash
bash shells/git_helper.sh <repo_url>
bash shells/git_helper.sh download_folder_or_file <repo_url> <branch> <path> <output_folder>
```

**Configuration:**

The script reads credentials in the following priority order:
1. **Environment variables** (from Kubernetes Secret):
   - `ENVCHECKER_GIT_USERNAME` - Git username
   - `ENVCHECKER_GIT_TOKEN` - Git token/password
   - `ENVCHECKER_GIT_DOMAIN` - Git domain (optional, extracted from URL if not set)

2. **Files on disk** (fallback for backward compatibility):
   - `/etc/git/git-user` - base64-encoded username
   - `/etc/git/git-token` - base64-encoded token

**Examples:**
```bash
# Clone/pull entire repository
# Credentials from environment variables (recommended)
export ENVCHECKER_GIT_USERNAME="user"
export ENVCHECKER_GIT_TOKEN="token"
export ENVCHECKER_GIT_DOMAIN="git.example.com"  # Required if domain cannot be extracted from URL
bash shells/git_helper.sh https://git.example.com/env-checker-notebooks.git

# Or using files (legacy)
bash shells/git_helper.sh https://git.example.com/env-checker-notebooks.git

# Download specific folder/file (sparse checkout)
bash shells/git_helper.sh download_folder_or_file \
  "https://git.example.com/repo.git" \
  "main" \
  "notebooks/test.ipynb" \
  "/home/jovyan/git_source/test"
```

**Debug Output:**
The script provides debug information:
```text
DEBUG: Git authentication URL: https://user:***@git.example.com
DEBUG: Full Git repository URL: https://git.example.com/repo.git
```

**Note**: The legacy Bash script is maintained for backward compatibility only. New implementations should use the Python script with environment variables.

**Kubernetes/Helm Configuration:**

For Kubernetes deployments, credentials are provided via the `env-checker-git-secret` Secret:

```yaml
# Helm values.yaml - Legacy variables for git_helper.sh
ENVCHECKER_GIT_USERNAME: 'your-username'
ENVCHECKER_GIT_TOKEN: 'your-token'
ENVCHECKER_GIT_DOMAIN: 'git.example.com'  # Required if domain cannot be extracted from repository URL

# New method variables (for git_helper.py)
git:
  username: 'your-username'
  token: 'your-token'
  repositoryUrl: 'https://git.example.com/owner/repo.git'
  targetPath: '/home/jovyan/target'
  sparsePath: 'notebooks/'
  branch: 'main'
  subfolder: ''
```

This creates a Secret with:
- `ENVCHECKER_GIT_USERNAME` - mapped from `ENVCHECKER_GIT_USERNAME` (top-level in values.yaml)
- `ENVCHECKER_GIT_TOKEN` - mapped from `ENVCHECKER_GIT_TOKEN` (top-level in values.yaml)
- `ENVCHECKER_GIT_DOMAIN` - mapped from `ENVCHECKER_GIT_DOMAIN` (top-level in values.yaml)
- `GIT_USERNAME`, `GIT_TOKEN`, etc. - mapped from `git.*` section (for new method)

The Secret is automatically mounted as environment variables in the Pod.

## Path Handling Differences

### New Method (Environment Variables)
- Files are fetched to `<GIT_TARGET_PATH>/<GIT_SUBFOLDER>/...`
- File paths in `run.sh` are used as-is (no automatic prefix)
- You must specify the full path relative to `GIT_TARGET_PATH`

**Example:**
```bash
export GIT_TARGET_PATH="/home/jovyan/target"
export GIT_SPARSE_PATH="notebooks/"
bash run.sh --git /home/jovyan/target/notebooks/test.ipynb
```

### Legacy Method (Deprecated)
- Repository is cloned to `/home/jovyan/<repo-name>/`
- File paths are automatically prefixed with `<repo-name>/`
- Paths in composite files are also adjusted automatically

**Example:**
```bash
bash run.sh --git=https://git.example.com/repo.git notebooks/test.ipynb
# File is executed from: /home/jovyan/repo/notebooks/test.ipynb
```

## Backward Compatibility

The system maintains full backward compatibility with the legacy `--git=URL` format:
- ✅ Old commands continue to work
- ✅ Path handling is preserved for legacy method
- ✅ Composite files with relative paths work correctly
- ⚠️ Legacy method shows deprecation warnings
- ⚠️ Legacy method is disabled in PRODUCTION_MODE=true

## Testing

### Manual Testing

The system includes comprehensive manual testing through the `git_integration_tests.ipynb` notebook, which covers:

#### Test Scenarios
1. **Regular Integration Run**: Basic repository fetching and file retrieval
2. **Non-existent Repository**: Error handling for invalid repository URLs
3. **Single File Creation**: Testing simple file fetch operations
4. **Deep Nesting**: Testing complex directory structure creation
5. **Folder Fetching**: Testing entire folder retrieval
6. **Non-existent Files**: Error handling for invalid file paths
7. **Branch Operations**: Testing different branch fetching
8. **Subfolder Organization**: Testing file organization options

#### Running Manual Tests
```bash
# Execute the test notebook
bash run.sh tests/notebooks/git_integration_tests.ipynb
```

### Automated Testing

**Status**: TBD
