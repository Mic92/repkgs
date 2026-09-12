# bundle drv: a package's output as one self-contained tree (builder/bundle.nu), for
# `repkgs bootstrap`. Nix supplies the closure and checks that no store reference is left.
{
  nu,
  tools,
  tree,
}:
drv:
derivation {
  name = "${drv.name}-bundle";
  inherit (drv) system;
  __structuredAttrs = true;
  __contentAddressed = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  builder = "${nu}/bin/nu";
  args = [
    "--no-config-file"
    "--include-path=${tree}"
    (builtins.path {
      path = tree + "/bundle.nu";
      name = "bundle.nu";
    })
  ];
  package = drv;
  exportReferencesGraph.closure = [ drv ];
  outputChecks.out.allowedReferences = [ ];
  PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") tools);
}
