# purl type → candidates {version date prerelease tag? url? sha256?}; each source fills what it
# knows, `versions` completes date/prerelease. All GETs go through http.nu's cache.

use version.nu *
use http.nu *

# all versions the purl's datasource lists
export def versions [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string, date: any, prerelease: bool> {
  match $p.type {
    github => (github $p)
    gitlab => (gitlab $p)
    pypi => (pypi $p)
    cargo => (crates $p)
    npm => (npm $p)
    hackage => (fetch $"https://hackage.haskell.org/package/($p.name)/preferred" $p.name | get normal-version | each {|v| {version: $v} })
    gnu => (listing $"https://ftp.gnu.org/gnu/($p.name)/" $p.name)
    generic => (generic $p)
    _ => (error make {msg: $"no datasource for purl type ($p.type)"})
  } | default false prerelease | default null date
    | update prerelease {|r| $r.prerelease or (version is-prerelease $r.version) }
    | where version =~ '^\d'
}

def fetch [url: string, what: string, --max-age: duration = 10min]: nothing -> oneof<string, list<any>, record> {
  let r = http cached $url --max-age $max_age
  if $r.status != 200 { error make {msg: $"($what): GET ($url) → ($r.status)"} }
  $r.body
}

# releases if the project publishes any, else tags
def github [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  let repo = $"https://api.github.com/repos/($p.namespace)/($p.name)"
  let rels = fetch $"($repo)/releases?per_page=20" $repo | where not draft | each {|r|
    {version: (version from-tag $r.tag_name), date: $r.published_at, prerelease: $r.prerelease, tag: $r.tag_name}
  }
  if ($rels | is-not-empty) { return $rels }
  fetch $"($repo)/tags?per_page=100" $repo | each {|t| {version: (version from-tag $t.name), tag: $t.name} }
}

# pkg:gitlab/<ns>/<name>[?repository_url=https://gitlab.example.org]
def gitlab [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  let host = ($p.qualifiers.repository_url? | default "https://gitlab.com")
  let id = ($"($p.namespace)/($p.name)" | url encode --all)
  fetch $"($host)/api/v4/projects/($id)/repository/tags?per_page=100" $p.name | each {|t| {version: (version from-tag $t.name), date: $t.commit?.created_at?, tag: $t.name} }
}

def pypi [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  fetch $"https://pypi.org/pypi/($p.name)/json" $p.name | get releases | items {|v, files|
    let files = $files | where not yanked
    let sdist = $files | where packagetype == sdist | get -o 0
    if ($files | is-not-empty) { {version: $v, date: $files.0.upload_time_iso_8601, url: $sdist.url?, sha256: $sdist.digests?.sha256?} }
  } | compact
}

def crates [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  fetch $"https://crates.io/api/v1/crates/($p.name)/versions" $p.name | get versions | where not yanked | each {|v| {version: $v.num, date: $v.created_at} }
}

def npm [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  let name = [$p.namespace $p.name] | where $it != '' | str join '/'
  let doc = fetch $"https://registry.npmjs.org/($name | str replace '/' '%2f')" $name
  $doc.versions | columns | each {|v| {version: $v, date: ($doc.time | get -o $v)} }
}

# a directory index or download page: <name>-<version>.tar.* links, date from the same line if any
def listing [url: string, name: string, --regex: oneof<string, nothing>]: nothing -> table<version: string> {
  let re = ($regex | default ('(?:^|[/">])' + $name + '-(\d[0-9a-z.]*?)\.(?:tar\.(?:xz|lz|bz2|gz|zst)|zip|tgz)'))
  fetch $url $name --max-age 6hr | to text | lines | each {|l|
    let m = $l | parse -r $re
    if ($m | is-not-empty) { {version: $m.0.capture0, date: ($l | parse -r '(\d{4}-\d{2}-\d{2})' | get -o 0.capture0)} }
  } | compact | uniq-by version
}

# pkg:generic/<name>?url=…[&regex=…]
def generic [p: record<type: string, namespace: string, name: string, qualifiers: record>]: nothing -> table<version: string> {
  if $p.qualifiers.url? == null { error make {msg: $"pkg:generic/($p.name) needs ?url="} }
  listing $p.qualifiers.url $p.name --regex $p.qualifiers.regex?
}
