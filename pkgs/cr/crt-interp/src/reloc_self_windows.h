// reloc.h, Windows: the module handle owning the address
#include <windows.h>
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif

__attribute__((visibility("hidden"), used)) static void reloc_self(const void* addr, char* out, size_t n) {
  HMODULE module = 0;
  if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCSTR)addr, &module))
    GetModuleFileNameA(module, out, (DWORD)n);
  for (char* p = out; *p; p++)
    if (*p == '\\') *p = '/';
}
