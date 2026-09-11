#!/usr/bin/env nu
# For cpus upstream ships no binaries for: cross build our own `<pkg>` from this machine, upload
# its store path as a nar to the GitHub release `bootstrap-<pkg>-<version>` and add a
# `<cpu>` source to pkgs/*/<pkg>-bootstrap/sources.toml. The riscv64 set then fetches it like an
# upstream tarball (fixed-output, no dependency on this machine's derivations).
#   tools/upload-bootstrap.nu go jdk [--cpus riscv64] [--repo Mic92/repkgs] [--store-path /nix/store/…]

def main [
  ...pkgs: string # package names whose output becomes <pkg>-bootstrap's source
  --cpus: string = "riscv64" # comma separated
  --repo: string = "Mic92/repkgs"
  --store-path: string # already built (on another machine, `nix copy`ed here): skip nix-build
]: nothing -> nothing {
  let root = ($env.CURRENT_FILE | path dirname | path dirname)
  for pkg in $pkgs {
    let toml = (glob $"($root)/pkgs/*/($pkg)-bootstrap/sources.toml" | first)
    let version = (^nix-instantiate --eval --strict --json $root -A $"($pkg).version" | from json)
    let tag = $"bootstrap-($pkg)-($version)"
    let built = ($cpus | split row "," | each {|cpu|
      print -e $"building ($pkg) ($version) for ($cpu)"
      let out = (if $store_path != null { $store_path } else { ^nix-build $root -A $pkg --argstr platform $"($cpu)-linux" --no-out-link | str trim })
      let file = $"($env.TMPDIR? | default /tmp)/($pkg)-($version)-($cpu)-linux.nar.xz"
      ^nix-store --dump $out | ^xz -T0 -9e | save -f --raw $file
      {cpu: $cpu, file: $file, hash: (^nix-store -q --hash $out | str trim | ^nix hash convert --hash-algo sha256 --to sri $in | str trim)}
    })
    if (^gh release view $tag -R $repo | complete).exit_code != 0 {
      ^gh release create $tag -R $repo --title $tag --notes $"($pkg) ($version) cross built by repkgs commit (^git -C $root rev-parse --short HEAD | str trim), for cpus upstream has no binaries for"
    }
    ^gh release upload $tag -R $repo --clobber ...($built | get file)
    let cur = (open $toml)
    let sources = ($built | each {|b| {
      key: $b.cpu
      url: $"https://github.com/($repo)/releases/download/bootstrap-($pkg)-{version}/($pkg)-{version}-($b.cpu)-linux.nar.xz"
      hash: $b.hash
      name: $pkg
    } })
    let kept = ($cur.source | where {|s| $s.key not-in ($built | get cpu) })
    $cur | update source ($kept ++ $sources) | to toml | save -f $toml
    print -e $"($tag): uploaded ($built | get cpu | str join ', '), wrote ($toml)"
  }
}
