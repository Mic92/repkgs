# mixed: python (maturin backend) + cargo in one tree
{
  package,
  buildPkgs,
}:
package {
  name = "rpds-py";
  uses = [
    "python"
    "cargo"
  ];
  python.backend = "maturin";
  python.module = "rpds";
  phases = [
    "python.build"
    "python.install"
    "python.test"
  ];
  buildDependencies = [ buildPkgs.maturin ];
}
