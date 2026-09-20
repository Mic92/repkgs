# also stands in for libgnurx/libregex on windows: <regex.h> and -lregex/-lgnurx over TRE's POSIX API
{
  package,
  platform,
  toolchain,
  on,
}:
package {
  name = "tre";
  uses = [ "autotools" ];
  patches = [
    ./upstream-llp64-align.patch
    ./upstream-mingw-wchar.patch
  ];
  autotools.flags = [
    "--disable-agrep"
    "--enable-static"
  ];
  # wretest hardcodes en_US.ISO-8859-1, our glibc only carries C.UTF-8
  phases.before."autotools.test" = on (platform.libc == "glibc" && !platform.cross) [
    {
      name = "latin1-locale";
      run = ''
        let sr = "${toolchain.sysroot}"
        mkdir locale
        # glibc's own tools keep the build-time interpreter path (pkgs/gl/glibc/bootstrap.nu runs them the same way)
        with-env { I18NPATH: $"($sr)/share/i18n" } {
          x $"($sr)/lib/${platform.interp}" --library-path $"($sr)/lib" $"($sr)/bin/localedef" --no-archive -i en_US -f ISO-8859-1 ./locale/en_US.ISO-8859-1
        }
        $env.LOCPATH = $"($env.PWD)/locale"
      '';
    }
  ];
  # mingw has no regex(3). Like MSYS2's libsystre: the POSIX names as real symbols forwarding to
  # tre_*, so `AC_CHECK_LIB(gnurx, regexec)` links, and a top-level regex.h
  phases.after."autotools.install" = on (platform.os == "windows") [
    {
      name = "system-regex";
      run = ''
        "#include <tre/regex.h>\n" | save $"($c.out)/include/regex.h"
        x cc -O2 $"-I($c.out)/include" -c ${./systre.c} -o systre.o
        # -lregex / -lgnurx: the four POSIX symbols plus all of libtre in one archive
        for n in [regex gnurx] {
          cp $"($c.out)/lib/libtre.a" $"($c.out)/lib/lib($n).a"
          x llvm-ar q $"($c.out)/lib/lib($n).a" systre.o
        }
      '';
    }
  ];
}
