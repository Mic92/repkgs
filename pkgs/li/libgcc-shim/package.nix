# lib/libgcc_s.so.1 with the GCC_* symbol versions upstream-built binaries expect, backed by our
# libunwind. `prebuilt` packages depend on it, and builds whose fresh binaries call pthread_exit
# or pthread_cancel: glibc dlopens libgcc_s.so.1 for those by soname, from libc's own search path
# (nothing, libc has no RUNPATH) or LD_LIBRARY_PATH, hence the env export.
{ package, toolchain }:
package {
  name = "libgcc-shim";
  version = "1";
  source = ./src;
  steps = [
    {
      name = "build";
      run = ''
        mkdir $"($c.out)/lib"
        # glibc's pthread_exit dlsyms the C personality routine too. compiler-rt has it, hidden as
        # all its builtins: take the object and un-hide it
        let builtins = (^cc -print-libgcc-file-name | str trim)
        x llvm-ar x $builtins gcc_personality_v0.c.o
        x llvm-objcopy --set-symbol-visibility __gcc_personality_v0=default gcc_personality_v0.c.o
        (x cc -shared -O2 -o $"($c.out)/lib/libgcc_s.so.1" $"($c.src)/gcc_s.c" gcc_personality_v0.c.o
          $"-Wl,--version-script=($c.src)/gcc_s.ver" -Wl,-soname,libgcc_s.so.1
          -Wl,--whole-archive $"${toolchain.sysroot}/lib/libunwind.a" -Wl,--no-whole-archive -nostdlib++)
      '';
    }
  ];
  exports = {
    libs = [ ];
    env.LD_LIBRARY_PATH = "{root}/lib";
  };
}
