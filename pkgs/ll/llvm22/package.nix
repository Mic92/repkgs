# libLLVM of the major rustc bundles (src/llvm-project in the rustc tarball), one behind ours:
# rustc's feature tables track that major and reject or invent names on a newer one (amx-tf32)
{ variant, pkgs }: variant pkgs.llvm { }
