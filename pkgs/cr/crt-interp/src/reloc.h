// A path relative to the executable or shared object this is compiled into, resolved at run
// time: RELOC("../share/foo") in bin/foo or lib/libfoo.so is <prefix>/share/foo wherever the
// package was copied. For compiled-in directories that would otherwise name the install prefix.
// Only ISO C and /proc (dladdr on macOS, the module handle on Windows), so it compiles under any
// feature-test macros the package sets.
#ifndef RELOC_H
#define RELOC_H
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <dlfcn.h>
#elif defined(_WIN32)
#include <windows.h>
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

// hidden: every executable and library gets its own copy, and the mapping containing it is
// the file it was linked into
__attribute__((visibility("hidden"), noinline, used)) static const char* reloc_dir(void) {
  static char dir[PATH_MAX];
  if (dir[0]) return dir;
#if defined(__APPLE__)
  Dl_info info;
  if (dladdr((const void*)&reloc_dir, &info) && info.dli_fname) strncpy(dir, info.dli_fname, sizeof dir - 1);
#elif defined(_WIN32)
  HMODULE module = 0;
  if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCSTR)(void*)&reloc_dir, &module))
    GetModuleFileNameA(module, dir, sizeof dir);
  for (char* p = dir; *p; p++)
    if (*p == '\\') *p = '/';
#else
  unsigned long self = (unsigned long)(void*)&reloc_dir, lo, hi;
  FILE* maps = fopen("/proc/self/maps", "re");
  char line[PATH_MAX + 128];
  while (maps && fgets(line, sizeof line, maps)) {
    char* path = strchr(line, '/');
    if (sscanf(line, "%lx-%lx", &lo, &hi) == 2 && lo <= self && self < hi && path) {
      path[strcspn(path, "\n")] = 0;
      strncpy(dir, path, sizeof dir - 1);
      break;
    }
  }
  if (maps) fclose(maps);
#endif
  char* slash = strrchr(dir, '/');
  if (slash) slash[1] = 0;
  return dir;
}

__attribute__((visibility("hidden"), used)) static const char* reloc_path(const char* rel) {
  static struct {
    const char* rel;
    char* abs;
  } seen[32];
  for (int i = 0; i < 32 && seen[i].rel; i++)
    if (seen[i].rel == rel || !strcmp(seen[i].rel, rel)) return seen[i].abs;
  const char* dir = reloc_dir();
  char* abs = (char*)malloc(strlen(dir) + strlen(rel) + 1);
  if (!abs) return rel;
  strcat(strcpy(abs, dir), rel);
  for (int i = 0; i < 32; i++)
    if (!seen[i].rel) {
      seen[i].rel = rel;
      seen[i].abs = abs;
      break;
    }
  return abs;
}

#define RELOC(rel) reloc_path(rel)

#ifdef __cplusplus
}
#endif
#endif
