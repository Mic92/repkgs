# Unpack an archive into `dest` the way sources are stored: if everything sits under one top-level
# directory (tarballs, github zips) that directory becomes `dest`, otherwise (flat zips such as
# deno's releases) the entries land in `dest` as they are. nix/sources.nix runs this at build time (--fetch:
# download $env.url first, tools from $env.unpacker), uptrack's prefetch when it computes the hash.
def main [archive?: path, dest?: path, --fetch]: nothing -> nothing {
  if $fetch {
    http get --raw --redirect-mode follow --max-time 10min $env.url | save archive
    $env.PATH = [$"($env.unpacker)/bin"]
    unpack archive $env.out
  } else {
    unpack $archive $dest
  }
}

def unpack [archive: path, dest: path]: nothing -> nothing {
  let stage = $"($dest).unpack"
  mkdir $stage
  ^bsdtar -xf $archive -C $stage --no-same-owner --no-same-permissions
  ^chmod -R u+w,a-st $stage
  let top = (ls -a $stage)
  if ($top | length) == 1 and $top.0.type == dir {
    mv $top.0.name $dest
    rm -rf $stage
  } else {
    mv $stage $dest
  }
}
