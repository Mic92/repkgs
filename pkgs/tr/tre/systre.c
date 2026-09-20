/* POSIX regex(3) entry points over TRE, after MSYS2's libsystre (BSD-2-Clause) */
#include <tre/tre.h>

int regcomp(regex_t *preg, const char *regex, int cflags) { return tre_regcomp(preg, regex, cflags); }
void regfree(regex_t *preg) { tre_regfree(preg); }
size_t regerror(int errcode, const regex_t *preg, char *errbuf, size_t errbuf_size) {
  return tre_regerror(errcode, preg, errbuf, errbuf_size);
}
int regexec(const regex_t *preg, const char *str, size_t nmatch, regmatch_t pmatch[], int eflags) {
  return tre_regexec(preg, str, nmatch, pmatch, eflags);
}
