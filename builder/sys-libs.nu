# Locked third-party packages that link a C library, per ecosystem: which package of ours provides
# it (`pkg`) and how the build is told to use it instead of a bundled copy (`env`, plus `tags` for
# go and `flags` for bundler; `{root}` stands for the library's store path).
#
# Decided when the package is pinned: uptrack looks the lock files of the tree it just hashed up
# here (`wanted`) and writes `sys = [..]` into [pin] of sources.toml, nix/package.nix makes those
# dependencies. At build time the build-system module applies `env-for`/`go-tags`/
# `gem-build-flags` for the libraries present and `check`s the lock still agrees with sys.
#
# Explicit on purpose: linking a system library is a decision. Packages that only ever vendor
# (ring, aws-lc-sys, modernc.org/sqlite) or are plain OS bindings have no entry.
# The tables are builder/sys-libs.json (nix/python.nix reads the python one too): per ecosystem,
# locked name -> {pkg, env, …}. python entries may lack `pkg` and carry `tools` (build programs
# by package name) and `configSettings` for the sdist build
const TABLES_FILE = path self ./sys-libs.json
export def tables []: nothing -> record { open $TABLES_FILE }

# --- lock side: uptrack writes [pin] sys, the build checks it --------------------------------------

const LOCKS = {cargo: Cargo.lock, go: go.sum, python: uv.lock, gems: Gemfile.lock}

# package names in a lock file
def locked [ecosystem: string, f: path]: nothing -> list<string> {
  match $ecosystem {
    "cargo" | "python" => { open --raw $f | from toml | get -o package | default [] | get name }
    "go" => { open --raw $f | lines | where $it != "" | split column " " path | get path }
    "gems" => { open --raw $f | lines | parse -r '^    (?<name>[A-Za-z0-9_.-]+) \(' | get name }
  }
}

# our packages the locked `names` of one ecosystem can link, sorted
export def wanted-for [ecosystem: string, names: list<string>]: nothing -> list<string> {
  (tables) | get $ecosystem | transpose locked entry | where locked in $names | each { $in.entry.pkg? } | compact | uniq | sort
}

# our packages the lock files in `dir` can link, sorted: what [pin] sys should say
export def wanted [dir: path]: nothing -> list<string> {
  $LOCKS | items {|eco, file|
    let f = ($dir | path join $file)
    if ($f | path exists) { wanted-for $eco (locked $eco $f) } else { [] }
  } | flatten | uniq | sort
}

# build time: the lock can link libraries [pin] sys does not name -> the pin is stale. null: no
# sources.toml, dependencies are by hand. (Names the set lacks on this platform are fine:
# nix/package.nix drops those and the locked package vendors)
export def check [dir: path, sys: any]: nothing -> nothing { check-names (wanted $dir) $sys rehash }

export def check-names [wanted: list<string>, sys: any, cmd: string]: nothing -> nothing {
  if $sys == null { return }
  let missing = ($wanted | where $it not-in $sys)
  if ($missing | is-not-empty) {
    error make {msg: $"sys-libs: the lock can link ($missing | str join ', '), missing from [pin] sys in sources.toml. `repkgs update ($cmd) <pkg>` rewrites it"}
  }
}

# python packages that build from sdist whenever they appear (fetch/pypi.nu)
export def sdist-packages []: nothing -> list<string> { (tables).python | transpose locked entry | where { $in.entry.pkg? != null } | get locked }

# --- builder side (cargo.nu, go.nu, bundler.nu, pyapp.nu): configure for the libraries present ----

# table entries of `ecosystem` whose library is among `deps` ({name, root, …} records from ctx),
# each with that dependency's root attached
def active [ecosystem: string, deps: list<record<name: string, root: string>>]: nothing -> table {
  let roots = ($deps | select name root | rename pkg root)
  (tables) | get $ecosystem | transpose locked entry | flatten entry | join $roots pkg
}

# env vars from the matching entries, {root} replaced by the library's store path
export def env-for [ecosystem: string, deps: list<record<name: string, root: string>>]: nothing -> record {
  active $ecosystem $deps
    | reduce --fold {} {|e, acc| $acc | merge ($e.env | items {|k, v| [$k ($v | str replace -a "{root}" $e.root)] } | into record) }
}

# go: build tags that switch a module to the system library
export def go-tags [deps: list<record<name: string, root: string>>]: nothing -> list<string> {
  active go $deps | each { $in.tags? | default [] } | flatten | uniq
}

# bundler: gem -> `bundle config build.<gem>` argument string
export def gem-build-flags [deps: list<record<name: string, root: string>>]: nothing -> record {
  active gems $deps | where { $in.flags | is-not-empty }
    | reduce --fold {} {|e, acc| $acc | upsert $e.locked ($e.flags | str replace -a "{root}" $e.root | str join " ") }
}
