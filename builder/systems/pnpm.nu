use ../core.nu *
use ../node-common.nu

# pnpm install --offline from fetch.pnpmDeps (`pnpm.deps`: registry tarballs that seed a fresh
# content-addressed store; pnpm verifies each against pnpm-lock.yaml), `pnpm run <script>`,
# `pnpm test`, and the pruned package as lib/node_modules/<name> with its bin links.
def knobs []: nothing -> record<script: string, deps: any, test: bool, flags: list<string>> {
  knobs-for pnpm {script: "build", deps: null, test: true, flags: []}
}

# seed the store from the tarballs, then `pnpm install --offline`
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  load-env {
    npm_config_store_dir: $"($c.build)/pnpm-store", npm_config_offline: "true", npm_config_update_notifier: "false", npm_config_loglevel: "warn"
    npm_config_manage_package_manager_versions: "false"  # do not fetch the pnpm version package.json names
    npm_config_side_effects_cache: "false", npm_config_verify_store_integrity: "false"
    CI: "true", NODE_OPTIONS: "--no-deprecation", XDG_DATA_HOME: $"($c.build)/xdg", XDG_CACHE_HOME: $"($c.build)/xdg"
  }
  cd (project-dir pnpm)
  # `store add` unpacks tarballs into the CAS the way a download would
  let tarballs = (open $"($k.deps)/index.json" | each {|t| $"($k.deps)/tarballs/($t.file)" })
  if ($tarballs | is-not-empty) { x pnpm store add ...$tarballs }
  x pnpm install --offline --frozen-lockfile --ignore-scripts ...$k.flags
  node-common after-install $env.PWD
}

# pnpm run <pnpm.script>
export def build []: nothing -> nothing { cd (project-dir pnpm); x pnpm run (knobs).script ...(knobs).flags }

# pnpm test unless pnpm.test = false
export def test []: nothing -> nothing { cd (project-dir pnpm); if (knobs).test { x pnpm test } }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  cd (project-dir pnpm)
  x pnpm prune --prod --ignore-scripts
  node-common install-tree
}
