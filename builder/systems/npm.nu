use ../core.nu *
use ../node-common.nu

# npm ci from fetch.npmDeps (`npm.deps`: a package-lock.json whose `resolved` point at store
# tarballs; npm checks each against the lock's integrity), `npm run <script>`, `npm test`, and the
# pruned package as lib/node_modules/<name> with its bin links.
def knobs []: nothing -> record<script: string, deps: any, test: bool, flags: list<string>> {
  knobs-for npm {script: "build", deps: null, test: true, flags: []}
}

# offline `npm ci` against the rewritten lock
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  load-env {
    npm_config_cache: $"($c.build)/npm-cache", npm_config_offline: "true", npm_config_progress: "false", npm_config_audit: "false"
    npm_config_fund: "false", npm_config_update_notifier: "false", npm_config_loglevel: "warn", NODE_OPTIONS: "--no-deprecation"
  }
  cd (project-dir npm)
  cp $"($k.deps)/package-lock.json" package-lock.json
  ^chmod u+w package-lock.json  # npm prune rewrites it
  x npm ci --ignore-scripts ...$k.flags
  node-common after-install $env.PWD
}

# npm run <npm.script>
export def build []: nothing -> nothing { cd (project-dir npm); x npm run (knobs).script ...(knobs).flags }

# npm test unless npm.test = false
export def test []: nothing -> nothing { cd (project-dir npm); if (knobs).test { x npm test } }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  cd (project-dir npm)
  x npm prune --omit=dev --ignore-scripts
  node-common install-tree
}
