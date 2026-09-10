use ../core.nu *
use ../node-common.nu

# npm ci from fetch.npmDeps (`npm.deps`: a package-lock.json whose `resolved` point at store
# tarballs; npm checks each against the lock's integrity), `npm run <script>`, `npm test`, and the
# pruned package as lib/node_modules/<name> with its bin links.
# offline `npm ci` against the rewritten lock
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options npm)
  load-env {
    npm_config_cache: $"($c.build)/npm-cache", npm_config_offline: "true", npm_config_progress: "false", npm_config_audit: "false"
    npm_config_fund: "false", npm_config_update_notifier: "false", npm_config_loglevel: "warn", NODE_OPTIONS: "--no-deprecation"
  }
  cp $"($o.deps)/package-lock.json" package-lock.json
  ^chmod u+w package-lock.json  # npm prune rewrites it
  x npm ci --ignore-scripts ...$o.flags
  node-common after-install $env.PWD
}

export def workdir []: nothing -> string { project-dir npm }

# npm run <npm.script> (null: nothing to build)
export def build []: nothing -> nothing {
  let script = (options npm).script
  if $script != null { x npm run $script }
}

# npm test
export def test []: nothing -> nothing { x npm test }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  x npm prune --omit=dev --ignore-scripts
  node-common install-tree
}
