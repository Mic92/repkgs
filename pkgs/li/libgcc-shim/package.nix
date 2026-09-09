# lib/libgcc_s.so.1 with the GCC_* symbol versions upstream-built binaries expect, backed by our
# libunwind. Only `prebuilt` packages depend on it.
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
        (x cc -shared -O2 -o $"($c.out)/lib/libgcc_s.so.1" $"($c.src)/gcc_s.c"
          $"-Wl,--version-script=($c.src)/gcc_s.ver" -Wl,-soname,libgcc_s.so.1
          -Wl,--whole-archive $"${toolchain.sysroot}/lib/libunwind.a" -Wl,--no-whole-archive -nostdlib++)
      '';
    }
  ];
  exports.libs = [ ];
}
