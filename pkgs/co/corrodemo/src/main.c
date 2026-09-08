#include <stdio.h>
#include <stdint.h>
uint64_t rs_add(uint64_t, uint64_t);
int main(void) { printf("2+40=%llu\n", (unsigned long long)rs_add(2, 40)); return rs_add(2, 40) == 42 ? 0 : 1; }
