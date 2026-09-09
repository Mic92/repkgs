# Info-ZIP 6.0 (2009), flags given directly for the same reason as pkgs/zi/zip
{ package }:
package {
  name = "unzip";
  steps = [
    {
      name = "build";
      run = ''
        let cflags = "-O2 -I. -DUNIX -DLARGE_FILE_SUPPORT -DUNICODE_SUPPORT -DUNICODE_WCHAR -DUTF8_MAYBE_NATIVE -DNO_LCHMOD -DDATE_FORMAT=DF_YMD -std=gnu89 -Wno-implicit-int -Wno-implicit-function-declaration -Wno-deprecated-non-prototype -Wno-format-security"
        x make -f unix/Makefile unzips CC=cc LD=cc AS=cc $"CF=($cflags)" LF2= $"-j($c.njobs)"
      '';
    }
  ];
  install."bin/" = [
    "unzip"
    "funzip"
    "unzipsfx"
  ];
  links."bin/zipinfo" = "unzip";
  tests.version = "-v";
}
