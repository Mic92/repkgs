use core.nu *

# npm ci from an offline cache, npm run <script>, npm test, install as lib/node_modules/<name> + bin links.
def knobs []: nothing -> record<root: string, script: string, deps: any, test: bool, flags: list<string>> { knobs-for npm {root: ".", script: "build", deps: null, test: true, flags: []} }

# offline node_modules: `npm.deps` is fetch.npmDeps output, a package-lock.json whose `resolved`
# entries point at store tarballs. npm ci checks each against the lock's `integrity`
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  let dir = $"($c.src)/($k.root)"
  load-env {
    npm_config_cache: $"($c.build)/npm-cache", npm_config_offline: "true", npm_config_progress: "false", npm_config_audit: "false"
    npm_config_fund: "false", npm_config_update_notifier: "false", npm_config_loglevel: "warn", NODE_OPTIONS: "--no-deprecation"
  }
  cd $dir
  cp $"($k.deps)/package-lock.json" package-lock.json
  ^chmod u+w package-lock.json  # npm prune rewrites it
  x npm ci --ignore-scripts ...$k.flags
  # .bin scripts say #!/usr/bin/env node. No /usr/bin/env in the sandbox. Build-tree only, so absolute is fine here
  # (installed scripts get the launcher treatment of §3 instead).
  for f in (ls -l node_modules/.bin | get target | each {|t| $"node_modules/.bin/($t)" | path expand }) {
    let first = (open --raw $f | lines | first)
    let m = ($first | parse --regex '^#!\s*/usr/bin/env\s+(?P<prog>\S+)')
    if ($m | is-not-empty) {
      let prog = (tool $m.0.prog)
      open --raw $f | str replace $first $"#!($prog)" | save -f $f
    }
  }
  $env.PATH = ($env.PATH | prepend $"($dir)/node_modules/.bin")
}

# `run` is a nu keyword. The verb is build = `npm run <script>`
export def build []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; let k = (knobs); x npm run $k.script ...$k.flags }
# npm test unless `npm.test = false`
export def test []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; if (knobs).test { x npm test } }
# for packages whose product is the node package itself
export def install []: nothing -> nothing {
  let c = (ctx)
  cd $"($c.src)/((knobs).root)"
  x npm prune --omit=dev --ignore-scripts
  let dst = $"($c.out)/lib/node_modules/($c.spec.name)"
  mkdir ($dst | path dirname)
  ^cp -r . $dst
  mkdir $"($c.out)/bin"
  for b in (open package.json | get bin? | default {} | transpose name path) { ^ln -s $"($dst)/($b.path)" $"($c.out)/bin/($b.name)" }
}
