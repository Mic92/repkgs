# cgo against sqlite via mattn/go-sqlite3: the modules tree propagates our sqlite and go.nu adds
# the `libsqlite3` tag (builder/sys-libs.nu), nothing here names it
{
  package,
  sources,
  fetch,
}:
package {
  name = "dbmate";
  uses = [ "go" ];
  go.modules = fetch.goModules { source = sources.default; };
  go.ldflags = [ "-s" ];
  go.packages = [ "." ];
  go.testPackages = [
    "./pkg/dbutil/..."
    "./pkg/driver/sqlite/..."
  ]; # the other drivers' tests want running database servers
  bin = [ "dbmate" ];
  tests.version = true;
}
