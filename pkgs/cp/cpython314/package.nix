# CPython itself, the interpreter package. The python *build system* module is what builds wheels.
{
  package,
  pkgs,
  platform,
  buildPkgs,
}:
package {
  name = "cpython314";
  uses = [ "autotools" ];
  autotools.flags = [
    "--without-ensurepip"
    "--with-openssl=${pkgs.openssl}"
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
  tests.run = false; # hours
  dependencies = [
    pkgs.zlib
    pkgs.xz
    pkgs.bzip2
    pkgs.libffi
    pkgs.openssl
    pkgs.expat
    pkgs.sqlite
  ];
  buildDependencies = if platform.cross then [ buildPkgs.cpython ] else [ ];
  bin = [ "python3" ];
}
