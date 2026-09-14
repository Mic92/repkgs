{ package, platform }:
package {
  name = "lowdown";
  # oconfigure knows ELF and Mach-O shared libraries
  platforms.os = [
    "linux"
    "macos"
  ];
  uses = [ "make" ];
  patches = [ ./upstream-portable-make.patch ];
  # oconfigure takes KEY=value, not --prefix. seccomp probes the build machine's uname -m
  make.configureScript = "none";
  phases.before."make.build" = [
    {
      name = "oconfigure";
      run = ''
        "HAVE_SECCOMP_FILTER=0\nHAVE_SANDBOX_INIT=0\nHAVE_PLEDGE=0\n" | save configure.local
        # dash: it relies on echo expanding \n
        x sh ./configure $"PREFIX=($c.out)" $"MANDIR=($c.out)/share/man" LINK_METHOD=shared LINKER_SOSUFFIX=${
          if platform.os == "macos" then "dylib" else "so"
        }
        $env.LD_LIBRARY_PATH = $env.PWD # for regress
      '';
    }
  ];
  make.testTarget = [ "regress" ];
  make.installTarget = [
    "install"
    "install_shared"
  ];
  bin = [
    "lowdown"
    "lowdown-diff"
  ];
}
