#!/bin/bash

# DEPRECATED: This script is maintained for backward compatibility only.
# New implementations should use utils/integration/git_helper.py with GIT_* environment variables.
# See GitIntegrationDocumentation.md for details.

# Set global variables on top level (for backward compatibility with source)
git_source_path=$1
# get folder for storage "https://git.example.com/prod.cse.ssm/env-checker-notebooks.git" -> "env-checker-notebooks"
relative_path=$(basename -s .git "$git_source_path" 2>/dev/null || echo "")
absolute_path="/home/jovyan/$relative_path"

#$1 - path to project source notebooks folder
gitProcess() {
    # Use global variables (backward compatibility)
    prepare_git_config_files "$git_source_path"
    echo -e "\ngitProcess has been started"
    check_relative_path_is_exists "$git_source_path" "$relative_path" "$absolute_path"
    echo -e "gitProcess has been finished\n"
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
        username=$(echo -n "$(</etc/git/git-user)" | base64 -d 2>/dev/null || echo "")
    fi
    if [ -z "$token" ] && [ -f /etc/git/git-token ]; then
        token=$(echo -n "$(</etc/git/git-token)" | base64 -d 2>/dev/null || echo "")
    fi

    # If we have credentials, configure Git
    if [ -n "$username" ] && [ -n "$token" ]; then
        git config --global credential.username "$username"
        git config --global credential.helper 'store --file ~/.git-credentials'

        # Get domain from environment variable
        local git_domain="${ENVCHECKER_GIT_DOMAIN:-}"

        # If domain is not set, try to extract from git_source_path (global or provided)
        if [ -z "$git_domain" ] && [ -n "$source_path" ]; then
            # Extract domain from URL (e.g., https://git.example.com/repo.git -> git.example.com)
            git_domain=$(echo "$source_path" | sed -E 's|^https?://([^/]+).*|\1|' | sed 's|:.*||' 2>/dev/null || echo "")
        fi

        # Domain is required - fail if not set
        if [ -z "$git_domain" ]; then
            echo "ERROR: Git domain is not specified. Please set ENVCHECKER_GIT_DOMAIN environment variable or provide a repository URL with domain."
            return 1
        fi

        # Build full authenticated URL for debugging
        local auth_url="https://$username:$token@$git_domain"
        echo "DEBUG: Git authentication URL: https://$username:***@$git_domain"
        echo "DEBUG: Using Git domain: $git_domain"

        # Store credentials for Git
        echo "$auth_url" >>~/.git-credentials
    else
        echo "WARNING: No Git credentials found (neither ENVCHECKER_GIT_USERNAME/ENVCHECKER_GIT_TOKEN env vars nor /etc/git/git-user/git-token files)"
    fi
}

check_relative_path_is_exists() {
    # Use global variables (backward compatibility)
    echo "git_source_path=$git_source_path"
    echo "relative_path=$relative_path"
    echo "absolute_path=$absolute_path"

    # Debug: Show full Git URL (with masked credentials)
    if [[ "$git_source_path" == http* ]]; then
        local debug_url
        debug_url=$(echo "$git_source_path" | sed -E 's|://([^:]+):([^@]+)@|://\1:***@|')
        echo "DEBUG: Full Git repository URL: $debug_url"
    fi

    if [ -d "/home/jovyan/$relative_path" ]; then
        echo "Path exists: /home/jovyan/$relative_path. Run the pull operation"
        run_git_pull
    else
        echo "Path does not exist: /home/jovyan/$relative_path. Run the checkout operation"
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

    echo -e "\ndownload_folder_from_git has been started"
    if [ -z "$repo_url" ] || [ -z "$branch" ] || [ -z "$folder_or_file_path" ] || [ -z "$output_folder" ]; then
        echo "Error: Repository URL, branch name, folder path, and output folder name are required."
        return 1
    fi

    if [ -d "$output_folder/$folder_or_file_path" ] || [ -f "$output_folder/$folder_or_file_path" ]; then
        echo "The $output_folder/$folder_or_file_path already exists. Skip cloning."
        return 0
    fi

    # Cloning $repo_url for $branch to $output_folder
    # --depth 1          - cloning only last commit
    # --filter=blob:none - skipped blob-objects (for data reduction)
    # --sparse           - cloning in sparse-checkout mode
    if ! git clone --branch "$branch" --depth 1 --filter=blob:none --sparse "$repo_url" "$output_folder"; then
        echo "Error while cloning repository."
        return 1
    fi

    cd "$output_folder" || exit # Goes to the directory into which the repository was cloned.
    echo "Setting up sparse-checkout..."
    git sparse-checkout init --no-interaction # Initializes sparse-checkout. --no-interaction - executing a command without user confirmation
    if ! git sparse-checkout set "$folder_or_file_path"; then
        echo "Error configuring sparse-checkout."
        return 1
    fi

    echo "Download folder from git completed successfully."
    echo -e "download_folder_from_git has been finished\n"

    return 0
}

# Only execute if script is run directly (not sourced)
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ "$1" == "download_folder_or_file" ]; then
        # Pass repo_url (second argument) to prepare_git_config_files for domain extraction
        if ! prepare_git_config_files "${2:-}"; then
            echo "ERROR: Failed to prepare Git configuration"
            exit 1
        fi
        download_folder_or_file_from_git "$2" "$3" "$4" "$5"
    else
        gitProcess "$1"
    fi
fi
