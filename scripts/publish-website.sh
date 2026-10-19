#!/usr/bin/env bash
#
# publish-website.sh — push the freshly generated release.ts to the website repo
# so GitHub Pages rebuilds the download links automatically.
#
# This is the "auto link update" half of the pipeline. The docker release job
# runs it after the ISO is published to R2:
#
#   1. Reads the generated release.ts (from publish-iso.sh, in the project root).
#   2. Clones the website repo to a temp dir.
#   3. Overwrites src/lib/release.ts and commits + pushes to main.
#   4. The website's GitHub Pages workflow reacts to the main push and deploys.
#
# The deployed site itself still makes zero network calls — the new links are
# baked into the static build.
#
# Auth (pick one):
#   - Recommended for unattended/CI releases: a GitHub **fine-grained personal
#     access token** scoped to the website repo with "Contents: Read and write":
#         GitHub > Settings > Developer settings > Fine-grained tokens.
#     Put it in release.env:
#         WEBSITE_DEPLOY_TOKEN="github_pat_..."
#         WEBSITE_REPO="https://github.com/aelum-dev/website.git"
#   - No PAT? The script falls back to the logged-in `gh` CLI token (the one `gh`
#     itself uses to push), so a local release works with just `gh auth login`.
#   - Neither? It falls back to pushing over SSH (your SSH key must be on GitHub).
#
# Usage:
#   scripts/publish-website.sh            # uses ./release.ts in the project root
#   RELEASE_TS=/tmp/x/release.sh scripts/publish-website.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local secrets (gitignored) if present, so `make release-website` works
# standalone the same way it does through release.sh.
if [ -f "$ROOT_DIR/release.env" ]; then
    set -a; . "$ROOT_DIR/release.env"; set +a
fi

WEBSITE_REPO="${WEBSITE_REPO:-https://github.com/aelum-dev/website.git}"
RELEASE_TS="${RELEASE_TS:-$ROOT_DIR/release.ts}"
BRANCH="${WEBSITE_BRANCH:-main}"
# Auth username for the HTTPS remote. GitHub ignores the username for token
# auth, but 'x-access-token' is the conventional value. Override via
# WEBSITE_TOKEN_USER if your token requires a real username.
WEBSITE_TOKEN_USER="${WEBSITE_TOKEN_USER:-x-access-token}"
# Identity for the generated commit. The throwaway clone has no local git
# identity, so without this the commit would inherit the machine's global
# identity instead of Aelum's.
GIT_NAME="${WEBSITE_GIT_NAME:-Aelum}"
GIT_EMAIL="${WEBSITE_GIT_EMAIL:-aelumdev@gmail.com}"

if [[ ! -f "$RELEASE_TS" ]]; then
  echo "ERROR: no generated release.ts at $RELEASE_TS (run scripts/publish-iso.sh first)." >&2
  exit 1
fi

# Auth: an explicit fine-grained PAT wins; otherwise reuse the logged-in gh CLI
# token; otherwise fall back to SSH. Either way the push writes to the website
# repo's main branch.
if [[ -n "${WEBSITE_DEPLOY_TOKEN:-}" ]]; then
  REMOTE="https://${WEBSITE_TOKEN_USER}:${WEBSITE_DEPLOY_TOKEN}@${WEBSITE_REPO#https://}"
elif command -v gh >/dev/null 2>&1 && _gh_token="$(gh auth token 2>/dev/null)" && [[ -n "$_gh_token" ]]; then
  echo "==> WEBSITE_DEPLOY_TOKEN not set; using the gh CLI login ($(gh api user -q .login 2>/dev/null || echo unknown))."
  REMOTE="https://${WEBSITE_TOKEN_USER}:${_gh_token}@${WEBSITE_REPO#https://}"
else
  # https://github.com/aelum-dev/website.git  ->  git@github.com:aelum-dev/website.git
  _host="${WEBSITE_REPO#https://}"; _host="${_host#http://}"
  REMOTE="git@${_host/\//:}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Cloning $WEBSITE_REPO ($BRANCH) via ${REMOTE%%:*}..."
git clone --depth 1 --branch "$BRANCH" "$REMOTE" "$WORK/site"
cd "$WORK/site"

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

git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
  commit -m "chore: update download links to v${VERSION}" >/dev/null
echo "==> Pushing to $BRANCH..."
git push origin "$BRANCH"
echo "==> Done. GitHub Pages will rebuild with the new links."
