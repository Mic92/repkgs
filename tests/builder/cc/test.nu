use checks.nu *
has-debug bin/hello
has-debug lib/libhello.so
assert "static archive lost its DWARF" (not (has-section lib/libhello.a .debug_info))
assert "upstream ELF untouched" (has-section lib/upstream.so .debug_info)
assert "install map copies a directory" ($"($env.pkg)/share/data/file" | path exists)
assert "absolute self symlink made relative" ((^readlink $"($env.pkg)/lib/libabs.so") == "libhello.so")
assert ".la removed" (not ($"($env.pkg)/lib/libhello.la" | path exists))
done
