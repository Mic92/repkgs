# cgo against sqlite via mattn/go-sqlite3: the modules tree propagates our sqlite and go.nu adds
# the `libsqlite3` tag (builder/sys-libs.nu), nothing here names it
{
  package,
  buildPkgs,
}:
package {
  name = "dbmate";
  uses = [ "go" ];
  go.ldflags = [ "-s" ];
  go.packages = [ "." ];
  buildDependencies = [ buildPkgs.sqlite ]; # tests dump schemas through the sqlite3 cli
  go.testPackages = [
    "./pkg/dbutil/..."
    "./pkg/driver/sqlite/..."
  ]; # the other drivers' tests want running database servers
  tests.version = true;
}
