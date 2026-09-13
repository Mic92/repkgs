// reloc.h, macOS: dladdr. <dlfcn.h> hides it under _POSIX_C_SOURCE and the package may have
// included it that way already, so declared here (layout and symbol as in dyld's header).
#include <string.h>

typedef struct {
  const char* dli_fname;
  void* dli_fbase;
  const char* dli_sname;
  void* dli_saddr;
} reloc_dl_info;
int reloc_dladdr(const void*, reloc_dl_info*) __asm__("_dladdr");

__attribute__((visibility("hidden"), used)) static void reloc_self(const void* addr, char* out, size_t n) {
  reloc_dl_info info;
  if (reloc_dladdr(addr, &info) && info.dli_fname) strncpy(out, info.dli_fname, n - 1);
}
