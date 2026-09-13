// A path relative to the executable or shared object this is compiled into, resolved at run
// time: RELOC("../share/foo") in bin/foo or lib/libfoo.so is <prefix>/share/foo wherever the
// package was copied. For compiled-in directories that would otherwise name the install prefix.
// reloc_self.h is the OS's way to name the file an address is mapped from (cc installs the one
// for its target next to this).
#ifndef RELOC_H
#define RELOC_H
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "reloc_self.h"

#ifdef __cplusplus
extern "C" {
#endif

// hidden: every executable and library gets its own copy, and the mapping containing it is
// the file it was linked into
__attribute__((visibility("hidden"), noinline, used)) static const char* reloc_dir(void) {
  static char dir[PATH_MAX];
  if (dir[0]) return dir;
  reloc_self((const void*)&reloc_dir, dir, sizeof dir);
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
