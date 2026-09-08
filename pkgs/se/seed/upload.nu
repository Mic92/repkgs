#!/usr/bin/env nu
# Build the seed nar for each system, upload to the GitHub release `seed-<version>` and rewrite
# ./sources.toml. Version comes from build.nix's seed name (seed-<N>-<system>).
#   pkgs/se/seed/upload.nu [--systems x86_64-linux,aarch64-linux] [--repo Mic92/dotfiles]

def main [
  --systems: string = "x86_64-linux,aarch64-linux" # comma separated, others keep their sources.toml entry
  --repo: string = "Mic92/dotfiles" # GitHub repo holding the seed-<N> releases
]: nothing -> nothing {
  let here = ($env.CURRENT_FILE | path dirname)
  let toml = $"($here)/sources.toml"
  let built = ($systems | split row "," | each {|sys|
    print -e $"building seed nar for ($sys)"
    let out = (^nix-build $"($here)/build.nix" -A nar --argstr system $sys --no-out-link | str trim)
    let file = (ls $out | where name =~ '\.nar\.xz$' | first | get name)
    { sys: $sys, file: $file, hash: (open --raw $"($out)/nar-hash" | str trim),
      version: ($file | path basename | parse "seed-{v}-{rest}" | first | get v) }
  })
  let version = ($built | get version | uniq)
  if ($version | length) != 1 { error make {msg: $"systems disagree on seed version: ($version)"} }
  let tag = $"seed-($version | first)"

  if (^gh release view $tag -R $repo | complete).exit_code != 0 {
    ^gh release create $tag -R $repo --title $tag --notes $"pkgs bootstrap seed ($version | first), built by pkgs/se/seed/build.nix"
  }
  ^gh release upload $tag -R $repo --clobber ...($built | get file)

  let cur = (open $toml)
  let sources = ($built | each {|b| {
    key: $b.sys
    url: $"https://github.com/($repo)/releases/download/seed-{version}/seed-{version}-($b.sys).nar.xz"
    hash: $b.hash, unpack: true, name: "seed"
  } })
  # systems not rebuilt this run keep their old entry
  let kept = ($cur.source | where {|s| $s.key not-in ($built | get sys) })
  $cur | update source ($sources ++ $kept) | update pin { version: ($version | first) } | to toml | save -f $toml
  print -e $"($tag): uploaded ($built | get sys | str join ', '), wrote ($toml)"
}
