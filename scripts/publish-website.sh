#!/usr/bin/env bash
#
# publish-website.sh — push the freshly generated release.ts to the website repo
# so GitLab Pages rebuilds the download links automatically.
#
# This is the "auto link update" half of the pipeline. The docker release job
# runs it after the ISO is published to R2:
#
#   1. Reads the generated release.ts (from publish-iso.sh, in the project root).
#   2. Clones the website repo to a temp dir.
#   3. Overwrites src/lib/release.ts and commits + pushes to main.
#   4. The website's GitLab Pages CI reacts to the main push and deploys.
#
# The deployed site itself still makes zero network calls — the new links are
# baked into the static build.
#
# Setup (one time):
#   1. Create a GitLab **project access token** (Owner role) with
#      read_repository + write_repository on the website repo:
#         Settings > Access Tokens > Project Access Tokens.
#   2. Export it (or put it in release.env):
#          export WEBSITE_DEPLOY_TOKEN="glpat-..."
#          export WEBSITE_TOKEN_USER="gitlab+project-access-token"
#          export WEBSITE_REPO="https://gitlab.com/aelum/website.git"
#
# Usage:
#   scripts/publish-website.sh            # uses ./release.ts in the project root
#   RELEASE_TS=/tmp/x/release.sh scripts/publish-website.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBSITE_REPO="${WEBSITE_REPO:-https://gitlab.com/aelum/website.git}"
RELEASE_TS="${RELEASE_TS:-$ROOT_DIR/release.ts}"
BRANCH="${WEBSITE_BRANCH:-main}"
# Auth username for the GitLab remote. For a project access token this is
# literally 'gitlab+project-access-token' (the token authenticates as its own
# username, not 'oauth2'). Override per-token via WEBSITE_TOKEN_USER.
WEBSITE_TOKEN_USER="${WEBSITE_TOKEN_USER:-gitlab+project-access-token}"

if [[ ! -f "$RELEASE_TS" ]]; then
  echo "ERROR: no generated release.ts at $RELEASE_TS (run scripts/publish-iso.sh first)." >&2
  exit 1
fi

# Auth: prefer a GitLab project access token (read+write on the website repo),
# otherwise fall back to an SSH key (local dev). Either way the push writes to
# the website repo's main branch.
if [[ -n "${WEBSITE_DEPLOY_TOKEN:-}" ]]; then
  REMOTE="https://${WEBSITE_TOKEN_USER}:${WEBSITE_DEPLOY_TOKEN}@${WEBSITE_REPO#https://}"
else
  # https://gitlab.com/aelum/website.git  ->  git@gitlab.com:aelum/website.git
  _host="${WEBSITE_REPO#https://}"; _host="${_host#http://}"
  REMOTE="git@${_host/\//:}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cloning $WEBSITE_REPO ($BRANCH) via ${REMOTE%%:*}..."
git clone --depth 1 "$REMOTE" "$WORK/site"
cd "$WORK/site"

if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  git checkout "$BRANCH" || git fetch origin "$BRANCH" && git checkout -B "$BRANCH" origin "$BRANCH"
fi

VERSION="$(sed -n 's/.*version: "\(.*\)".*/\1/p' "$RELEASE_TS" | head -1)"
cp "$RELEASE_TS" "src/lib/release.ts"
git add src/lib/release.ts

# Only commit if the content actually changed vs HEAD. (Use --cached: release.ts
# is a new/untracked file, so a plain `git diff` would never see it.)
if git diff --cached --exit-code -- src/lib/release.ts >/dev/null 2>&1; then
  echo "==> release.ts identical to what's on $BRANCH — nothing to deploy."
  git reset -q HEAD -- src/lib/release.ts
  exit 0
fi

git commit -m "chore: update download links to v${VERSION}" >/dev/null
echo "==> Pushing to $BRANCH..."
git push origin "$BRANCH"
echo "==> Done. GitLab Pages will rebuild with the new links."
