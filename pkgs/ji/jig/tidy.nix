# `jig-tidy FILE...`: clang-tidy over src/ with the third-party headers and store dir the bootstrap
# build uses. Imported by shell.nix for treefmt's cpp-tidy step.
{ pkgs, llvm }:
let
  src =
    name:
    (import ../../../nix/sources.nix (../.. + "/${builtins.substring 0 2 name}/${name}/sources.toml"))
    .default;
  thirdParty = pkgs.runCommand "jig-third-party" { } ''
    mkdir -p $out/include
    tar -xf ${src "blake3"} -C $out/include --strip-components=2 --wildcards '*/c/blake3.h'
    ln -s ${src "nlohmann-json"} $out/include/json.hpp
  '';
in
# clang-tools' wrapper picks up libc++ and libc from the calling shell's libcxx stdenv
pkgs.writeShellScriptBin "jig-tidy" ''
  exec ${llvm.clang-tools}/bin/clang-tidy -quiet "$@" -- \
    -std=c++26 -stdlib=libc++ -DJIG_STORE_DIR="\"${builtins.storeDir}\"" -isystem ${thirdParty}/include
''
