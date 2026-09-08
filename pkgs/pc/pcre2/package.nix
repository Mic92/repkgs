{
  package,
  pkgs,
}:
package {
  name = "pcre2";
  uses = [ "cmake" ];
  tests.separate = true;
  cmake.defs = {
    PCRE2_SUPPORT_JIT = true;
    PCRE2_BUILD_PCRE2_16 = true;
    PCRE2_BUILD_PCRE2_32 = true;
    PCRE2GREP_SUPPORT_CALLOUT_FORK = false; # test execs /bin/echo
  };
  dependencies = [
    pkgs.zlib
    pkgs.bzip2
  ];
}
