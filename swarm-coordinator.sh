#!/bin/bash
# swarm-coordinator.sh - Works on any Git forge
# Universal Self-Distributing Swarm Coordinator

set -e

VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[SWARM]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# Detect platform from CI environment or git remote
detect_platform() {
    # Check CI environment variables first
    if [ -n "$GITHUB_ACTIONS" ]; then
        echo "github"
    elif [ -n "$GITLAB_CI" ]; then
        echo "gitlab"
    elif [ -n "$GITEA_ACTIONS" ]; then
        echo "gitea"
    elif [ -n "$FORGEJO_ACTIONS" ]; then
        echo "forgejo"
    elif [ -n "$CI_WOODPECKER" ]; then
        echo "woodpecker"
    else
        # Detect from git remote
        local remote
        remote=$(git remote get-url origin 2>/dev/null || echo "")
        case "$remote" in
            *github.com*) echo "github" ;;
            *gitlab.com*|*gitlab.*) echo "gitlab" ;;
            *gitea.*) echo "gitea" ;;
            *codeberg.org*|*forgejo.*) echo "forgejo" ;;
            *) echo "generic" ;;
        esac
    fi
}

# Get repository info from git remote
get_repo_info() {
    local remote
    remote=$(git remote get-url origin 2>/dev/null || echo "")
    
    # Parse owner/repo from various URL formats
    if [[ "$remote" =~ ^https?://([^/]+)/([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        FORGE_HOST="${BASH_REMATCH[1]}"
        OWNER="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"
    elif [[ "$remote" =~ ^git@([^:]+):([^/]+)/([^/.]+)(\.git)?$ ]]; then
        FORGE_HOST="${BASH_REMATCH[1]}"
        OWNER="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"
    else
        FORGE_HOST="unknown"
        OWNER="unknown"
        REPO="unknown"
    fi
    
    export FORGE_HOST OWNER REPO
}

# Discover forks (platform-specific)
discover_forks() {
    local platform=$1
    
    case "$platform" in
        github)
            curl -s "https://api.github.com/repos/$OWNER/$REPO/forks?per_page=100" 2>/dev/null \
                | jq -r '.[].full_name' 2>/dev/null || echo ""
            ;;
        gitlab)
            local project_id="${OWNER}%2F${REPO}"
            curl -s "https://${FORGE_HOST}/api/v4/projects/${project_id}/forks" 2>/dev/null \
                | jq -r '.[].path_with_namespace' 2>/dev/null || echo ""
            ;;
        gitea|forgejo)
            curl -s "https://${FORGE_HOST}/api/v1/repos/${OWNER}/${REPO}/forks" 2>/dev/null \
                | jq -r '.[].full_name' 2>/dev/null || echo ""
            ;;
        *)
            # Fallback: no API, return empty
            echo ""
            ;;
    esac
}

# Calculate health based on fork count
calculate_health() {
    local fork_count=$1
    
    if [ "$fork_count" -ge 10 ]; then
        echo "healthy"
    elif [ "$fork_count" -ge 6 ]; then
        echo "stable"
    elif [ "$fork_count" -ge 3 ]; then
        echo "vulnerable"
    else
        echo "degraded"
    fi
}

# Main coordination logic
main() {
    log "Self-Distributing Swarm Coordinator v$VERSION"
    echo ""
    
    # Detect platform
    PLATFORM=$(detect_platform)
    log "Detected platform: $PLATFORM"
    
    # Get repository info
    get_repo_info
    log "Repository: $OWNER/$REPO"
    log "Forge host: $FORGE_HOST"
    echo ""
    
    # Discover forks
    log "Discovering swarm topology..."
    FORKS=$(discover_forks "$PLATFORM")
    FORK_COUNT=$(echo "$FORKS" | grep -v '^$' | wc -l | tr -d ' ')
    
    if [ "$FORK_COUNT" -gt 0 ]; then
        log "Discovered $FORK_COUNT forks:"
        echo "$FORKS" | head -20
        if [ "$FORK_COUNT" -gt 20 ]; then
            info "... and $((FORK_COUNT - 20)) more"
        fi
    else
        info "No forks discovered yet"
    fi
    echo ""
    
    # Calculate health
    HEALTH=$(calculate_health "$FORK_COUNT")
    log "Swarm health: $HEALTH ($FORK_COUNT forks)"
    echo ""
    
    # Create/update swarm manifest
    log "Updating swarm manifest..."
    mkdir -p .swarm
    
    # Generate node ID (portable across Linux/macOS)
    NODE_ID=$(echo "$OWNER/$REPO" | sha256sum 2>/dev/null | cut -c1-16 || \
              echo "$OWNER/$REPO" | shasum -a 256 2>/dev/null | cut -c1-16 || \
              echo "$(echo "$OWNER/$REPO" | md5sum 2>/dev/null | cut -c1-16)" || \
              echo "unknown")
    
    # Build forks array for JSON (handle empty case)
    if [ -n "$FORKS" ] && [ "$(echo "$FORKS" | grep -v '^$' | wc -l)" -gt 0 ]; then
        FORKS_JSON=$(echo "$FORKS" | grep -v '^$' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
    else
        FORKS_JSON="[]"
    fi
    
    # Create manifest JSON
    cat > .swarm/manifest.json << EOF
{
  "version": "$VERSION",
  "platform": "$PLATFORM",
  "forge_host": "$FORGE_HOST",
  "repository": "$OWNER/$REPO",
  "node_id": "$NODE_ID",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "swarm_topology": {
    "fork_count": $FORK_COUNT,
    "health": "$HEALTH",
    "forks": $FORKS_JSON
  },
  "distribution_mechanics": {
    "method": "fork-native",
    "replication": "automatic via git clone",
    "discovery": "platform API + git branches",
    "healing": "via CI/CD sync",
    "consensus": "git merge"
  }
}
EOF
    
    log "✓ Swarm manifest updated"
    
    # Commit changes (if any) - use --local to not affect global git config
    git config --local user.name "Swarm Coordinator" 2>/dev/null || true
    git config --local user.email "swarm@devswarm.local" 2>/dev/null || true
    
    if ! git diff --quiet .swarm/ 2>/dev/null; then
        git add .swarm/
        git commit -m "🐝 Swarm: Update topology ($FORK_COUNT forks on $PLATFORM)" 2>/dev/null || true
        
        # Try to push (may fail on forks without write access - that's OK)
        if git push origin HEAD 2>/dev/null; then
            log "✓ Changes pushed"
        else
            info "Push skipped (no write access or no changes)"
        fi
    else
        info "No changes to commit"
    fi
    
    echo ""
    log "✓ Swarm coordination complete"
}

# Run
main "$@"