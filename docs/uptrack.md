# uptrack

The update tool for this tree and others. Designed after reading nixpkgs-update, nix-update,
llm-agents.nix's updater, Renovate, and the distro tools (Debian uscan, Fedora Anitya, Arch
nvchecker, Homebrew livecheck, Guix refresh).

## Lessons taken

- Machine-written state lives in a data file next to the package and Nix only reads it
  (llm-agents). Never edit Nix source (nixpkgs-update's regex rewriters and skip lists are the
  cost of doing so).
- Where versions come from is inferred from the source identity, configuration is the exception
  (nix-update, livecheck, guix refresh).
- Separate "list releases" from "compare versions" (Renovate's datasource and versioning axes).
  Renovate's third axis, file managers, is unnecessary when we own the metadata format.
- Keep a persistent dashboard and libyear, not only PRs (Renovate). Put build evidence in the PR
  (nixpkgs-update). Use OSV by purl for advisories instead of NVD/CPE guessing. Treat Repology as
  a second opinion, not the driver.
- Dynamic derivations already removed vendor hashes, so nothing of nixpkgs-update's fake-hash
  rebuilds or nix-update's `cargoHash` handling is needed.
- Some packages need code. In llm-agents 34 of 186 have an `update.py` (median 80 lines) for
  reasons no schema covers: APT indexes with GPG, a second pin read from inside the new source,
  lock files below the root, lockfile surgery. Code must be a first-class part of the pipeline.
- At scale the expensive part is polling. It must be one batched, cached pass that never runs
  per-package code.

## Metadata: `sources.toml`

One file per package. Humans write `[upstream]`, `[[source]].url`, `[watch]`, `[locks]`. The
tool writes `hash` and `[pin]`. Nix reads it with `fromTOML`.

```toml
[upstream]
purl = "pkg:github/sharkdp/fd"     # identity; picks datasource and default versioning
# versioning = "semver"|"pep440"|"calver"|"loose"   allow = ">=10,<11"
# prerelease = false   every = "30d" (minimum release age)   group = "llvm"
# cpe = "cpe:2.3:a:haxx:curl"      only for NVD lookups where OSV has no coverage (C projects)
# frozen = "last release 2009"     instead of purl: dead upstream, never polled
# relocks = ["hackage"]            applying this package re-solves every [locks] of that ecosystem

[[source]]
key = "default"                    # free-form: default, x86_64-linux, docs…
url = "https://github.com/sharkdp/fd/archive/refs/tags/v{version}.tar.gz"  # the canonical one, nix/mirrors.nix adds fallbacks by prefix
hash = "sha256-…"                  # tool; NAR hash of the unpacked tree (--strip-components 1), fetch+unpack is one FOD
# unpack = false                   # keep the file as is (single files); hash is then the flat sha256

[pin]                              # tool
version = "10.5.0"
date = "2025-05-18"                # release date: libyear, `every`
# file = "25.0.4.1_1"              # anything else a resolve hook returned. Every key here is a {key} in urls

[watch]                            # optional; default is the purl's datasource
# url = "…/LATEST"  regex = "([0-9.]+)"   |  feed = "…/releases.atom"  |  purl = "pkg:npm/x"

[locks]                            # dependency hashes to record in the repo-wide locks/<eco>.toml
# go = "."                         # dir in the source holding go.sum (`uptrack lock`, and on apply)
```

`package.nix` keeps behaviour only:

```nix
{ package, fetch, sources, ... }:
package {
  name = "fd";
  inherit (sources) version;
  source = fetch.pinned sources "default";
  uses = [ "cargo" ];
  cargo.deps = fetch.cargoVendor { inherit source; };
}
```

TOML rather than JSON for comments and stable diffs. One file rather than attributes in Nix so
that listing a whole tree is a glob, and so the same file works in repos without Nix.

## Pipeline

```
discover → resolve → decide → apply → verify
```

**discover** globs `sources.toml`, validates (unknown keys are errors that list the known ones).

**resolve** is the only stage that talks to upstreams, and it only evaluates watches. Purls are
grouped by host: GitHub gets one GraphQL query per 100 repositories, registries their JSON
endpoints, `[watch] url` a conditional GET. The cache under `$XDG_CACHE_HOME/uptrack` keeps
etag, last-modified, body hash and last seen version per URL, so a 304 or an unchanged body means
"no change" without parsing. Per-host token buckets and `every`-aware polling keep it inside rate
limits. Output per package: current, candidate, changed. `uptrack check --all` on an unchanged
world is a few hundred 304s.

**decide** is pure: metadata + candidates + flags → a plan entry `{name, from, to, date, reason,
sources, locks:[{file, resolver, why}], pins, advisories, provenance}` or `{name, skip}`. The plan
JSON is the interface for CI, reviewers and LLMs. `apply` consumes it unchanged or edited.

**apply**, only for changed entries: substitute `{version}` into source URLs, prefetch with
`nix store prefetch-file`, write `hash` and `[pin]`, then the **lock** stage for packages with
`[locks]`: fetch the pinned source through the tree (`nix-build -A {name}.src`) and record what
the ecosystem's own lock cannot give Nix in a tree-wide table, `$UPTRACK_LOCKS/<eco>.toml`
(default `<root>/locks/`; another tree points `fetch.goModules { locks = ./its/go.toml; }` at its
own). Today that is `go`: go.sum's `h1:` is a dirhash, so `[go]` maps `module@version` to the
proxy's `.mod`/`.zip` sha256. `hackage` and `luarocks` are version sets: no upstream lock file at
all, so the table holds version and sha256 per package, solved by cabal resp. luarocks. The table is one sorted line per entry and `merge=union` in
.gitattributes, so parallel additions merge textually; `treefmt` re-normalises. Cargo and npm
locks carry file hashes already and need nothing. `uptrack lock [pkg…]` runs the stage alone.
Entries already matching `[pin]` are no-ops, so runs resume.

**verify** builds through a tree adapter (`nix-build -A {name}` here) and appends evidence to the
plan entry: the `version:` line our build prints, closure size delta, test result.

## Custom stages

Without an `update.nu` a package needs nothing beyond `sources.toml`: versions come from the
purl's datasource (github, gitlab, pypi, cargo, npm, hackage, gnu, `generic` with `?url=`, and
two vendor feeds: `visualstudio` for the VS release manifest, `applesdk` for the macOS software
update catalog), every `[[source]].url` gets `{version}` and the other `[pin]` keys substituted and prefetched, missing
lock files are detected and generated, verify builds it. That is the path for most packages.
`pkgs/xx/<name>/update.nu` exists only to replace a stage. It is a nu module exporting any of:

```nu
export def resolve [pkg: record]: nothing -> table                 # → [{version tag? date? prerelease url? sha256? …}], extra keys land in [pin]
export def files   [entry: record]: nothing -> record              # → {relative path: content}, written after the pin
export def verify  [entry: record]: nothing -> record              # → {verified log? ...} instead of nix-build
```

uptrack runs the hook in a fresh `nu` with `uptrack/src` on the module path (`use datasource.nu`,
`use http.nu`, `use version.nu` work), passes records as arguments and reads JSON from stdout;
stderr is shown. Hooks never write files themselves and only run after the watch fired, so the
skim stays cheap. Anything else exported is an error. `uptrack list` shows which stages a
package overrides. Examples: `pkgs/ll/llvm/update.nu` exports `files` to regenerate the per-cpu
compiler-rt source lists from the new tarball, `pkgs/ru/rust-bootstrap/update.nu` exports
`resolve` so the bootstrap compiler is the one rust's `src/stage0` names, not the newest.

## Reports

- `dashboard`: pending, held by `allow`, too young for `every`, failing verify, advisories.
  `sync-github` upserts it as one pinned issue plus a PR per entry or group, idempotent by branch
  name.
- `report --libyear | --stale 90d` from `[pin].date`.
- `report --advisories`: OSV batch query by purl@version for current and candidate. purl and CPE
  do not map onto each other, so C projects without registry coverage add an optional `cpe`
  (vendor:product) for NVD's match API. The report flags packages where neither source knows the
  identity.
- `report --repology`: where other distros are ahead although our datasource says current. The
  fix is usually the purl.

## CLI

```
uptrack list [names]                     parse and validate every sources.toml
uptrack check [names] [--json]           poll upstreams, print pending updates and problems (exit 10 if pending)
uptrack apply [names] [--plan f]         write hash + [pin] (+ hook files, locks) for pending updates
uptrack verify [names]                   nix-build at the current pin
uptrack rehash [names]                   re-prefetch at the current pin, after editing a url
uptrack lock [names] [--prune]           fill locks/<eco>.toml for packages with [locks]
uptrack init <dir> <purl> <url-template> new sources.toml, pinned to upstream's newest
```

About 700 lines of nu in `pkgs/up/uptrack/src/`: purl, version comparison, datasources
(github, gitlab, pypi, crates, npm, hackage, gnu, generic listing), cached http, the pipeline,
locks (go, hackage, luarocks), CLI. Not built: advisory/libyear reports, grouped updates.
