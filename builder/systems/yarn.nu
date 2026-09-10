use ../core.nu *
use ../node-common.nu

# yarn (classic) install --offline from fetch.yarnDeps (`yarn.deps`: an offline mirror directory,
# yarn checks each tarball against yarn.lock's integrity), `yarn run <script>`, `yarn test`, and
# the pruned package as lib/node_modules/<name> with its bin links.
def options []: nothing -> record {
  options-for yarn {script: "build", deps: null, flags: []}
}

# `yarn install --offline --frozen-lockfile` against the mirror
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options)
  load-env {
    YARN_CACHE_FOLDER: $"($c.build)/yarn-cache", YARN_YARN_OFFLINE_MIRROR: $o.deps, YARN_ENABLE_PROGRESS_BARS: "false"
    YARN_DISABLE_SELF_UPDATE_CHECK: "true", NODE_OPTIONS: "--no-deprecation"
  }
  cd (project-dir yarn)
  x yarn install --offline --frozen-lockfile --ignore-scripts --non-interactive --no-progress ...$o.flags
  node-common after-install $env.PWD
}

export def workdir []: nothing -> string { project-dir yarn }

# yarn run <yarn.script> (null: nothing to build)
export def build []: nothing -> nothing {
  let script = (options).script
  if $script != null { x yarn run --offline $script }
}

# yarn test
export def test []: nothing -> nothing { x yarn test --offline }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  x yarn install --offline --frozen-lockfile --ignore-scripts --production --non-interactive --no-progress ...(options).flags
  node-common install-tree
}
