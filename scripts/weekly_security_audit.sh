#!/usr/bin/env bash
# Copyright Security Onion Solutions LLC and/or licensed to Security Onion Solutions LLC under one
# or more contributor license agreements. Licensed under the Elastic License 2.0 as shown at
# https://securityonion.net/license; you may not use this file except in compliance with the
# Elastic License 2.0.
#
# weekly_security_audit.sh — Idempotent weekly security audit script.
# Audits Python dependencies, updates vulnerable packages, runs tests,
# and opens a PR targeting main.

set -euo pipefail

###############################################################################
# Configuration
###############################################################################
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATE_STAMP="$(date +%Y-%m-%d)"
BRANCH_NAME="weekly-audit-${DATE_STAMP}"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/weekly_security_audit.log"
REQUIREMENTS_FILE="${REPO_ROOT}/requirements.txt"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"

###############################################################################
# Helpers
###############################################################################
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR: $*"
    exit 1
}

###############################################################################
# Setup — ensure log directory exists and rotate old logs (30-day retention)
###############################################################################
setup_logging() {
    mkdir -p "${LOG_DIR}"

    # Rotate logs older than 30 days
    find "${LOG_DIR}" -name "weekly_security_audit*.log" -type f -mtime +30 -delete 2>/dev/null || true

    # Start fresh log for this run
    echo "=== Weekly Security Audit — ${DATE_STAMP} ===" > "${LOG_FILE}"
}

###############################################################################
# Step 1 — Fetch latest main from upstream
###############################################################################
fetch_upstream() {
    log "Fetching latest ${TARGET_BRANCH} from ${UPSTREAM_REMOTE}..."
    git -C "${REPO_ROOT}" fetch "${UPSTREAM_REMOTE}" "${TARGET_BRANCH}" \
        || die "Failed to fetch ${UPSTREAM_REMOTE}/${TARGET_BRANCH}"
    log "Fetch complete."
}

###############################################################################
# Step 2 — Run dependency audit (pip-audit preferred, safety as fallback)
###############################################################################
run_dependency_audit() {
    log "Running dependency audit..."

    local audit_output
    audit_output=""
    local audit_exit=0

    if command -v pip-audit &>/dev/null; then
        log "Using pip-audit for dependency audit."
        audit_output="$(pip-audit -r "${REQUIREMENTS_FILE}" 2>&1)" || audit_exit=$?
    elif command -v safety &>/dev/null; then
        log "pip-audit not found; falling back to safety."
        audit_output="$(safety check -r "${REQUIREMENTS_FILE}" 2>&1)" || audit_exit=$?
    else
        die "Neither pip-audit nor safety is installed. Install one to continue."
    fi

    log "Audit output:"
    echo "${audit_output}" >> "${LOG_FILE}"

    if [ ${audit_exit} -ne 0 ]; then
        log "Vulnerabilities detected (exit code ${audit_exit}). Will attempt to update dependencies."
        return 1
    fi

    log "No vulnerabilities detected."
    return 0
}

###############################################################################
# Step 3 — Update vulnerable dependencies in requirements.txt
###############################################################################
update_dependencies() {
    log "Updating vulnerable dependencies..."

    # Install/upgrade all packages to their latest allowed versions
    pip install --upgrade -r "${REQUIREMENTS_FILE}" >> "${LOG_FILE}" 2>&1 \
        || die "pip install --upgrade failed."

    # Re-freeze only the packages already listed in requirements.txt,
    # preserving comments and adding version pins.
    local tmp_file
    tmp_file="$(mktemp)"
    local frozen
    frozen="$(pip freeze 2>/dev/null)"

    while IFS= read -r line; do
        # Preserve comment lines and blank lines
        if [[ "${line}" =~ ^[[:space:]]*# ]] || [[ -z "${line}" ]]; then
            echo "${line}" >> "${tmp_file}"
            continue
        fi

        # Extract the bare package name (strip any version specifiers)
        local pkg_name
        pkg_name="$(echo "${line}" | sed -E 's/[><=!~].*//' | xargs)"

        if [ -z "${pkg_name}" ]; then
            echo "${line}" >> "${tmp_file}"
            continue
        fi

        # Look up the installed version from pip freeze (case-insensitive)
        local frozen_line
        frozen_line="$(echo "${frozen}" | grep -i "^${pkg_name}==" | head -1)" || true

        if [ -n "${frozen_line}" ]; then
            echo "${frozen_line}" >> "${tmp_file}"
        else
            # Package not installed / not found — keep original line
            echo "${line}" >> "${tmp_file}"
        fi
    done < "${REQUIREMENTS_FILE}"

    mv "${tmp_file}" "${REQUIREMENTS_FILE}"
    log "Dependencies updated in ${REQUIREMENTS_FILE}."
}

###############################################################################
# Step 4 — Run test suite
###############################################################################
run_tests() {
    log "Running test suite with pytest..."

    if ! pytest "${REPO_ROOT}" >> "${LOG_FILE}" 2>&1; then
        die "Test suite failed. Aborting — no changes will be committed."
    fi

    log "All tests passed."
}

###############################################################################
# Step 5 — Commit changes on a new feature branch
###############################################################################
commit_changes() {
    log "Preparing commit on branch ${BRANCH_NAME}..."

    cd "${REPO_ROOT}"

    # If the branch already exists (idempotent re-run), reset it
    if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
        git checkout "${BRANCH_NAME}"
        git reset --hard "${UPSTREAM_REMOTE}/${TARGET_BRANCH}"
    else
        git checkout -b "${BRANCH_NAME}" "${UPSTREAM_REMOTE}/${TARGET_BRANCH}"
    fi

    git add "${REQUIREMENTS_FILE}"

    # Only commit if there are staged changes
    if git diff --cached --quiet; then
        log "No dependency changes to commit."
        return 1
    fi

    git commit -S -m "chore: update vulnerable dependencies (${DATE_STAMP})

Automated weekly security audit. Updated pinned versions in
requirements.txt to address known vulnerabilities." \
        || die "Failed to create signed commit."

    log "Changes committed on ${BRANCH_NAME}."
}

###############################################################################
# Step 6 — Push branch and open a GPG-signed pull request
###############################################################################
push_and_open_pr() {
    log "Pushing branch ${BRANCH_NAME} to origin..."

    git push -u origin "${BRANCH_NAME}" --force-with-lease >> "${LOG_FILE}" 2>&1 \
        || die "Failed to push branch."

    log "Branch pushed. Opening pull request..."

    # Check if a PR already exists for this branch (idempotent)
    local existing_pr
    existing_pr="$(gh pr list --head "${BRANCH_NAME}" --state open --json number --jq '.[0].number' 2>/dev/null)" || true

    if [ -n "${existing_pr}" ]; then
        log "PR #${existing_pr} already exists for ${BRANCH_NAME}. Skipping PR creation."
        return 0
    fi

    gh pr create \
        --title "chore: weekly security audit (${DATE_STAMP})" \
        --body "## Summary
- Automated weekly dependency security audit.
- Updated pinned versions in \`requirements.txt\` to address known vulnerabilities.
- All tests pass.

## Audit Log
See \`logs/weekly_security_audit.log\` for full details." \
        --base "${TARGET_BRANCH}" \
        --head "${BRANCH_NAME}" \
        >> "${LOG_FILE}" 2>&1 \
        || die "Failed to create pull request."

    log "Pull request created successfully."
}

###############################################################################
# Main
###############################################################################
main() {
    setup_logging
    log "Starting weekly security audit..."

    fetch_upstream

    local vulnerabilities_found=false
    if ! run_dependency_audit; then
        vulnerabilities_found=true
    fi

    if [ "${vulnerabilities_found}" = true ]; then
        update_dependencies

        # Re-run audit to confirm fixes
        if ! run_dependency_audit; then
            log "WARNING: Some vulnerabilities may remain after update."
        fi

        run_tests
        if commit_changes; then
            push_and_open_pr
        fi
    else
        log "No vulnerabilities found. Nothing to update."
    fi

    log "Weekly security audit completed successfully."
}

main "$@"
