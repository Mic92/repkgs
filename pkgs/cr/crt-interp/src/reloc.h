// A path relative to the executable or shared object this is compiled into, resolved at run
// time: RELOC("../share/foo") in bin/foo or lib/libfoo.so is <prefix>/share/foo wherever the
// package was copied. For compiled-in directories that would otherwise name the install prefix.
// Only ISO C and /proc, so it compiles under any feature-test macros the package sets.
#ifndef RELOC_H
#define RELOC_H
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// hidden: every executable and library gets its own copy, and the mapping containing it is
// the file it was linked into
__attribute__((visibility("hidden"), noinline, used)) static const char* reloc_dir(void) {
  static char dir[PATH_MAX];
  if (dir[0]) return dir;
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
