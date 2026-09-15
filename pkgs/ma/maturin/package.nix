# PEP 517 backend for Rust extensions. Build tool only: no upload, sbom, completions, zig/xwin
{
  package,
}:
package {
  name = "maturin";
  uses = [ "cargo" ];
  cargo.noDefaultFeatures = true;
  phases.remove = [ "cargo.test" ];
  # the backend `python -m build` imports is the pure Python part, which then runs bin/maturin
  phases.after."cargo.install" = [
    {
      name = "backend";
      run = ''
        let sp = $"($c.out)/lib/python3/site-packages"
        mkdir $sp
        cp -r $"($c.src)/maturin" $sp
      '';
    }
  ];
}
