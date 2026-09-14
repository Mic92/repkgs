# `jig-tidy FILE...`: clang-tidy over src/ with the third-party headers and store dir the bootstrap
# build uses. Imported by shell.nix for treefmt's cpp-tidy step.
{ pkgs, llvm }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  src =
    name:
    (import ../../../nix/sources.nix {
      unpacker =
        (import ../../../nix/sources.nix { unpacker = null; } ../../se/seed/sources.toml).fetch
          system;
      inherit system;
    } (../.. + "/${builtins.substring 0 2 name}/${name}/sources.toml")).default;
  thirdParty = pkgs.runCommand "jig-third-party" { } ''
    mkdir -p $out/include
    cp ${src "blake3"}/c/blake3.h ${src "zstd"}/lib/zstd.h ${src "zstd"}/lib/zstd_errors.h $out/include/
    ln -s ${src "nlohmann-json"} $out/include/json.hpp
  '';
in
# the clang-tools wrapper takes libc++ from the calling shell, and needs bash
pkgs.writeShellScriptBin "jig-tidy" ''
  exec ${pkgs.bash}/bin/bash ${llvm.clang-tools}/bin/clang-tidy -quiet "$@" -- \
    -std=c++26 -stdlib=libc++ -DJIG_STORE_DIR="\"${builtins.storeDir}\"" -isystem ${thirdParty}/include
''
