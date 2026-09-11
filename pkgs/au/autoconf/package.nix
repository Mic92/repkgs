{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "autoconf";
  uses = [ "autotools" ];
  buildDependencies = [
    buildPkgs.m4
    buildPkgs.perl
  ];
  # autoconf, autom4te… are perl and sh scripts that exec m4. configure records whichever it finds
  # on PATH, the build machine's when cross: name the target's after install
  dependencies = [
    pkgs.m4
    pkgs.perl
    pkgs.bash
  ];
  phases = [
    "autotools.configure"
    "autotools.build"
    "autotools.install"
    {
      name = "retarget";
      run = ''
        let map = ([m4 perl bash] | each {|t| {from: (tool $t), to: $"(dep-root $t 'the scripts run it')/bin/($t)"} })
        for f in (glob $"($c.out)/bin/*") {
          edit $f {|| let t = $in; $map | reduce --fold $t {|m, acc| $acc | str replace -a $m.from $m.to } }
        }
      '';
    }
  ];
  tests.relocated = true;
  # 555/557 pass in 20 min. AS_DIRNAME and AC_FUNC_GETGROUPS probe host behaviour (toybox
  # dirname corner cases, no supplementary groups in the sandbox)
  tests.run = false;
}
