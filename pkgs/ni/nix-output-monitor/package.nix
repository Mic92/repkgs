{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "nix-output-monitor";
  uses = [ "cabal" ];
  cabal.exes = [ "nom" ];
  buildDependencies = [
    buildPkgs.libarchive # for bsdtar in hermes-include phase
  ];
  # nom --version execs nix, and nom build/shell/develop wrap nix/nix-shell:
  # as a runtime dependency its bin/ lands on the launcher's PATH, which is
  # also what makes the version check pass in its empty environment
  dependencies = [ pkgs.nix ];
  # hermes-json vendors simdjson whose amalgamation drops every <iterator>
  # include as editor-only: libstdc++ provides it transitively, libc++ does
  # not, so std::inserter fails to compile. Prefer a patched unpack as a
  # local package; hackage revisions cannot change sources.
  phases.before."cabal.build" = {
    name = "hermes-include";
    run = ''
      let deps = ((options cabal) | get deps)
      let pkg = (ls $"($deps)/hermes-json-*.tar.gz" | get name | first | path basename | str replace ".tar.gz" "")
      mkdir patched
      ^bsdtar -xf $"($deps)/($pkg).tar.gz" -C patched
      let header = $"patched/($pkg)/simdjson/singleheader/simdjson.h"
      "#include <iterator>\n" + (open --raw $header) | save -f $header
      $"packages: patched/($pkg)\n" | save --append cabal.project.local
    '';
  };
  bin = [ "nom" ];
  # test suites need HUnit/doctest-parallel, outside the dependency-only freeze
  tests.run = false;
  # argv[0] dispatch: nom-build/nom-shell behave as nix-build/nix-shell
  links = {
    "bin/nom-build" = "nom";
    "bin/nom-shell" = "nom";
  };
  completions = {
    bash = [
      "nix-output-monitor/completions/nom.bash"
      "nix-output-monitor/completions/nom-build.bash"
      "nix-output-monitor/completions/nom-shell.bash"
    ];
    zsh = [
      "nix-output-monitor/completions/nom.zsh"
      "nix-output-monitor/completions/nom-build.zsh"
      "nix-output-monitor/completions/nom-shell.zsh"
    ];
    fish = [ "nix-output-monitor/completions/nom.fish" ];
    nu = [ ./nom-completions.nu ];
  };
  patches = [
    # Tolerate floating-CA/deferred/impure/dynamic derivations instead of
    # DerivationParseError "string"; drops nix-derivation.
    # https://github.com/maralorn/nix-output-monitor/issues/167
    ./content-addressed-derivations.patch
    # FetchToStore activity/result from nix 2.36pre.
    # https://github.com/maralorn/nix-output-monitor/pull/313
    ./upstream-fetch-to-store-nix-2.36.patch
    # Forest roots in a set, fixes quadratic slowdown.
    # https://github.com/maralorn/nix-output-monitor/pull/304
    ./upstream-fix-quadratic-slowdown.patch
    # FileTransfer progress bars (rebased, must apply after /pull/313).
    # https://github.com/maralorn/nix-output-monitor/pull/314
    ./upstream-filetransfer-progress.patch
    # Remote store: .drv only exists remotely (--store ssh-ng://... with
    # --eval-store auto). Skip graph expansion silently instead of
    # DerivationReadError spam. https://github.com/maralorn/nix-output-monitor/issues/175
    ./remote-store-missing-drv.patch
    # .drv files are always UTF-8; TextIO.readFile decodes with the process
    # locale and throws under a C locale (nh --build-host over ssh).
    ./utf8-derivation-read.patch
  ];
}
