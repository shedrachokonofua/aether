#!/bin/bash
set -euo pipefail

BRANCH="main"
LOCK_FILE="/home/aether/coupe-updater.lock"

log() {
  echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $1"
}

cleanup() {
  exec 200>&-
}
trap cleanup EXIT

log "Starting updater"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another instance is running"
    exit 1
fi


cd /home/aether/coupe
log "Fetching latest changes..."

if git fetch origin "$BRANCH" 2>&1; then
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/"$BRANCH")

    if [ "$LOCAL" != "$REMOTE" ]; then
        log "Local and remote branches are different. Pulling latest changes..."
        if git pull origin "$BRANCH" 2>&1; then
            log "Pulled latest changes, running installation task"

            if task install 2>&1; then
                log "Installation completed"
            else
                log "ERROR: Installation failed"
                exit 1
            fi
        else
            log "ERROR: Git pull failed"
            exit 1
        fi
    else
        log "No changes to pull."
    fi
else
    log "Failed to fetch changes. Please check your network connection and try again."
fi

