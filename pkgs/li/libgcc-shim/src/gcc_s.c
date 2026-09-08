// libgcc_s.so.1 for upstream-built binaries (rustc, node, ...) on our gcc-free runtime: the
// _Unwind_* ABI comes from libunwind.a linked whole, versioned GCC_3.0.. by gcc_s.ver. compiler-rt's
// builtins are hidden by design, so the few libgcc integer routines such binaries import are here.

int __popcountdi2(long long value) { return __builtin_popcountll((unsigned long long)value); }

int __popcountti2(__int128 value) {
  return __builtin_popcountll((unsigned long long)value) + __builtin_popcountll((unsigned long long)(value >> 64));
}

int __clzdi2(long long value) { return __builtin_clzll((unsigned long long)value); }

int __ctzdi2(long long value) { return __builtin_ctzll((unsigned long long)value); }
