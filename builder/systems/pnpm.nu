use ../core.nu *
use ../node-common.nu

# pnpm install --offline from fetch.pnpmDeps (`pnpm.deps`: registry tarballs that seed a fresh
# content-addressed store; pnpm verifies each against pnpm-lock.yaml), `pnpm run <script>`,
# `pnpm test`, and the pruned package as lib/node_modules/<name> with its bin links.
def options []: nothing -> record<script: string, deps: any, flags: list<string>> {
  options-for pnpm {script: "build", deps: null, flags: []}
}

# seed the store from the tarballs, then `pnpm install --offline`
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options)
  load-env {
    npm_config_store_dir: $"($c.build)/pnpm-store", npm_config_offline: "true", npm_config_update_notifier: "false", npm_config_loglevel: "warn"
    npm_config_manage_package_manager_versions: "false"  # do not fetch the pnpm version package.json names
    npm_config_side_effects_cache: "false", npm_config_verify_store_integrity: "false"
    NODE_OPTIONS: "--no-deprecation"
  }
  cd (project-dir pnpm)
  # `store add` unpacks tarballs into the CAS the way a download would
  let tarballs = (open $"($o.deps)/index.json" | each {|t| $"($o.deps)/tarballs/($t.file)" })
  if ($tarballs | is-not-empty) { x pnpm store add ...$tarballs }
  x pnpm install --offline --frozen-lockfile --ignore-scripts ...$o.flags
  node-common after-install $env.PWD
}

# pnpm run <pnpm.script>
export def build []: nothing -> nothing { x pnpm run (options).script ...(options).flags }

# pnpm test
export def test []: nothing -> nothing { x pnpm test }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  x pnpm prune --prod --ignore-scripts
  node-common install-tree
}
