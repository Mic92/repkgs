use ../core.nu *
use ../sys-libs.nu

# A Ruby application installed with Bundler from its Gemfile.lock (fetch.gems, `bundler.deps`):
#   $out/lib/<name>/                the application tree, gems under vendor/bundle (deployment layout)
#   $out/bin/<exe>                  stubs that start our ruby with that bundle and load exe/<exe>
# Native extensions compile with the cc on PATH (mkmf takes CC from rbconfig, which says "cc").
# Gems that can link one of our libraries (a dependency, from [pin] sys) get `bundle config
# build.<gem>` flags and env from sys-libs.nu.
export const OPTIONS = {
  without: {default: [development test], doc: "Gemfile groups to leave out"}
  test: {default: null, type: list, doc: "command run under `bundle exec` as the test (null: none, test gems are usually in `without`)"}
  flags: {default: [], doc: "extra arguments for bundle install"}
}

def app-dir []: nothing -> string { let c = (ctx); $"($c.out)/lib/($c.spec.name)" }

# mkmf runs on the host ruby but must describe the target: its rbconfig.rb first on RUBYLIB,
# copied out so the host ruby does not pick up the target's .so files beside it
def --env cross-rbconfig []: nothing -> nothing {
  let c = (ctx)
  if not $c.platform.cross { return }
  let target = (files $"(dep-root ruby "extensions compile against the target ruby")/lib/ruby/*/*/rbconfig.rb" | first)
  let dir = $"($c.build)/cross-rbconfig"
  mkdir $dir
  cp $target $dir
  $env.RUBYLIB = ([$dir] ++ ($env.RUBYLIB? | default "" | split row ":" | where { $in != "" }) | str join ":")
}

# copy the source to its final place, put the fetched gems and checksummed lock beside it, and
# configure bundler entirely through BUNDLE_* env (no .bundle/config to clean up afterwards)
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options bundler)
  let app = (app-dir)
  ^cp -r $"(project-dir bundler)/." $app
  mkdir vendor
  ^cp -rL $"($o.deps)/vendor/cache" vendor/cache
  ^cp -f $"($o.deps)/Gemfile.lock" Gemfile.lock
  chmod -R u+w vendor Gemfile.lock
  load-env {
    BUNDLE_PATH: $"($app)/vendor/bundle", BUNDLE_CACHE_PATH: $"($app)/vendor/cache", BUNDLE_FROZEN: "true"
    BUNDLE_WITHOUT: ($o.without | str join ":"), BUNDLE_JOBS: $"($c.njobs)", BUNDLE_RETRY: "0"
    BUNDLE_USER_HOME: $"($c.build)/bundle-home", GEM_HOME: $"($c.build)/gem-home"
    MAKEFLAGS: $"-j($c.njobs)"
  }
  sys-libs check $app $c.spec.sys
  load-env (sys-libs env-for gems $c.deps)
  load-env (gem-build-env $c.deps)
  cross-rbconfig
}

export def workdir []: nothing -> string { app-dir }

# unpack the cached .gem files into vendor/bundle, compiling native extensions
export def build []: nothing -> nothing {
  x bundle install --local --no-cache ...((options bundler).flags)
  # the .gem archives, bundler's download cache and extension build logs and mkmf Makefiles (which embed the build dir)
  rm -rf vendor/cache ...(files --dirs vendor/bundle/ruby/*/cache) ...(files vendor/bundle/ruby/*/extensions/**/{gem_make.out,mkmf.log}) ...(files vendor/bundle/ruby/*/gems/*/ext/**/Makefile)
  fix-shebangs vendor/bundle (ctx).njobs
}

# `bundler.test`: a command run with `bundle exec` (off by default: test gems are in `without`)
export def test []: nothing -> nothing {
  let command = (options bundler).test
  if $command != null { x bundle exec ...$command }
}

# bin/<name> for each `bin` of the spec
export def install []: nothing -> nothing {
  let c = (ctx)
  let app = (app-dir)
  let ruby = (dep-root ruby "the bin stubs run the target ruby")
  mkdir $"($c.out)/bin"
  for name in ($c.spec.bin? | default []) {
    bin-stub $name $app $ruby | save -f $"($c.out)/bin/($name)"
    chmod +x $"($c.out)/bin/($name)"
  }
}

# BUNDLE_BUILD__<GEM> is how `bundle config build.<gem> <flags>` reaches `gem install` without a config file
def gem-build-env [deps: list<record<name: string, root: string>>]: nothing -> record {
  let flags = (sys-libs gem-build-flags $deps)
  if ($flags | is-not-empty) { note sys-libs ($flags | columns | str join " ") }
  $flags | items {|gem, value| [$"BUNDLE_BUILD__($gem | str uppercase | str replace -a "-" "___")" $value] } | into record
}

# a ruby script that activates the bundle and loads the application's own executable, the app
# dir found from the stub's own location
def bin-stub [name: string, app: string, ruby: string]: nothing -> string {
  let c = (ctx)
  let exe = ([exe bin] | each { $"($app)/($in)/($name)" } | where { path exists } | first)
  [
    $"#!($ruby)/bin/ruby"
    $"app = File.expand_path\('../($app | path relative-to $c.out)', __dir__)"
    "ENV['BUNDLE_GEMFILE'] = \"#{app}/Gemfile\""
    "ENV['BUNDLE_PATH'] = \"#{app}/vendor/bundle\""
    $"ENV['BUNDLE_WITHOUT'] = '((options bundler).without | str join ":")'"
    "ENV['BUNDLE_FROZEN'] = 'true'"
    "require 'bundler/setup'"
    $"load \"#{app}/($exe | path relative-to $app)\""
  ] | str join "\n"
}
