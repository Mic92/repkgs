# MSVC CRT + STL, UCRT and the Windows SDK for one cpu as {crt,sdk}/, what `clang -target
# *-windows-msvc /winsysroot` expects: fetched payload by payload off the Visual Studio
# manifest (builder/fetch/winsdk.nu), nothing compiled. Unfree, stays out of the public cache.
{
  package,
  fetch,
  sources,
  platform,
}:
package {
  name = "windows-sdk";
  source = fetch.windowsSdk {
    manifest = sources.fetch "default";
    arch = platform.cpu;
  };
  phases = [ ];
  install."." = [
    "crt"
    "sdk"
  ];
  exports = false;
}
