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
  # Git for Windows is a fork with its own compat layer, upstream configure needs socklen_t & co.
  platforms.posix = true;
  uses = [
    "autotools"
    "cargo"
  ];
  cargo.tool = buildPkgs.rust-bootstrap;
  cargo.deps = null;
  phases = { }; # autotools', cargo only sets up
  autotools.outOfTree = false;
  autotools.flags = [
    "--with-curl"
    "--with-expat"
    "--with-libpcre2"
    "--without-tcltk"
  ];
  # RUNTIME_PREFIX: exec path, templates, locale relative to the binary (configure made them
  # absolute), no compiled-in fallback prefix. System config is the machine's /etc
  patches = [ ./relocatable.patch ];
  autotools.makeFlags = [
    "RUNTIME_PREFIX=YesPlease"
    "gitexecdir=libexec/git-core"
    "template_dir=share/git-core/templates"
    "sysconfdir=/etc"
    "RUST_TARGET_DIR=$(CARGO_TARGET_DIR)/${platform.rustTriple}/release"
    "CURL_LDFLAGS=-lcurl" # asked of curl-config, which curl built with cmake does not install
    "NO_PERL=1"
    "PERL_PATH=" # NO_PERL still leaves /usr/bin/perl for t/Makefile's lints
    "NO_PYTHON=1"
    "NO_GETTEXT=1"
    # config.mak.uname asks the build machine
    "uname_S=${platform.osNames.cmake}"
    "uname_M=${platform.cpu}"
    "uname_O=${if platform.os == "linux" then "GNU/Linux" else platform.os}"
    "uname_R="
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
}
