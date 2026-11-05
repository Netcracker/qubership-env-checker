#!/bin/bash

# DEPRECATED: This script is maintained for backward compatibility only.
# New implementations should use utils/integration/git_helper.py with GIT_* environment variables.
# See GitIntegrationDocumentation.md for details.

# Structured logging helper. Records go to stderr so they never mix with the
# path this script echoes back to its caller on stdout.
if [ -f /home/jovyan/shells/log_json.sh ]; then
    # shellcheck disable=SC1091
    # shellcheck source=/home/jovyan/shells/log_json.sh
    source /home/jovyan/shells/log_json.sh
else
    # Degraded fallback when the helper is not part of the image.
    log_json() { echo "$@" >&2; }
    log_debug() { :; }
    log_info() { log_json INFO "$@"; }
    log_warn() { log_json WARN "$@"; }
    log_error() { log_json ERROR "$@"; }
    log_command() { "$@"; }
fi

# Set global variables on top level (for backward compatibility with source)
git_source_path=$1
# get folder for storage "https://git.example.com/project/env-checker-notebooks.git" -> "env-checker-notebooks"
relative_path=$(basename -s .git "$git_source_path" 2>/dev/null || echo "")
absolute_path="/home/jovyan/$relative_path"

#$1 - path to project source notebooks folder
gitProcess() {
    # Use global variables (backward compatibility)
    prepare_git_config_files "$git_source_path" || return 1
    log_info "Git process started"
    if ! check_relative_path_is_exists "$git_source_path" "$relative_path" "$absolute_path"; then
        log_error "Git process failed"
        return 1
    fi
    log_info "Git process finished"
    echo "$relative_path"
}

git_config_path_is_writable() {
    local path=$1
    { [ -e "$path" ] && [ -w "$path" ]; } ||
        { [ ! -e "$path" ] && [ -w "$(dirname "$path")" ]; }
}

include_existing_git_config() {
    local destination=$1
    local source=$2
    if [ ! -f "$source" ] || [ "$source" = "$destination" ]; then
        return 0
    fi
    if git config --file "$destination" --get-all include.path 2>/dev/null |
        grep -qxF "$source"; then
        return 0
    fi
    if ! git config --file "$destination" --add include.path "$source"; then
        log_error "Cannot preserve the existing Git configuration" path "$source"
        return 1
    fi
}

prepare_git_global_config() {
    local home="${HOME:-/home/jovyan}"
    local home_config="$home/.gitconfig"

    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
        if ! git_config_path_is_writable "$GIT_CONFIG_GLOBAL"; then
            log_error "Git global configuration is not writable" path "$GIT_CONFIG_GLOBAL"
            return 1
        fi
        return 0
    fi

    # Keep Git's native global-config search when ~/.gitconfig is writable. This preserves
    # settings from both $XDG_CONFIG_HOME/git/config and ~/.gitconfig.
    if git_config_path_is_writable "$home_config"; then
        return 0
    fi

    local config_file="${TMPDIR:-/tmp}/.gitconfig"
    if ! git_config_path_is_writable "$config_file"; then
        log_error "Git global configuration is not writable" path "$config_file"
        return 1
    fi
    export GIT_CONFIG_GLOBAL="$config_file"

    local xdg_config="${XDG_CONFIG_HOME:-$home/.config}/git/config"
    include_existing_git_config "$config_file" "$xdg_config" || return 1
    include_existing_git_config "$config_file" "$home_config" || return 1
}

quote_shell_argument() {
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

prepare_git_config_files() {
    # Use global git_source_path if provided as argument, otherwise use global variable (backward compatibility)
    local source_path="${1:-$git_source_path}"

    prepare_git_global_config || return 1
    if ! git config --global http.sslVerify false; then
        log_error "Cannot configure Git SSL verification"
        return 1
    fi

    # Try to get credentials from environment variables first (new method)
    local username="${ENVCHECKER_GIT_USERNAME:-}"
    local token="${ENVCHECKER_GIT_TOKEN:-}"

    # Fallback to files if environment variables are not set (old method for backward compatibility)
    if [ -z "$username" ] && [ -f /etc/git/git-user ]; then
        # Try to read as plain text first, then try base64 decode
        local file_content
        file_content=$(cat /etc/git/git-user 2>/dev/null || echo "")
        if [ -n "$file_content" ]; then
            # Try base64 decode, if it fails, use content as-is
            username=$(echo -n "$file_content" | base64 -d 2>/dev/null || echo "$file_content")
        fi
    fi
    if [ -z "$token" ] && [ -f /etc/git/git-token ]; then
        # Try to read as plain text first, then try base64 decode
        local file_content
        file_content=$(cat /etc/git/git-token 2>/dev/null || echo "")
        if [ -n "$file_content" ]; then
            # Try base64 decode, if it fails, use content as-is
            token=$(echo -n "$file_content" | base64 -d 2>/dev/null || echo "$file_content")
        fi
    fi

    # If we have credentials, configure Git
    if [ -n "$username" ] && [ -n "$token" ]; then
        # With a read-only root filesystem $HOME is not writable, so fall back to /tmp.
        local credentials_file="${GIT_CREDENTIALS_FILE:-$HOME/.git-credentials}"
        if [ -e "$credentials_file" ] && [ ! -w "$credentials_file" ]; then
            credentials_file="/tmp/.git-credentials"
        elif [ ! -e "$credentials_file" ] && [ ! -w "$(dirname "$credentials_file")" ]; then
            credentials_file="/tmp/.git-credentials"
        fi

        local quoted_credentials_file
        quoted_credentials_file=$(quote_shell_argument "$credentials_file")
        if ! git config --global credential.username "$username" ||
            ! git config --global credential.helper "store --file $quoted_credentials_file"; then
            log_error "Cannot configure Git credentials" path "${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}"
            return 1
        fi

        # Get domain from environment variable first
        local git_domain="${ENVCHECKER_GIT_DOMAIN:-}"
        # Fallback to file if environment variable is not set (old method for backward compatibility)
        if [ -z "$git_domain" ] && [ -f /etc/git/git-domain ]; then
            # Try to read as plain text first, then try base64 decode
            local file_content
            file_content=$(cat /etc/git/git-domain 2>/dev/null || echo "")
            if [ -n "$file_content" ]; then
                # Try base64 decode, if it fails, use content as-is
                git_domain=$(echo -n "$file_content" | base64 -d 2>/dev/null || echo "$file_content")
            fi
        fi

        # If domain is not set, try to extract from git_source_path (global or provided)
        if [ -z "$git_domain" ] && [ -n "$source_path" ]; then
            # Extract domain from URL (e.g., https://git.example.com/repo.git -> git.example.com)
            git_domain=$(echo "$source_path" | sed -E 's|^https?://([^/]+).*|\1|' | sed 's|:.*||' 2>/dev/null || echo "")
        fi

        # Domain is required - fail if not set
        if [ -z "$git_domain" ]; then
            log_error "Git domain is not specified" env_var "ENVCHECKER_GIT_DOMAIN"
            return 1
        fi

        # Build full authenticated URL for debugging
        local auth_url="https://$username:$token@$git_domain"
        log_debug "Git authentication configured" username "$username" git_domain "$git_domain"

        # Create the credential file without group or other access, and secure an existing file
        # before writing a token to it.
        if [ ! -e "$credentials_file" ] &&
            ! (umask 077 && : >"$credentials_file"); then
            log_error "Cannot create the Git credentials file" path "$credentials_file"
            return 1
        fi
        if [ ! -f "$credentials_file" ]; then
            log_error "Git credentials path is not a regular file" path "$credentials_file"
            return 1
        fi
        if ! chmod 600 "$credentials_file"; then
            log_error "Cannot secure the Git credentials file" path "$credentials_file"
            return 1
        fi

        # Store credentials for Git (once per value, so repeated runs do not grow the file)
        if ! grep -qxF "$auth_url" "$credentials_file" 2>/dev/null; then
            if ! echo "$auth_url" >>"$credentials_file"; then
                log_error "Cannot store Git credentials" path "$credentials_file"
                return 1
            fi
        fi
    else
        log_warn "No Git credentials found" sources_checked "ENVCHECKER_GIT_USERNAME/ENVCHECKER_GIT_TOKEN, /etc/git/git-user, /etc/git/git-token"
    fi
}

# Marks a directory as safe for Git (once), so a root-owned mount point does not block pull.
trust_git_directory() {
    local directory=$1
    prepare_git_global_config || return 1
    if ! git config --global --get-all safe.directory | grep -qxF "$directory"; then
        if ! git config --global --add safe.directory "$directory"; then
            log_error "Cannot configure Git safe.directory" path "$directory"
            return 1
        fi
    fi
}

check_relative_path_is_exists() {
    # Use global variables (backward compatibility)
    log_info "Git paths resolved" relative_path "$relative_path" absolute_path "$absolute_path"

    # Debug: Show full Git URL (with masked credentials)
    if [[ "$git_source_path" == http* ]]; then
        local debug_url
        debug_url=$(echo "$git_source_path" | sed -E 's|://([^:]+):([^@]+)@|://\1:***@|')
        log_debug "Git repository URL" repo_url "$debug_url"
    fi

    # A mounted volume root is usually owned by root while Git runs as another user, and Git
    # refuses to work in such a repository ("dubious ownership") on every run after the clone.
    trust_git_directory "$absolute_path" || return 1

    # A directory alone is not a repository: in Kubernetes the path is an emptyDir mount that
    # exists before the first clone. A checkout can have a .git directory or a .git file that
    # points to metadata elsewhere.
    if [ -d "$absolute_path/.git" ] || [ -f "$absolute_path/.git" ]; then
        log_info "Repository exists; running the pull operation" path "$absolute_path"
        run_git_pull
    else
        log_info "Repository does not exist; running the checkout operation" path "$absolute_path"
        run_git_checkout
    fi
}

run_git_checkout() {
    # Use global variables (backward compatibility)
    if ! mkdir -p "$absolute_path"; then
        log_error "Cannot create the Git checkout directory" path "$absolute_path"
        return 1
    fi
    if [ -z "$(ls -A "$absolute_path" 2>/dev/null)" ]; then
        # git clone accepts an existing empty directory (for example a volume mount).
        log_command git clone "$git_source_path" "$absolute_path"
    else
        # Do not overwrite files in a directory that Git does not manage.
        log_error "Directory is not empty and is not a Git repository" path "$absolute_path"
        return 1
    fi
}

# Prints the remote branch to sync with: origin/HEAD, then origin/main, then origin/master.
resolve_remote_branch() {
    local branch
    branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        git remote set-head origin --auto >/dev/null 2>&1
        branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    fi
    if [ -z "$branch" ]; then
        for candidate in origin/main origin/master; do
            if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                branch="$candidate"
                break
            fi
        done
    fi
    echo "$branch"
}

run_git_pull() {
    # Use global variables (backward compatibility)
    if ! cd "$absolute_path"; then
        log_error "Cannot enter the Git checkout directory" path "$absolute_path"
        return 1
    fi
    #Checks if there is a connection with the remote repository, if not - establishes a connection
    if [[ "$(git remote)" == "" ]]; then
        if ! git remote add origin "$git_source_path"; then
            log_error "Cannot configure the Git remote" remote "origin"
            cd ~ || return 1
            return 1
        fi
    fi
    #Updates the origin branch from the server and downloads all changes.
    log_command git fetch origin || {
        cd ~ || exit
        return 1
    }
    #Resets the state of the local branch to the remote default branch, ignoring all local changes
    local remote_branch
    remote_branch=$(resolve_remote_branch)
    if [ -z "$remote_branch" ]; then
        log_error "Cannot determine the remote branch" repo "$absolute_path"
        cd ~ || exit
        return 1
    fi
    log_info "Resetting to the remote branch" branch "$remote_branch"
    if ! log_command git reset --hard "$remote_branch"; then
        cd ~ || return 1
        return 1
    fi
    cd ~ || exit
}

download_folder_or_file_from_git() {
    local repo_url=$1
    local branch=$2
    local folder_or_file_path=$3
    local output_folder=$4

    log_info "Folder download started" branch "$branch"
    if [ -z "$repo_url" ] || [ -z "$branch" ] || [ -z "$folder_or_file_path" ] || [ -z "$output_folder" ]; then
        log_error "Missing required arguments" missing_args "repo_url, branch, folder_or_file_path, output_folder"
        return 1
    fi

    if [ -d "$output_folder/$folder_or_file_path" ] || [ -f "$output_folder/$folder_or_file_path" ]; then
        log_info "Target already exists; skipping the clone" output_folder "$output_folder" path "$folder_or_file_path"
        return 0
    fi

    # Cloning $repo_url for $branch to $output_folder
    # --depth 1          - cloning only last commit
    # --filter=blob:none - skipped blob-objects (for data reduction)
    # --sparse           - cloning in sparse-checkout mode
    if ! log_command git clone --branch "$branch" --depth 1 --filter=blob:none --sparse "$repo_url" "$output_folder"; then
        log_error "Failed to clone the repository"
        return 1
    fi

    cd "$output_folder" || exit # Goes to the directory into which the repository was cloned.
    log_info "Setting up sparse checkout" sparse_path "$folder_or_file_path"
    log_command git sparse-checkout init --no-interaction # Initializes sparse-checkout. --no-interaction - executing a command without user confirmation
    if ! log_command git sparse-checkout set "$folder_or_file_path"; then
        log_error "Failed to configure sparse checkout" sparse_path "$folder_or_file_path"
        return 1
    fi

    log_info "Folder download completed" output_folder "$output_folder"
    log_info "Folder download finished" output_folder "$output_folder"

    return 0
}

# Only execute if script is run directly (not sourced)
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ "$1" == "download_folder_or_file" ]; then
        # Pass repo_url (second argument) to prepare_git_config_files for domain extraction
        if ! prepare_git_config_files "${2:-}"; then
            log_error "Failed to prepare the Git configuration"
            exit 1
        fi
        download_folder_or_file_from_git "$2" "$3" "$4" "$5"
    else
        gitProcess "$1"
    fi
fi
