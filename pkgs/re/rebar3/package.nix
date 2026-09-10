# rebar3 bootstraps itself offline from its vendored dependencies into one escript
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "rebar3";
  buildDependencies = [ buildPkgs.erlang ];
  dependencies = [ pkgs.erlang ];
  phases = [
    {
      name = "bootstrap";
      run = ''
        use beam.nu
        with-env {HOME: $c.build, REBAR_OFFLINE: "1"} { x escript bootstrap }
        beam install-escript _build/prod/bin/rebar3
      '';
    }
  ];
  tests.relocated = true;
}
