import sys
import os
import subprocess
import shutil
import requests
from urllib.parse import urlsplit, urlunsplit, quote


def get_git_config():
    """
    Get Git configuration from environment variables with default values.

    Returns:
        dict: Dictionary containing all Git configuration values.
    """
    return {
        'username': os.environ.get("GIT_USERNAME", ""),
        'token': os.environ.get("GIT_TOKEN", ""),
        'repository_url': os.environ.get("GIT_REPOSITORY_URL", ""),
        'target_path': os.environ.get("GIT_TARGET_PATH", ""),
        'sparse_path': os.environ.get("GIT_SPARSE_PATH", ""),
        'branch': os.environ.get("GIT_BRANCH", "main"),
        'subfolder': os.environ.get("GIT_SUBFOLDER", "")
    }


def check_repo_exists(repo_url: str) -> bool:
    """
    Simple repository existence check via GET request.

    Args:
        repo_url (str): Repository URL

    Returns:
        bool: True if repository exists, False if not
    """
    try:
        response = requests.get(repo_url, timeout=10)
        return response.status_code != 404
    except Exception:
        # If request fails, assume repository exists and let git handle it
        return True


def authenticate_repo_url(repo_url: str) -> str:
    """
    Authenticate repository URL using environment variables if available.

    Args:
        repo_url (str): The original repository URL.

    Returns:
        str: Authenticated URL if GIT_USERNAME/GIT_TOKEN are available, otherwise original URL.
    """
    config = get_git_config()
    username = config.get('username')
    token = config.get('token')
    if username and token:
        return get_auth_string(token=token, username=username, repo_url=repo_url)
    return repo_url


def fetch_from_repo(repo_url: str, target_path: str, sparse_path: str,
                    branch: str = "main", subfolder: str = "") -> bool:
    """
    Sparse-checkout a repository path into target_path.
    If GIT_USERNAME/GIT_TOKEN are present in the environment, the function
    will authenticate by embedding credentials into the repo URL (HTTPS only).

    Args:
        repo_url (str): The URL of the Git repository.
        target_path (str): Local directory where files will be fetched.
        sparse_path (str): Path to fetch from the repository.
        branch (str): Branch to fetch from. Defaults to "main".
        subfolder (str): Subfolder to move files to. Defaults to "".

    Returns:
        bool: True if successful.

    Raises:
        FileExistsError: If target_path already exists.
        subprocess.CalledProcessError: If git commands fail.
    """
    print(
        f"repo_url={repo_url}, target_path={target_path}, sparse_path={sparse_path}, "
        f"branch={branch}, subfolder={subfolder}"
    )

    # Authenticate URL if credentials are available
    repo_url = authenticate_repo_url(repo_url)

    if os.path.exists(target_path):
        print(f"Removed: {target_path}")
        shutil.rmtree(target_path)

    # init empty repo and enable sparse checkout
    os.makedirs(target_path, exist_ok=True)
    subprocess.run(["git", "init"], cwd=target_path, check=True)
    subprocess.run(["git", "remote", "add", "origin", repo_url], cwd=target_path, check=True)
    subprocess.run(["git", "config", "core.sparseCheckout", "true"], cwd=target_path, check=True)

    sparse_file = os.path.join(target_path, ".git", "info", "sparse-checkout")
    with open(sparse_file, "w", encoding="utf-8") as f:
        f.write(sparse_path + "\n")

    subprocess.run(["git", "pull", "origin", branch], cwd=target_path, check=True)

    src_path = os.path.join(target_path, *sparse_path.split("/"))
    if subfolder:
        dst_dir = os.path.join(target_path, subfolder)
        os.makedirs(dst_dir, exist_ok=True)
        # If src_path is a directory, move its contents to dst_dir
        if os.path.isdir(src_path):
            for item in os.listdir(src_path):
                shutil.move(os.path.join(src_path, item), dst_dir)
            shutil.rmtree(src_path)
        else:
            shutil.move(src_path, dst_dir)
        # Remove all parent directories created by git (e.g., jovyan/tests)
        top_level = os.path.join(target_path, sparse_path.split("/")[0])
        if os.path.exists(top_level):
            shutil.rmtree(top_level)
    else:
        # If src_path is a directory, move its contents to target_path
        if os.path.isdir(src_path):
            for item in os.listdir(src_path):
                shutil.move(os.path.join(src_path, item), target_path)
            shutil.rmtree(src_path)
        else:
            shutil.move(src_path, target_path)
        # Remove all parent directories created by git (e.g., jovyan/tests)
        top_level = os.path.join(target_path, sparse_path.split("/")[0])
        if os.path.exists(top_level):
            shutil.rmtree(top_level)
    return True


def get_auth_string(token: str, username: str, repo_url: str) -> str:
    """
    Authenticate with a Git repository using a token and a username.

    Args:
        token (str): The token to use for authentication.
        username (str): The username to use for authentication.
        repo_url (str): The URL of the Git repository.

    Returns:
        str: The authenticated URL of the Git repository. If creds are missing,
        returns the original URL unchanged.

    Notes:
        - Works for HTTPS(S) URLs by embedding credentials in netloc.
        - SSH URLs are returned unchanged.
    """
    if not token or not username:
        return repo_url

    parts = urlsplit(repo_url)
    # don't try to inject into SSH/other schemes
    if parts.scheme not in ("http", "https"):
        return repo_url

    # netloc may already contain creds; replace them
    host = parts.hostname or ""
    port = f":{parts.port}" if parts.port else ""
    auth = f"{quote(username)}:{quote(token)}@" if username and token else ""
    new_netloc = f"{auth}{host}{port}"
    return urlunsplit((parts.scheme, new_netloc, parts.path, parts.query, parts.fragment))


def fetch_from_git_config() -> bool:
    """
    Fetch repository using Git configuration from environment variables.

    Returns:
        bool: True if successful.
    """
    config = get_git_config()

    # Validate required configuration
    required_fields = ['repository_url', 'target_path']
    missing_fields = [field for field in required_fields if not config.get(field)]

    if missing_fields:
        print(f"ERROR: Missing required Git configuration: {', '.join(missing_fields)}")
        print("Required environment variables:")
        print("  GIT_REPOSITORY_URL - URL of the Git repository")
        print("  GIT_TARGET_PATH - Local directory where files will be fetched")
        return False

    # Use defaults for optional fields
    repo_url = config['repository_url']
    target_path = config['target_path']
    sparse_path = config.get('sparse_path', '')
    branch = config.get('branch', 'main')
    subfolder = config.get('subfolder', '')

    print(f"Fetching repository: {repo_url}")
    print(f"Target path: {target_path}")
    print(f"Sparse path: {sparse_path or 'all files'}")
    print(f"Branch: {branch}")
    print(f"Subfolder: {subfolder or 'none'}")

    try:
        # Fetch the repository
        success = fetch_from_repo(repo_url, target_path, sparse_path, branch, subfolder)
        return success

    except Exception as e:
        print(f"ERROR: Failed to fetch repository: {e}")
        return False


def run_fetch(repo_url: str, target_path: str, sparse_path: str,
              branch: str = "main", subfolder: str = "") -> bool:
    """
    Simple wrapper for fetch_from_repo for use in tests.

    Args:
        repo_url (str): Repository URL
        target_path (str): Target path
        sparse_path (str): Sparse checkout path
        branch (str): Branch
        subfolder (str): Subfolder

    Returns:
        bool: True if successful, False if error
    """
    try:
        return fetch_from_repo(repo_url, target_path, sparse_path, branch, subfolder)
    except Exception as e:
        print(f"ERROR: Failed to fetch repository: {e}")
        return False


if __name__ == "__main__":
    # No arguments - use environment variables (Helm-provided GIT_* envs)
    if len(sys.argv) == 1:
        success = fetch_from_git_config()
        sys.exit(0 if success else 1)

    # Explicit args mode: expect at least 3 required args
    if len(sys.argv) >= 4:
        repo_url = sys.argv[1]

        # Check if repository exists before proceeding
        if not check_repo_exists(repo_url):
            print(f"ERROR: Repository does not exist: {repo_url}")
            sys.exit(1)

        target_path = sys.argv[2]
        sparse_path = sys.argv[3]
        branch = sys.argv[4] if len(sys.argv) > 4 else "main"
        subfolder = sys.argv[5] if len(sys.argv) > 5 else ""
        fetch_from_repo(repo_url, target_path, sparse_path, branch, subfolder)
        sys.exit(0)

    # Fallback: show usage when insufficient arguments were provided
    print("Usage: python3 git_helper.py <repo_url> <target_path> <sparse_path> [branch] [subfolder]")
    print("Or: python3 git_helper.py  # uses GIT_* environment variables")
    sys.exit(1)
