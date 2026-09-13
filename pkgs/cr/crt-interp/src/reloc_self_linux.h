// reloc.h, Linux: the mapping in /proc/self/maps that contains the address. Only ISO C, so it
// compiles under any feature-test macros the package sets.
#include <stdio.h>
#include <string.h>

__attribute__((visibility("hidden"), used)) static void reloc_self(const void* addr, char* out, size_t n) {
  unsigned long self = (unsigned long)addr, lo, hi;
  FILE* maps = fopen("/proc/self/maps", "re");
  char line[4096 + 128];
  while (maps && fgets(line, sizeof line, maps)) {
    char* path = strchr(line, '/');
    if (sscanf(line, "%lx-%lx", &lo, &hi) == 2 && lo <= self && self < hi && path) {
      path[strcspn(path, "\n")] = 0;
      strncpy(out, path, n - 1);
      break;
    }
  }
  if (maps) fclose(maps);
}
