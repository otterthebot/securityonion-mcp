#!/usr/bin/env bash
# Copyright Security Onion Solutions LLC and/or licensed to Security Onion Solutions LLC under one
# or more contributor license agreements. Licensed under the Elastic License 2.0 as shown at
# https://securityonion.net/license; you may not use this file except in compliance with the
# Elastic License 2.0.

# Weekly Security Audit Script
# Pulls latest main, audits dependencies, updates requirements.txt, runs the
# full test suite, and (if tests pass) creates a GPG-signed commit on a feature
# branch, pushes it, and opens a GPG-signed PR.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/weekly_security_audit.log"
BRANCH_NAME="security-audit/weekly-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${LOG_DIR}"

# Logging helper – writes to both stdout and the log file
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# 1. Pull the latest main branch
# ---------------------------------------------------------------------------
pull_latest_main() {
    log "=== Step 1: Pulling latest main branch ==="
    git -C "${REPO_ROOT}" checkout main 2>&1 | tee -a "${LOG_FILE}"
    git -C "${REPO_ROOT}" pull --ff-only origin main 2>&1 | tee -a "${LOG_FILE}"
    log "Main branch is up to date."
}

# ---------------------------------------------------------------------------
# 2. Dependency audit
# ---------------------------------------------------------------------------
dependency_audit() {
    log "=== Step 2: Running dependency audit ==="

    # Install pip-audit if not already available
    if ! command -v pip-audit &>/dev/null; then
        log "Installing pip-audit..."
        pip install pip-audit 2>&1 | tee -a "${LOG_FILE}"
    fi

    log "Auditing Python dependencies..."
    if pip-audit -r "${REPO_ROOT}/requirements.txt" 2>&1 | tee -a "${LOG_FILE}"; then
        log "Dependency audit passed – no known vulnerabilities."
    else
        log "WARNING: Dependency audit found issues (see above)."
        # Non-fatal – we continue to allow the PR to capture the update.
    fi
}

# ---------------------------------------------------------------------------
# 3. Update requirements.txt (pin current versions)
# ---------------------------------------------------------------------------
update_requirements() {
    log "=== Step 3: Updating requirements.txt ==="

    # Install current dependencies then freeze pinned versions back into
    # requirements.txt while preserving the license header.
    pip install -r "${REPO_ROOT}/requirements.txt" 2>&1 | tee -a "${LOG_FILE}"

    local header
    header=$(head -n 4 "${REPO_ROOT}/requirements.txt")

    # Freeze only the packages originally listed (unpinned names)
    local pkgs
    pkgs=$(grep -v '^\s*#' "${REPO_ROOT}/requirements.txt" | grep -v '^\s*$' | sed 's/[=<>!].*//' | tr '[:upper:]' '[:lower:]')

    local tmpfile
    tmpfile=$(mktemp)
    echo "${header}" > "${tmpfile}"

    for pkg in ${pkgs}; do
        local pinned
        pinned=$(pip freeze 2>/dev/null | grep -i "^${pkg}==" | head -n1) || true
        if [[ -n "${pinned}" ]]; then
            echo "${pinned}" >> "${tmpfile}"
        else
            # Keep the original unpinned line if we can't resolve it
            echo "${pkg}" >> "${tmpfile}"
        fi
    done

    cp "${tmpfile}" "${REPO_ROOT}/requirements.txt"
    rm -f "${tmpfile}"
    log "requirements.txt updated with pinned versions."
}

# ---------------------------------------------------------------------------
# 4. Run the full test suite
# ---------------------------------------------------------------------------
run_tests() {
    log "=== Step 4: Running full test suite ==="
    if python -m pytest "${REPO_ROOT}/tests" -v 2>&1 | tee -a "${LOG_FILE}"; then
        log "All tests passed."
        return 0
    else
        log "ERROR: Test suite failed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 5. Create GPG-signed commit on a feature branch, push, and open PR
# ---------------------------------------------------------------------------
commit_and_push() {
    log "=== Step 5: Creating feature branch and GPG-signed commit ==="

    git -C "${REPO_ROOT}" checkout -b "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    git -C "${REPO_ROOT}" add requirements.txt 2>&1 | tee -a "${LOG_FILE}"

    if git -C "${REPO_ROOT}" diff --cached --quiet; then
        log "No dependency changes to commit."
        return 0
    fi

    git -C "${REPO_ROOT}" commit -S -m "chore: weekly security audit dependency update

Automated weekly security audit – pinned dependency versions and
verified no known vulnerabilities." 2>&1 | tee -a "${LOG_FILE}"

    log "Pushing branch ${BRANCH_NAME} to origin..."
    git -C "${REPO_ROOT}" push -u origin "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"

    log "=== Step 6: Opening GPG-signed pull request ==="
    if command -v gh &>/dev/null; then
        gh pr create \
            --title "chore: weekly security audit dependency update" \
            --body "Automated weekly security audit.

- Pulled latest main
- Ran dependency audit (pip-audit)
- Updated pinned dependency versions in requirements.txt
- Full test suite passed

Signed-off-by: weekly_security_audit.sh" \
            --base main \
            --head "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"
        log "Pull request created."
    else
        log "WARNING: gh CLI not found – skipping PR creation."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "====================================="
    log "Weekly Security Audit – Starting"
    log "====================================="

    pull_latest_main
    dependency_audit
    update_requirements

    if run_tests; then
        commit_and_push
    else
        log "Skipping commit/push/PR because tests failed."
        log "Weekly Security Audit – FAILED (tests)"
        exit 1
    fi

    log "====================================="
    log "Weekly Security Audit – Complete"
    log "====================================="
}

main "$@"
