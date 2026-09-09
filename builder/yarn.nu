use core.nu *
use node-package.nu

# yarn (classic) install --offline from fetch.yarnDeps (`yarn.deps`: an offline mirror directory,
# yarn checks each tarball against yarn.lock's integrity), `yarn run <script>`, `yarn test`, and
# the pruned package as lib/node_modules/<name> with its bin links.
def knobs []: nothing -> record<script: string, deps: any, test: bool, flags: list<string>> {
  knobs-for yarn {script: "build", deps: null, test: true, flags: []}
}

# `yarn install --offline --frozen-lockfile` against the mirror
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  load-env {
    YARN_CACHE_FOLDER: $"($c.build)/yarn-cache", YARN_YARN_OFFLINE_MIRROR: $k.deps, YARN_ENABLE_PROGRESS_BARS: "false"
    YARN_DISABLE_SELF_UPDATE_CHECK: "true", CI: "true", NODE_OPTIONS: "--no-deprecation", HOME: $"($c.build)/home"
  }
  cd (project-dir yarn)
  x yarn install --offline --frozen-lockfile --ignore-scripts --non-interactive --no-progress ...$k.flags
  node-package after-install $env.PWD
}

# yarn run <yarn.script>
export def build []: nothing -> nothing { cd (project-dir yarn); x yarn run --offline (knobs).script }

# yarn test unless yarn.test = false
export def test []: nothing -> nothing { cd (project-dir yarn); if (knobs).test { x yarn test --offline } }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  cd (project-dir yarn)
  x yarn install --offline --frozen-lockfile --ignore-scripts --production --non-interactive --no-progress ...(knobs).flags
  node-package install-tree
}
