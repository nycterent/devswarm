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
    
    # Parse owner/repo from various URL formats (handles subgroups like gitlab.com/group/subgroup/repo)
    if [[ "$remote" =~ ^https?://([^/]+)/(.*)/([^/]+?)(\.git)?/?$ ]]; then
        FORGE_HOST="${BASH_REMATCH[1]}"
        OWNER="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"
        # Remove trailing .git from repo name if present
        REPO="${REPO%.git}"
    elif [[ "$remote" =~ ^git@([^:]+):(.*)/([^/]+?)(\.git)?$ ]]; then
        FORGE_HOST="${BASH_REMATCH[1]}"
        OWNER="${BASH_REMATCH[2]}"
        REPO="${BASH_REMATCH[3]}"
        REPO="${REPO%.git}"
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
            # Use GITHUB_TOKEN if available to avoid rate limiting
            local auth_header=""
            if [ -n "$GITHUB_TOKEN" ]; then
                auth_header="Authorization: token ${GITHUB_TOKEN}"
                curl -s -H "$auth_header" "https://api.github.com/repos/$OWNER/$REPO/forks?per_page=100" 2>/dev/null \
                    | jq -r '.[].full_name' 2>/dev/null || echo ""
            else
                curl -s "https://api.github.com/repos/$OWNER/$REPO/forks?per_page=100" 2>/dev/null \
                    | jq -r '.[].full_name' 2>/dev/null || echo ""
            fi
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
    
    # Robust fork count calculation
    if [ -z "$FORKS" ]; then
        FORK_COUNT=0
    else
        FORK_COUNT=$(echo "$FORKS" | grep -v '^$' | wc -l | tr -d ' ')
        # Handle case where result is empty
        if [ -z "$FORK_COUNT" ]; then
            FORK_COUNT=0
        fi
    fi
    
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
    if command -v sha256sum >/dev/null 2>&1; then
        NODE_ID=$(echo "$OWNER/$REPO" | sha256sum | awk '{print substr($1,1,16)}')
    elif command -v shasum >/dev/null 2>&1; then
        NODE_ID=$(echo "$OWNER/$REPO" | shasum -a 256 | awk '{print substr($1,1,16)}')
    elif command -v md5sum >/dev/null 2>&1; then
        NODE_ID=$(echo "$OWNER/$REPO" | md5sum | awk '{print substr($1,1,16)}')
    else
        NODE_ID="unknown"
    fi
    
    # Build forks array for JSON
    if [ "$FORK_COUNT" -gt 0 ]; then
        FORKS_JSON=$(echo "$FORKS" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    else
        FORKS_JSON="[]"
    fi
    
    # Create manifest JSON using jq for safe escaping
    jq -n \
      --arg version "$VERSION" \
      --arg platform "$PLATFORM" \
      --arg forge_host "$FORGE_HOST" \
      --arg repository "$OWNER/$REPO" \
      --arg node_id "$NODE_ID" \
      --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg health "$HEALTH" \
      --argjson fork_count "$FORK_COUNT" \
      --argjson forks "$FORKS_JSON" \
      '{
        version: $version,
        platform: $platform,
        forge_host: $forge_host,
        repository: $repository,
        node_id: $node_id,
        updated_at: $updated_at,
        swarm_topology: {
          fork_count: $fork_count,
          health: $health,
          forks: $forks
        },
        distribution_mechanics: {
          method: "fork-native",
          replication: "automatic via git clone",
          discovery: "platform API + git branches",
          healing: "via CI/CD sync",
          consensus: "git merge"
        }
      }' > .swarm/manifest.json
    
    log "✓ Swarm manifest updated"
    
    # Commit changes (if any) - use --local to not affect global git config
    git config --local user.name "Swarm Coordinator" 2>/dev/null || true
    git config --local user.email "swarm@devswarm.local" 2>/dev/null || true
    
    # Check if .swarm directory exists and has changes
    if [ -d .swarm ] && ! git diff --quiet .swarm/ 2>/dev/null; then
        git add .swarm/
        
        # Try to commit with proper error handling
        COMMIT_OUTPUT=$(git commit -m "🐝 Swarm: Update topology ($FORK_COUNT forks on $PLATFORM)" 2>&1)
        COMMIT_EXIT=$?
        
        if [ $COMMIT_EXIT -ne 0 ]; then
            if echo "$COMMIT_OUTPUT" | grep -q "nothing to commit"; then
                info "No changes to commit"
            else
                warn "git commit failed: $COMMIT_OUTPUT"
            fi
        else
            log "✓ Commit successful"
            
            # Try to push (may fail on forks without write access - that's OK)
            if git push origin HEAD 2>/dev/null; then
                log "✓ Changes pushed"
            else
                info "Push skipped (no write access or no changes)"
            fi
        fi
    else
        info "No changes to commit"
    fi
    
    echo ""
    log "✓ Swarm coordination complete"
}

# Run
main "$@"