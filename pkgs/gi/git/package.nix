# git without the perl, python and tcl parts (send-email, svn, p4, gitk, git-gui) and without
# gettext. `configure` only records prefix, compiler and library locations into config.mak.autogen.
# Its Rust part (libgitcore, no crate dependencies) builds with the upstream toolchain so git does
# not wait for llvm and rust. make runs cargo, "cargo" in uses only sets up its environment
{
  package,
  pkgs,
  buildPkgs,
  platform,
}:
package {
  name = "git";
  uses = [
    "autotools"
    "cargo"
  ];
  cargo.toolchain = buildPkgs.rust-bootstrap;
  cargo.deps = null;
  phases = [
    "autotools.configure"
    "autotools.build"
    "autotools.test"
    "autotools.install"
  ];
  autotools.outOfTree = false;
  autotools.flags = [
    "--with-curl"
    "--with-expat"
    "--with-libpcre2"
    "--without-tcltk"
  ];
  autotools.makeFlags = [
    "RUST_TARGET_DIR=$(CARGO_TARGET_DIR)/${platform.rustTriple}/release"
    "CURL_LDFLAGS=-lcurl" # asked of curl-config, which curl built with cmake does not install
    "NO_PERL=1"
    "PERL_PATH=" # NO_PERL still leaves /usr/bin/perl for t/Makefile's lints
    "NO_PYTHON=1"
    "NO_GETTEXT=1"
    "NO_INSTALL_HARDLINKS=1"
    "INSTALL_SYMLINKS=1"
  ];
  autotools.testTarget = [
    "-C"
    "t"
    "T=t0000-basic.sh"
  ]; # the full suite is an hour, one script proves harness and binary. t0001 checks --shared modes the sandbox umask distorts
  dependencies = [
    pkgs.zlib
    pkgs.curl
    pkgs.expat
    pkgs.pcre2
    pkgs.openssl
  ];
  tests.relocated = true;
}
