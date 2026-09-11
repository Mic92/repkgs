# shared by the BEAM build systems (mix, rebar3)
use core.nu *

# a Hex tarball's contents.tar.gz into `dest`
export def unpack [tar: path, dest: path]: nothing -> nothing {
  mkdir $dest
  ^bsdtar -xOf $tar contents.tar.gz | ^bsdtar -xzf - -C $dest
}

# escript derives the module to call from the file name, so an escript cannot be renamed to
# bin/.<name> behind a launcher: it keeps its name under lib/escript/
export def install-escript [f: path]: nothing -> nothing {
  let c = (ctx)
  let name = ($f | path basename)
  mkdir $"($c.out)/lib/escript"
  cp $f $"($c.out)/lib/escript/($name)"
  # the target's escript (a dependency), not the one on PATH that ran the build
  write-launcher $name $"(dep-root erlang "escripts run under the target erlang")/bin/escript" [$"($c.out)/lib/escript/($name)"]
}
