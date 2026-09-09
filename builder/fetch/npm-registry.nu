# npm registry naming shared by the pnpm, bun and deno producers (npm's own lock carries full URLs)

export const REGISTRY = "https://registry.npmjs.org"

# "@scope/name@1.2.3" | "name@1.2.3" -> {name, version}: the version starts at the last "@" past position 0
export def split-id [id: string]: nothing -> record<name: string, version: string> {
  let at = ($id | str substring 1.. | str index-of -e "@") + 1
  {name: ($id | str substring ..<$at), version: ($id | str substring ($at + 1)..)}
}

# the registry's canonical tarball location (scoped packages drop the scope in the file name)
export def tarball-url [name: string, version: string, registry: string = ""]: nothing -> string {
  let base = (if $registry == "" { $REGISTRY } else { $registry | str trim -r -c "/" })
  $"($base)/($name)/-/($name | split row "/" | last)-($version).tgz"
}

# "@scope/name" as one path component / store name part
export def flat-name [name: string]: nothing -> string { $name | str replace "/" "+" }
