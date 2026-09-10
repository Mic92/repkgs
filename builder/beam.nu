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
  write-launcher $name (tool escript) [$"($c.out)/lib/escript/($name)"]
}
