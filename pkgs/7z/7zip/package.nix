# 7zz, the one archiver that reads .msi (OLE compound files) and .cab: the windows-sdk assemble
# step unpacks Microsoft's installers with it
{ package }:
package {
  name = "7zip";
  phases = [
    {
      name = "build";
      run = ''
        cd CPP/7zip/Bundles/Alone2
        let arch = ({x86_64: "_x64", aarch64: "_arm64"} | get -o $c.platform.cpu | default "")
        x make $"-j($c.njobs)" -f $"../../cmpl_clang($arch).mak" CC=cc CXX=c++ DISABLE_RAR_COMPRESS=true USE_ASM= "CFLAGS_WARN_WALL=-Wall -Wextra" $"O=($c.build)"
        install-bins $c.build [7zz]
      '';
    }
  ];
  bin = [ "7zz" ];
  tests.version = "7zz --help";
}
