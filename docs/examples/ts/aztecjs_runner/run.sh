#!/usr/bin/env bash
# Run aztec.js documentation examples against a live local network
#
# Prerequisites:
#   - Local Aztec network running on localhost:8080
#   - yarn-project packages built
#
# Usage:
#   ./run.sh                # Run all examples
#   ./run.sh connection     # Run specific example
#   ./run.sh getting_started advanced  # Run multiple examples
#
# Available examples: connection, getting_started, advanced, authwit, testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      Aztec.js Documentation Examples Test Runner           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if network is running
echo -e "${YELLOW}Checking network connection...${NC}"
if ! curl -s http://localhost:8080 > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot connect to Aztec network at localhost:8080${NC}"
    echo "Please start the network with: aztec start --sandbox"
    exit 1
fi
echo -e "${GREEN}✓ Network is running${NC}"
echo ""

# Setup function for a project
setup_project() {
    local project_name=$1
    local project_dir="$EXAMPLES_DIR/$project_name"

    echo -e "${YELLOW}Setting up $project_name...${NC}"

    cd "$project_dir"

    # Clean up any previous setup
    rm -rf node_modules .yarn package.json tsconfig.json artifacts 2>/dev/null || true

    # Run codegen for custom contracts if specified in config.yaml
    if command -v yq > /dev/null 2>&1; then
        local contract_count
        contract_count="$(yq eval '.contracts | length' config.yaml 2>/dev/null || echo "0")"

        if [ "$contract_count" -gt 0 ]; then
            local ARTIFACTS_DIR="$REPO_ROOT/docs/target"
            local BUILDER_CLI="$REPO_ROOT/yarn-project/builder/dest/bin/cli.js"

            while IFS= read -r contract_name; do
                local artifact="$ARTIFACTS_DIR/${contract_name}.json"
                if [ -f "$artifact" ]; then
                    node --no-warnings "$BUILDER_CLI" codegen "$artifact" -o artifacts > /dev/null 2>&1
                fi
            done < <(yq eval '.contracts[]' config.yaml)
        fi
    fi

    # Initialize yarn
    yarn init -y > /dev/null 2>&1
    yarn config set nodeLinker node-modules > /dev/null 2>&1

    # Set package type to module for ESM
    node -e "const pkg = require('./package.json'); pkg.type = 'module'; require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2));"

    # Read dependencies from config.yaml and install
    local deps=()
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Extract package name from YAML list item (- "@aztec/package")
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"?(@aztec/[a-z0-9._-]+)\"? ]]; then
            local pkg="${BASH_REMATCH[1]}"
            local pkg_name="${pkg#@aztec/}"
            deps+=("${pkg}@link:$REPO_ROOT/yarn-project/${pkg_name}")
        fi
    done < config.yaml

    if [ ${#deps[@]} -gt 0 ]; then
        yarn add "${deps[@]}" > /dev/null 2>&1
    fi

    yarn add -D typescript tsx > /dev/null 2>&1

    # Copy tsconfig
    cp "$EXAMPLES_DIR/tsconfig.template.json" tsconfig.json

    echo -e "${GREEN}✓ $project_name ready${NC}"
}

# Run function for a project
run_project() {
    local project_name=$1
    local project_dir="$EXAMPLES_DIR/$project_name"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}▶ Running: $project_name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    cd "$project_dir"

    local start_time=$(date +%s)

    if npx tsx index.ts; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo ""
        echo -e "${GREEN}✓ PASS - $project_name (${duration}s)${NC}"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo ""
        echo -e "${RED}✗ FAIL - $project_name (${duration}s)${NC}"
        return 1
    fi
}

# Cleanup function
cleanup_project() {
    local project_name=$1
    local project_dir="$EXAMPLES_DIR/$project_name"

    rm -rf "$project_dir/node_modules" \
           "$project_dir/.yarn" \
           "$project_dir/package.json" \
           "$project_dir/tsconfig.json" \
           "$project_dir/.yarnrc.yml" \
           "$project_dir/artifacts" 2>/dev/null || true
    # Keep yarn.lock empty
    > "$project_dir/yarn.lock"
}

# Determine which examples to run
# Note: bob_token_contract and other custom contract examples require verification keys
# which aren't generated during docs compilation, so they're not included by default
if [ $# -eq 0 ]; then
    EXAMPLES=("aztecjs_connection" "aztecjs_getting_started" "aztecjs_advanced" "aztecjs_authwit" "aztecjs_testing")
else
    EXAMPLES=()
    for arg in "$@"; do
        case "$arg" in
            connection)      EXAMPLES+=("aztecjs_connection") ;;
            getting_started) EXAMPLES+=("aztecjs_getting_started") ;;
            advanced)        EXAMPLES+=("aztecjs_advanced") ;;
            authwit)         EXAMPLES+=("aztecjs_authwit") ;;
            testing)         EXAMPLES+=("aztecjs_testing") ;;
            *)
                if [ -d "$EXAMPLES_DIR/aztecjs_$arg" ]; then
                    EXAMPLES+=("aztecjs_$arg")
                elif [ -d "$EXAMPLES_DIR/$arg" ]; then
                    EXAMPLES+=("$arg")
                else
                    echo -e "${RED}Unknown example: $arg${NC}"
                    exit 1
                fi
                ;;
        esac
    done
fi

echo "Running ${#EXAMPLES[@]} example(s): ${EXAMPLES[*]}"
echo ""

# Track results
PASSED=0
FAILED=0
FAILED_EXAMPLES=()

# Setup all projects first
echo -e "${YELLOW}Setting up projects...${NC}"
for example in "${EXAMPLES[@]}"; do
    setup_project "$example"
done
echo ""

# Run all projects
for example in "${EXAMPLES[@]}"; do
    if run_project "$example"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_EXAMPLES+=("$example")
    fi
done

# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up...${NC}"
for example in "${EXAMPLES[@]}"; do
    cleanup_project "$example"
done

# Summary
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                           SUMMARY                              ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Passed: ${GREEN}$PASSED${NC}"
echo -e "  Failed: ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed examples:${NC}"
    for ex in "${FAILED_EXAMPLES[@]}"; do
        echo -e "  - $ex"
    done
    echo ""
    exit 1
else
    echo -e "${GREEN}✅ All examples passed!${NC}"
    echo ""
    exit 0
fi
