# Nushell completions for nom, nom-build and nom-shell, autoloaded from
# share/nushell/vendor/autoload (see $nu.vendor-autoload-dirs).
# Mirrors nix-output-monitor/exe/Main.hs: nom wraps nix build/copy/shell/
# develop/flake, nom-build wraps nix-build and nom-shell wraps nix-shell.
# Only nom's own surface is completed here; wrapped commands fall back to
# file completion.
def "nu-complete nom" [] {
  ["build", "copy", "shell", "develop", "flake", "--version", "--json", "--help", "-h"]
}

export extern nom [
  command?: string@"nu-complete nom"
  --version
  --json
  --help(-h)
  ...args
]

# Common nix-build flags; the rest completes files.
export extern nom-build [
  --help(-h)
  --attr(-A): string
  --arg: string
  --argstr: string
  --dry-run
  --no-out-link
  --show-trace
  --keep-going(-k)
  --fallback
  --option: string
  --cores: string
  --max-jobs: string
  --log-format: string
  --verbose(-v)
  ...args
]

# Common nix-shell flags; the rest completes files.
export extern nom-shell [
  --help(-h)
  --attr(-A): string
  --arg: string
  --argstr: string
  --command(-c): string
  --run: string
  --pure
  --keep(-k): string
  --show-trace
  --option: string
  --cores: string
  --max-jobs: string
  --verbose(-v)
  ...args
]
