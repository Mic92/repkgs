/* what the libc makes of $TZ: the zone abbreviation in effect at the epoch */
#include <stdio.h>
#include <time.h>

int main(void) {
  time_t t = 0;
  struct tm tm;
  localtime_r(&t, &tm);
  printf("%s\n", tm.tm_zone);
  return 0;
}
