# a bundler application with native-extension gems (prism, rbs, json; psych gets our libyaml via
# sys-libs.nu): Gemfile.lock carries CHECKSUMS
{
  package,
  sources,
  fetch,
  pkgs,
}:
package {
  name = "ruby-lsp";
  uses = [ "bundler" ];
  bundler.gems = fetch.gems { source = sources.default; };
  dependencies = [ pkgs.ruby ];
  runtimeDependencies = [ pkgs.ruby ];
  bin = [
    "ruby-lsp"
    "ruby-lsp-check"
  ];
  tests.version = true;
}
