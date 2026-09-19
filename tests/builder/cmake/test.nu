use checks.nu *
has-debug bin/hello
has-debug lib/libgreet.so.1.2
assert "lib/, not lib64/" ($"($env.pkg)/lib/libgreet.so" | path exists)
assert "soname links relative" ((^readlink $"($env.pkg)/lib/libgreet.so.1") == "libgreet.so.1.2")
let cfg = (open --raw $"($env.pkg)/lib/cmake/greet/greetConfig.cmake")
assert "exported libm not a sysroot path" ($cfg !~ 'sysroot-[^"]*/libm\.')
let e = (open $"($env.pkg)/exports.json")
assert "exports: include dir" ("include" in $e.includeDirs)
assert "exports: pkgconfig dir" ("lib/pkgconfig" in $e.pkgconfigDirs)
assert "exports: libs" ("greet" in $e.libs)
done
