# `nix-shell --run treefmt` formats, `treefmt --ci` is the check. Built with nixpkgs'
# `treefmt.withConfig` so every tool is pinned here and shell.nix only carries the wrapper.
{ pkgs }:
let
  llvm = pkgs.llvmPackages_23;
  # nu's own parser/type checker over each file (authoritative). Fails on any error diagnostic
  nu-typecheck = pkgs.writeShellScript "nu-typecheck" ''
    status=0
    for f in "$@"; do
      out=$(${pkgs.nushell}/bin/nu --no-config-file --ide-check 50 "$f" | ${pkgs.jq}/bin/jq -r 'select(.type == "diagnostic" and .severity == "Error") | "\(.span.start): \(.message)"')
      if [ -n "$out" ]; then printf '%s:\n%s\n' "$f" "$out" >&2; status=1; fi
    done
    exit $status
  '';
  # statix checks one path per call
  statix-each = pkgs.writeShellScript "statix-each" ''
    status=0
    for f in "$@"; do ${pkgs.statix}/bin/statix check -c ${./statix.toml} "$f" || status=1; done
    exit $status
  '';
  nuFiles = [
    "*.nu"
    "pkgs/up/uptrack/src/uptrack"
  ];
in
pkgs.treefmt.withConfig {
  settings = {
    global.excludes = [
      "experiments/**"
      "pkgs/ll/llvm/*.txt"
      "result*"
      "**/lock.json"
    ];
    formatter = {
      nix = {
        command = "${pkgs.nixfmt}/bin/nixfmt";
        includes = [ "*.nix" ];
      };
      nix-statix = {
        command = "${statix-each}";
        includes = [ "*.nix" ];
      };
      nix-deadnix = {
        command = "${pkgs.deadnix}/bin/deadnix";
        options = [
          "--fail"
          "--edit"
        ];
        includes = [ "*.nix" ];
      };
      go = {
        command = "${pkgs.go}/bin/gofmt";
        options = [ "-w" ];
        includes = [ "pkgs/*/*/src/*.go" ];
      };
      cpp = {
        command = "${llvm.clang-tools}/bin/clang-format";
        options = [ "-i" ];
        includes = [
          "pkgs/*/*/src/*.cc"
          "pkgs/*/*/src/*.h"
          "pkgs/*/*/src/*.c"
        ];
      };
      # check only: clang-tidy with pkgs/ji/jig/src/.clang-tidy, warnings are errors
      cpp-tidy = {
        command = "${import ./pkgs/ji/jig/tidy.nix { inherit pkgs llvm; }}/bin/jig-tidy";
        includes = [ "pkgs/*/*/src/*.cc" ];
      };
      python = {
        command = "${pkgs.ruff}/bin/ruff";
        options = [ "format" ];
        includes = [ "*.py" ];
      };
      python-lint = {
        command = "${pkgs.ruff}/bin/ruff";
        options = [
          "check"
          "--fix"
        ];
        includes = [ "*.py" ];
      };
      toml = {
        command = "${pkgs.taplo}/bin/taplo";
        options = [ "format" ];
        includes = [ "*.toml" ];
      };
      # nu has no stable formatter, these two only check. nu-lint is the strict-typing/idiom
      # policy in .nu-lint.toml
      nu-typecheck = {
        command = "${nu-typecheck}";
        includes = nuFiles;
      };
      nu-lint = {
        command = "${pkgs.nu-lint}/bin/nu-lint";
        options = [
          "-c"
          ".nu-lint.toml"
        ];
        includes = nuFiles;
      };
    };
  };
}
