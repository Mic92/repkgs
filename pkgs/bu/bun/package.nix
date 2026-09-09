# Upstream's bun binary run under our dynamic linker (`prebuilt`), a build tool for the bun build
# system like `rust` is for cargo. From source later (docs/plan.md).
{
  package,
}:
package {
  name = "bun";
  prebuilt = true;
  install."bin/bun" = "bun";
  links."bin/bunx" = "bun";
  bin = [ "bun" ];
  tests.version = true;
}
