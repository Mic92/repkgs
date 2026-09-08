# The only `import <nixpkgs>` in the tree: tools that run on the build machine and are not packaged
# here yet, plus upstream source tarballs. Every attribute is a TODO for pkgs/<name>/package.nix.
# Rule: nothing that ends up *in* an output (libraries, headers, interpreters linked against) may
# come from here — only things that run during the build.
let
  nixpkgs = import <nixpkgs> { };
in
with nixpkgs;
{
  # build systems
  inherit nodejs;

  # qemu for cross tests, cacert and go for fetch.goModules
  inherit qemu-user cacert go;

}
