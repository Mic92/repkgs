# perf from the kernel's tools/perf, with libelf and libdw from pkgs/el/elfutils, so symbols
# and DWARF work. libtraceevent is not packaged here, which takes `perf trace` and the
# tracepoint events with it; the BPF skeletons are off because they want bpftool.
#
# A separate pin from pkgs/li/linux, which takes the UAPI headers out of the same tarball. Both
# fetches are the same url and hash, so they are the same derivation and the tree is downloaded
# once.
{
  package,
  pkgs,
  buildPkgs,
  sources,
}:
package {
  name = "perf";
  inherit (sources) version;
  source = "default";
  # perf_event_open, and the build reads the running kernel's headers
  platforms.os = [ "linux" ];
  # the feature probes compile and run programs for the build machine
  platforms.cross = false;
  uses = [ "make" ];
  make.root = "tools/perf";
  dependencies = [
    pkgs.elfutils
    pkgs.zlib
    pkgs.zstd
    pkgs.libcap
    pkgs.numactl
  ];
  buildDependencies = [
    buildPkgs.flex
    buildPkgs.bison
    buildPkgs.perl # tools/build generates headers with it
  ];
  phases = [
    {
      name = "build";
      run = ''
        # command-line assignments, not env: several of the makefiles under tools/ set CC and
        # friends themselves, and only the command line beats that
        let flags = [
          # prefix=/ with DESTDIR, not prefix=$out: perf compiles its exec path and its config
          # path into the binary, and an output that names its own install prefix is not
          # relocatable (finish.nu refuses it). subcmd resolves a relative exec path against
          # that compiled-in prefix and has no runtime-prefix mechanism, so the helpers under
          # libexec/perf-core are installed but not found unless PERF_EXEC_PATH names them.
          # Every builtin subcommand, stat, record and report among them, ignores the path.
          "prefix=/"
          $"DESTDIR=($c.out)"
          # Makefile.config rebuilds CC as `$(CLANG) $(CLANG_FLAGS) -fintegrated-as` as soon as it
          # finds that CC is clang, and $(CLANG) defaults to a bare `clang` on PATH, which
          # carries none of the toolchain wrapper flags. Naming the wrapper here keeps them,
          # and --target comes back from `cc -print-target-triple`, so it matches.
          "CLANG=cc"
          "CC=cc"
          "CXX=c++"
          "LD=ld.lld"
          "AR=ar"
          "WERROR=0"
          "NO_LIBTRACEEVENT=1"
          "NO_LIBBPF=1" # the skeletons need bpftool, which is another kernel tool again
          "NO_JEVENTS=1"
          "NO_LIBPYTHON=1"
          "NO_LIBPERL=1"
          "NO_SLANG=1"
          "NO_GTK2=1"
          "NO_CAPSTONE=1"
          "NO_LIBLLVM=1"
          "NO_LIBPFM4=1"
          "NO_BABELTRACE2=1"
          "NO_LIBDEBUGINFOD=1"
          "NO_DEMANGLE=1"
          "NO_SDT=1"
          "NO_RUST=1"
        ]
        x make $"-j($c.njobs)" ...$flags
        # `install` also builds the man pages, which want asciidoc
        x make ...$flags install-bin
      '';
    }
  ];
  bin = [ "perf" ];
  # the suite wants a live kernel, root for most of it, and minutes
  tests.run = false;
  tests.version = "--version";
}
