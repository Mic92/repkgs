# CPython itself, the interpreter package. The python *build system* module is what builds wheels.
{
  package,
  pkgs,
  platform,
  buildPkgs,
  on,
}:
package {
  name = "cpython314";
  uses = [ "autotools" ];
  autotools.flags = [
    "--without-ensurepip"
    "--with-openssl=${pkgs.openssl}"
    "--with-system-libmpdec"
    "ac_cv_file__dev_ptmx=yes"
    "ac_cv_file__dev_ptc=no"
  ]
  # cross: configure needs a same-version build-machine python and cannot run test programs
  ++ (
    if platform.cross then
      [
        "--with-build-python=python3" # by name: _sysconfigdata records CONFIG_ARGS
        "ac_cv_buggy_getaddrinfo=no"
      ]
    else
      [ ]
  );
  # no compiled-in PREFIX: an installed python is where its binary (/proc/self/exe, as macOS
  # asks the OS) or libpython is, a build tree one uses the source dir. sysconfig data and .pyc
  # paths relative, python-config from $0. LIBPL gets no copy of the build Makefile and
  # python-config.py (records of the build, nothing reads them)
  patches = [ ./relocatable.patch ];
  tests.run = false; # hours
  dependencies = [
    pkgs.zlib
    pkgs.xz
    pkgs.bzip2
    pkgs.libffi
    pkgs.openssl
    pkgs.expat
    pkgs.sqlite
    pkgs.mpdecimal
  ];
  buildDependencies = on platform.cross [ buildPkgs.cpython ];
  bin = [ "python3" ];
}
