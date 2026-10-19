# Release — Aelum ISO → Cloudflare R2

How a release is published, and how to run it **from any machine/VM** without
ever baking your secrets into the code.

## Where each step runs

```
                 (your PC / any VM)
┌───────────────────────────────────────────────────────────────────┐
│  make build          → output/*.iso   (ISO is huge; stays local)    │
│  make release        → sign → upload to R2 → update website links   │
└───────────────────────────────────────────────────────────────────┘
```

There is **no CI release job**. Building the ISO produces a multi‑gigabyte file
GitHub Releases can't host, and the release needs your ISO + your keys — so the whole
release runs locally on your machine (or any VM you copy the scripts to).

## Why your keys are never leaked

- The release scripts **read every credential from the environment** — nothing is
  hardcoded in them.
- Your secret values live only in a local **`release.env`** file, which is
  **gitignored** (see `.gitignore`) and therefore never committed or pushed.
- The only thing tracked in git is `release.env.example`, a template with empty
  placeholders.

So the scripts are fully portable: copy them to any machine, supply your own
`release.env` there, and run `make release`. Your keys never touch the repo.

## Assets served publicly

The ISO and its sidecar files are published to the `aelum` Cloudflare **R2**
bucket with `public-read`. `cdn.aelum.dev` is CNAME'd to the bucket endpoint
(Cloudflare origin pull — **no Cloudflare Worker is involved**). Assets live at:

```
https://cdn.aelum.dev/<tag>/<filename>
https://cdn.aelum.dev/<tag>/<filename>.sha256|.sha512|.asc
https://cdn.aelum.dev/<tag>/aelum-release-key.asc
https://cdn.aelum.dev/aelum/latest.json        ← release manifest
```

## Setup (one time, on the machine that will run releases)

```bash
cp release.env.example release.env     # gitignored — never commit this file
$EDITOR release.env                    # fill in the values below
make release                           # release newest ISO in output/
```

Fill in `release.env`:

| Variable | Purpose |
|----------|---------|
| `R2_ACCOUNT_ID` | Cloudflare Account ID (top‑right of dashboard) |
| `R2_ACCESS_KEY` | R2 API token — Access Key ID (Object Read & Write on `aelum`) |
| `R2_SECRET_KEY` | R2 API token — Secret Access Key |
| `R2_PUBLIC_BASE` | CDN domain for asset URLs (optional; default `https://cdn.aelum.dev`) |
| `AELUM_GPG_KEY` | Release signing key id, or `Name <email>` |
| `AELUM_GPG_PRIVATE_KEY_B64` | base64 of the armored **private** key (for headless signing) |
| `GPG_PASSPHRASE` | Passphrase for the signing key |
| `WEBSITE_DEPLOY_TOKEN` | GitHub **fine-grained PAT** with `Contents: Read and write` on the website repo |
| `WEBSITE_REPO` | website repo URL (default `https://github.com/aelum-dev/website.git`) |
| `AELUM_SIGNING_UID` / `_FP` / `_FP_TOP` / `_FP_BOT` / `_EXPIRES` | Signing‑key metadata shown on the website (optional) |

## Running it

```bash
make release                 # release newest ISO in output/
make release VERSION=2026.10.4   # pin the tag
make release ISO=output/foo.iso   # release a specific ISO
```

This runs, in order:

1. `scripts/release-iso.sh` — sign + checksum the ISO (imports the private key
   from the env, signs headlessly, verifies everything, prints the asset list).
2. `scripts/publish-iso.sh` — upload the ISO + sidecars to R2 (`public-read`),
   build + upload `latest.json`, and generate the website's `release.ts`.
3. `scripts/publish-website.sh` — commit `release.ts` to the website repo's
   `main`; GitHub Pages rebuilds with the fresh links.

## Run from another machine / VM

Because nothing secret is in git, porting is just:

```bash
# on the new machine:
git clone <this docker repo>
cd docker
cp release.env.example release.env   # fill in YOUR keys
make build    # only needed here if you also want to (re)build the ISO
make release
```

Your `release.env` is the only machine‑specific file, and it is never committed.

## The scripts

| Script | What it does |
|--------|--------------|
| `scripts/release-iso.sh` | Picks the ISO, writes SHA‑256/SHA‑512 checksums, produces a detached ASCII‑armored GPG signature, exports the public key, and **verifies everything** before printing the asset list. Imports the private key from the env for headless signing. |
| `scripts/publish-iso.sh` | Uploads the ISO + sidecars to R2 (`public-read`), builds + uploads `latest.json`, and generates the website's `release.ts`. Builds a throwaway rclone config from the env — never touches your main `rclone.conf`. |
| `scripts/build-release-metadata.sh` | Turns the signed ISO into `latest.json` (R2 manifest) and `release.ts` (website module) from the same source of truth, so the two can't drift. |
| `scripts/publish-website.sh` | Clones the website repo, overwrites `src/lib/release.ts`, and pushes to `main` (via the fine-grained PAT, or an SSH key as a fallback). GitHub Pages rebuilds automatically. |

## Verifying (for users)

```bash
curl -O https://cdn.aelum.dev/<tag>/<filename>.iso
curl -O https://cdn.aelum.dev/<tag>/<filename>.iso.sha256
sha256sum -c <filename>.iso.sha256

gpg --import aelum-release-key.asc
gpg --verify <filename>.iso.asc <filename>.iso
```
