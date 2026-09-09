#!/usr/bin/env nu
# Producer for fetch.yarnDeps { source, root? }: yarn.lock v1 (classic) gives every registry entry
# `resolved "<tarball url>#<sha1>"` and (yarn >= 1.10) `integrity <SRI>`, so each becomes a
# builtin:fetchurl fixed by that hash. Output is a yarn offline mirror: a flat directory of
# tarballs named the way `yarn install --offline` looks them up (the URL's basename, prefixed
# `@scope-` for scoped packages). yarn re-verifies each against the lock.
use dynamic.nu

# yarn.lock v1 -> [{keys, resolved, integrity}]. The format is yarn's own: unindented
# `"a@^1", b@2:` headers, two-space indented `field value` lines, values optionally quoted
def parse-lock [text: string]: nothing -> table {
  if ($text | str contains "__metadata:") { error make {msg: "yarnDeps: yarn.lock is yarn berry (v2+), only yarn classic v1 is supported"} }
  $text | lines | reduce --fold [] {|line, acc|
    if ($line | is-empty) or ($line starts-with "#") {
      $acc
    } else if not ($line starts-with " ") {
      $acc | append {keys: ($line | str trim -r -c ":"), resolved: null, integrity: null}
    } else {
      let kv = ($line | str trim | parse -r '^(?<k>\S+) "?(?<v>[^"]*)"?$')
      if ($kv | is-empty) or ($acc | is-empty) { return $acc }
      let k = $kv.0.k
      if $k in [resolved integrity] { $acc | update (($acc | length) - 1) { $in | update $k $kv.0.v } } else { $acc }
    }
  }
}

# the offline-mirror file name yarn derives from a tarball URL
def mirror-name [url: string]: nothing -> string {
  let path = ($url | url parse | get path)
  let base = ($path | path basename)
  let scope = ($path | parse -r '^/(?<s>@[^/]+)/' | get -o 0.s)
  if $scope == null { $base } else { $"($scope)-($base)" }
}

def main []: nothing -> nothing {
  let lock_file = ([$env.source $env.root yarn.lock] | path join)
  let entries = (parse-lock (open --raw $lock_file))
  # workspace / link: / file: entries have no `resolved`
  let remote = ($entries | where resolved != null)
  let foreign = ($remote | where { $in.resolved !~ '^https?://' or $in.resolved =~ '\.git(#|$)|/tarball/|codeload\.github\.com' })
  if ($foreign | is-not-empty) { error make {msg: $"yarnDeps: unsupported `resolved` \(git/github/file) for: ($foreign | get keys | str join ', ')"} }
  let unhashed = ($remote | where integrity == null)
  if ($unhashed | is-not-empty) { error make {msg: $"yarnDeps: no `integrity` \(yarn < 1.10 lock, run `yarn install` once with a current yarn 1.x) for: ($unhashed | get keys | str join ', ')"} }
  let fetched = ($remote | each {|e|
    let url = ($e.resolved | split row "#" | first)
    {url: $url, integrity: $e.integrity, file: (mirror-name $url)}
  } | uniq-by url | dynamic fetchurls)
  let layout = ($fetched | each {|f| {link: $f.out, to: $f.file} })
  dynamic collect yarn-deps $layout ($fetched | get drv)
}
