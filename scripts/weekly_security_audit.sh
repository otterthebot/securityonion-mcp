#!/usr/bin/env bash
# Copyright Security Onion Solutions LLC and/or licensed to Security Onion Solutions LLC under one
# or more contributor license agreements. Licensed under the Elastic License 2.0 as shown at
# https://securityonion.net/license; you may not use this file except in compliance with the
# Elastic License 2.0.
#
# Weekly Security Audit Script
# Idempotent script that audits Python dependencies, updates requirements.txt,
# runs the test suite, and opens a PR if everything passes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/weekly_security_audit.log"
BRANCH_NAME="security-audit/weekly-$(date +%Y%m%d)"

mkdir -p "${LOG_DIR}"

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] $*" | tee -a "${LOG_FILE}"
}

cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        log "ERROR: Script exited with code ${exit_code}"
    fi
    exit ${exit_code}
}
trap cleanup EXIT

log "===== Starting weekly security audit ====="

cd "${REPO_ROOT}"

# ── Pull latest upstream main ────────────────────────────────────────────────
log "Fetching upstream main..."
git fetch upstream main 2>&1 | tee -a "${LOG_FILE}"
git checkout main 2>&1 | tee -a "${LOG_FILE}"
git merge upstream/main --ff-only 2>&1 | tee -a "${LOG_FILE}"

# ── Create or reset the audit branch (idempotent) ───────────────────────────
if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
    log "Branch ${BRANCH_NAME} already exists, resetting to main..."
    git checkout "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    git reset --hard main 2>&1 | tee -a "${LOG_FILE}"
else
    log "Creating branch ${BRANCH_NAME}..."
    git checkout -b "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"
fi

# ── Install audit tooling ───────────────────────────────────────────────────
log "Installing/upgrading audit tools..."
pip install --quiet --upgrade pip-audit safety 2>&1 | tee -a "${LOG_FILE}"

# ── Run pip-audit ────────────────────────────────────────────────────────────
log "Running pip-audit..."
AUDIT_EXIT=0
pip-audit -r requirements.txt --output "${LOG_DIR}/pip_audit_report.txt" 2>&1 | tee -a "${LOG_FILE}" || AUDIT_EXIT=$?

if [ ${AUDIT_EXIT} -ne 0 ]; then
    log "WARNING: pip-audit found vulnerabilities (exit code ${AUDIT_EXIT}). See ${LOG_DIR}/pip_audit_report.txt"
else
    log "pip-audit passed with no known vulnerabilities."
fi

# ── Run safety check (fallback / second opinion) ────────────────────────────
log "Running safety check..."
SAFETY_EXIT=0
safety check -r requirements.txt 2>&1 | tee -a "${LOG_FILE}" || SAFETY_EXIT=$?

if [ ${SAFETY_EXIT} -ne 0 ]; then
    log "WARNING: safety found vulnerabilities (exit code ${SAFETY_EXIT})."
else
    log "safety check passed."
fi

# ── Auto-fix: update vulnerable packages in requirements.txt ────────────────
log "Attempting to fix audit findings via pip-audit..."
pip-audit -r requirements.txt --fix --dry-run 2>&1 | tee -a "${LOG_FILE}" || true
pip-audit -r requirements.txt --fix 2>&1 | tee -a "${LOG_FILE}" || true

# ── Run full test suite ──────────────────────────────────────────────────────
log "Running full test suite..."
TEST_EXIT=0
python -m pytest --tb=short 2>&1 | tee -a "${LOG_FILE}" || TEST_EXIT=$?

if [ ${TEST_EXIT} -ne 0 ]; then
    log "ERROR: Test suite failed (exit code ${TEST_EXIT}). Aborting PR creation."
    exit 1
fi
log "All tests passed."

# ── Commit changes if any ───────────────────────────────────────────────────
if git diff --quiet && git diff --cached --quiet; then
    log "No changes to commit. Repository is already up to date."
    log "===== Weekly security audit complete (no changes) ====="
    exit 0
fi

log "Committing changes..."
git add requirements.txt 2>&1 | tee -a "${LOG_FILE}"
git commit -S -m "chore(security): weekly dependency audit $(date +%Y-%m-%d)

Automated weekly security audit run.
- Ran pip-audit and safety checks
- Updated vulnerable dependencies where possible
- All tests passing" 2>&1 | tee -a "${LOG_FILE}"

# ── Push feature branch ─────────────────────────────────────────────────────
log "Pushing branch ${BRANCH_NAME}..."
git push --force-with-lease origin "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"

# ── Open PR if one doesn't already exist ─────────────────────────────────────
EXISTING_PR=$(gh pr list --head "${BRANCH_NAME}" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

if [ -n "${EXISTING_PR}" ]; then
    log "PR #${EXISTING_PR} already exists for ${BRANCH_NAME}. Skipping PR creation."
else
    log "Opening GPG-signed pull request..."
    gh pr create \
        --title "chore(security): weekly dependency audit $(date +%Y-%m-%d)" \
        --body "## Weekly Security Audit

- Ran \`pip-audit\` and \`safety\` against \`requirements.txt\`
- Updated vulnerable dependencies where fixes were available
- Full test suite passing

_This PR was automatically generated by the weekly security audit script._" \
        --base main \
        --head "${BRANCH_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    log "Pull request created successfully."
fi

log "===== Weekly security audit complete ====="
