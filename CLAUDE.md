# pie-extensions/EXTENSION_NAME

## What this repo is

This is a PIE-compatible mirror of UPSTREAM_OWNER/UPSTREAM_REPO. It does not contain original code — all source is automatically synced from the upstream repository.

## How syncing works

1. The `pie-extensions/core` repo runs a daily check for new upstream releases
2. When a new release is found, it dispatches `workflow_dispatch` to this repo's `.github/workflows/sync.yml`
3. The sync workflow uses `pie-extensions/mirror-action@v1` to:
   - Download the upstream release tarball
   - Extract source code to `src/`
   - Update `composer.json` version
   - Commit, tag, and push
   - Create a GitHub Release

## Key files

```
.pie-mirror.json                  # upstream config (repo, ext name, source dir)
composer.json                    # PIE-compatible package metadata
src/                             # upstream source code (populated by sync)
.github/workflows/sync.yml      # sync workflow triggered by core repo
```

## Manual sync trigger

To manually trigger a sync, go to:
Actions > Sync from upstream > Run workflow

Or via CLI:

```bash
gh workflow run sync.yml
```

## Initial sync

On first sync (when `composer.json` version is `0.0.0`), only the last 5 upstream releases are synced. After that, all new releases are synced as they appear.

## BigCommerce modifications

The `*-bc` branches (e.g. `35.0-bc`) carry a local patch — the **keyed multi-pool
descriptor cache** (INFRA-25160) — applied on top of the synced upstream source in
`src/php/ext/google/protobuf/protobuf.c`. Because a sync overwrites `src/`, the patch must
be re-applied after each upstream sync.

See [`docs/multi-pool-descriptor-cache.md`](docs/multi-pool-descriptor-cache.md) for the
what/why, production setup, packaging, and the cross-sync maintenance workflow.
