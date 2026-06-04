# Keyed multi-pool descriptor cache

> **Local patch, not upstream protobuf.** It lives on the `*-bc` branches (e.g. `35.0-bc`)
> as a patch on top of the synced upstream source. See
> [Maintenance across syncs](#maintenance-across-syncs) — it must be re-applied after every
> upstream sync.

## Why this exists

When `protobuf.keep_descriptor_pool_after_request=1`, the extension builds the descriptor
pool once and reuses it across requests instead of rebuilding it each time. Upstream's
persistence keeps **exactly one** descriptor pool alive per worker.

That single shared pool is unsafe when one long-lived worker serves requests for more than
one application version, and those versions ship **conflicting proto definitions** — the
same PHP class name and the same internal `.proto` filename but different fields. Pools key
their files by name, so the second version's file collides with the first's; whichever
loaded first wins for the rest of the worker's life, and a request from the other version
then sees the wrong descriptor and fatals.

The pool boundary therefore has to be **per application version**, not global and not
per-file (splitting a version's files across pools breaks proto imports, which resolve
within a single pool).

## What the patch does

It adds an opt-in, keyed persistence mode and leaves the existing unkeyed behavior
unchanged. Two INI settings (both `PHP_INI_ALL`):

| INI                                           | Default | Purpose                                                     |
|-----------------------------------------------|---------|-------------------------------------------------------------|
| `protobuf.keep_descriptor_pool_after_request` | `0`     | Existing upstream flag: persist the pool across requests.   |
| `protobuf.descriptor_pool_key`                | `""`    | **New.** Non-empty → keyed multi-pool mode for this request.|

Behavior when a non-empty key is set and persistence is on:

- **Same key** (across any number of requests/versions) → those requests share one pool,
  built once and reused.
- **Different keys** → independent pools that coexist in the same worker, so conflicting
  proto definitions never collide.
- **Empty key** → identical to upstream; single-version deployments are unaffected.

The key only takes effect when persistence is on: keyed mode requires
`keep_descriptor_pool_after_request=1`. If a key is set while persistence is off, the key is
**ignored** and the request runs the unkeyed upstream path (a keyed pool would have nothing
to persist into across requests). Both gates must agree — engaging the keyed cache on the key
alone, without persistence, leaves a freed pool referenced by the cache on the next same-key
request (a use-after-free; INFRA-25160).

## Enabling it

The key is delivered per request via a per-version **`.user.ini`** in the document root
(PHP scans `.user.ini` from the script dir up to `DOCUMENT_ROOT`):

```ini
; <docroot>/.user.ini
protobuf.keep_descriptor_pool_after_request = 1
protobuf.descriptor_pool_key = <key>
```

Because the setting is `PHP_INI_ALL`, `.user.ini` is applied during request startup before
the extension initializes the request, so keyed mode engages for that request. A
`fastcgi_param PHP_VALUE` set at the web server is an equivalent alternative and avoids the
`.user.ini` directory scan.

### Choosing a key

Use a **stable identifier that changes only when the proto definitions might change** —
for example a hash derived from the application's dependency lockfile, computed at
build/deploy time. Versions that resolve to the same identifier share one pool, which keeps
the number of live pools (and rebuilds) low.

### `user_ini.cache_ttl`

If a deployment's `.user.ini` never changes once shipped, set a long `user_ini.cache_ttl`
so each directory pays the `.user.ini` scan at most once per worker lifetime rather than
every 5 minutes (the default).

## Building & packaging

Standard `phpize` → `configure` → `make install`, built from the extension directory
(`src/php/ext/google/protobuf/`). `config.m4` expects `third_party/utf8_range` co-located
under that directory; the mirror's `post-extract` hook (`.pie-mirror.json`) already copies
it there and commits it, so no relocation is needed at build time.

The Debian package is built with fpm-cookery, sourcing this repo by **immutable git tag**
(e.g. `v35.0-bc.0`) rather than from PECL. PIE was considered and rejected for packaging:
it installs a built extension into a live PHP environment, whereas fpm-cookery needs a
`make install INSTALL_ROOT=<destdir>` staging step to assemble a relocatable `.deb`.

## Testing

`tests/integration/` is a self-contained docker stack (one pinned PHP-FPM worker + nginx)
that asserts the behaviors above against the extension built from this repo, including the
key-ignored-when-`keep=0` case. See [`tests/integration/README.md`](../tests/integration/README.md).

`tests/uaf/` is a lighter-weight, dedicated guard for the use-after-free above: it builds the
extension and drives the keyed pool across requests under `MALLOC_PERTURB_`, which poisons
freed memory so a dangling-pool reuse fails deterministically. (AddressSanitizer is not usable
here — PHP `dlopen`s extensions with `RTLD_DEEPBIND`, which the ASan runtime rejects.)

CI runs both on `*-bc` branches via `.github/workflows/integration.yml`.

## Maintenance across syncs

An upstream sync **overwrites `src/`**, and the patch lives inside the extension source, so
a sync wipes it. The workflow:

1. `main` tracks pristine upstream (populated by the sync).
2. Each `<version>-bc` branch = the matching sync commit **plus** the patch.
3. On a new upstream release: sync `main`, re-apply/rebase the patch to produce the next
   `<version>-bc` branch, cut a new tag (`v<version>-bc.N`), and point the package recipe
   at that tag.

The patch lives only on the `*-bc` branches.
