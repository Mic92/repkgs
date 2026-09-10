# the Lua package manager, a build tool here (builder/systems/luarocks.nu, `uptrack lock`): pure Lua,
# its hand-written configure takes only --prefix and --with-lua. It unpacks .src.rock with unzip
# and would compile C modules with a literal `gcc`: the installed config says cc.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "luarocks";
  uses = [ "autotools" ];
  autotools.outOfTree = false;
  dependencies = [
    pkgs.lua
    pkgs.unzip
  ];
  buildDependencies = [ buildPkgs.unzip ];
  phases = [
    {
      name = "configure";
      run = "cd $c.src; x ./configure $\"--prefix=($c.out)\" $\"--with-lua=(dep-root lua 'luarocks runs on it')\"";
    }
    "autotools.build"
    "autotools.install"
    {
      name = "cc";
      run = "for f in (glob $\"($c.out)/etc/luarocks/config-*.lua\") { \"\\nvariables.CC = \\\"cc\\\"\\nvariables.LD = \\\"cc\\\"\\n\" | save -a $f }";
    }
  ];
  bin = [
    "luarocks"
    "luarocks-admin"
  ];
}
