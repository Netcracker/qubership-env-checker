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
fi

# Set global variables on top level (for backward compatibility with source)
git_source_path=$1
# get folder for storage "https://git.example.com/project/env-checker-notebooks.git" -> "env-checker-notebooks"
relative_path=$(basename -s .git "$git_source_path" 2>/dev/null || echo "")
absolute_path="/home/jovyan/$relative_path"

#$1 - path to project source notebooks folder
gitProcess() {
    # Use global variables (backward compatibility)
    prepare_git_config_files "$git_source_path"
    log_info "Git process started" git_source_path "$git_source_path"
    check_relative_path_is_exists "$git_source_path" "$relative_path" "$absolute_path"
    log_info "Git process finished" git_source_path "$git_source_path"
    echo "$relative_path"
}

prepare_git_config_files() {
    # Use global git_source_path if provided as argument, otherwise use global variable (backward compatibility)
    local source_path="${1:-$git_source_path}"

    git config --global http.sslVerify false

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
        git config --global credential.username "$username"
        git config --global credential.helper 'store --file ~/.git-credentials'

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

        # Store credentials for Git
        echo "$auth_url" >>~/.git-credentials
    else
        log_warn "No Git credentials found" sources_checked "ENVCHECKER_GIT_USERNAME/ENVCHECKER_GIT_TOKEN, /etc/git/git-user, /etc/git/git-token"
    fi
}

check_relative_path_is_exists() {
    # Use global variables (backward compatibility)
    log_info "Git paths resolved" git_source_path "$git_source_path" relative_path "$relative_path" absolute_path "$absolute_path"

    # Debug: Show full Git URL (with masked credentials)
    if [[ "$git_source_path" == http* ]]; then
        local debug_url
        debug_url=$(echo "$git_source_path" | sed -E 's|://([^:]+):([^@]+)@|://\1:***@|')
        log_debug "Git repository URL" repo_url "$debug_url"
    fi

    if [ -d "/home/jovyan/$relative_path" ]; then
        log_info "Path exists; running the pull operation" path "/home/jovyan/$relative_path"
        run_git_pull
    else
        log_info "Path does not exist; running the checkout operation" path "/home/jovyan/$relative_path"
        run_git_checkout
    fi
}

run_git_checkout() {
    # Use global variables (backward compatibility)
    mkdir -p "$relative_path"
    git clone "$git_source_path" "$absolute_path"
}

run_git_pull() {
    # Use global variables (backward compatibility)
    cd "$absolute_path" || exit
    #Checks if there is a connection with the remote repository, if not - establishes a connection
    if [[ "$(git remote)" == "" ]]; then
        git remote add origin "$git_source_path"
    fi
    #Updates the origin branch from the server and downloads all changes.
    git fetch origin
    #Resets the state of the local branch to the state of the remote branch origin/master, ignoring all local changes
    git reset --hard origin/master
    cd ~ || exit
}

download_folder_or_file_from_git() {
    local repo_url=$1
    local branch=$2
    local folder_or_file_path=$3
    local output_folder=$4

    log_info "Folder download started" repo_url "$repo_url" branch "$branch"
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
    if ! git clone --branch "$branch" --depth 1 --filter=blob:none --sparse "$repo_url" "$output_folder"; then
        log_error "Failed to clone the repository" repo_url "$repo_url"
        return 1
    fi

    cd "$output_folder" || exit # Goes to the directory into which the repository was cloned.
    log_info "Setting up sparse checkout" sparse_path "$folder_or_file_path"
    git sparse-checkout init --no-interaction # Initializes sparse-checkout. --no-interaction - executing a command without user confirmation
    if ! git sparse-checkout set "$folder_or_file_path"; then
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
