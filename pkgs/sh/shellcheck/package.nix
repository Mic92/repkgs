{ package }:
package {
  name = "shellcheck";
  uses = [ "cabal" ];
  cabal.exes = [ "shellcheck" ];
  # 0.11.0 caps aeson <2.3 and QuickCheck <2.17, the shared hackage set carries pandoc's newer ones
  cabal.project = "allow-newer: ShellCheck:aeson, ShellCheck:QuickCheck";
}
