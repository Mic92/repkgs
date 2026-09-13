# The one way to list paths by pattern, lints/nu/bare-glob.yml bans `glob` everywhere else. nu's
# glob returns directory order, which leaked into an archive as member order and Nix refused the
# differing rebuild of a content-addressed derivation. Sorted, and regular files unless --dirs
# (directories only) or --any.
export def files [pattern: string, --dirs, --any, --no-symlink, --exclude: list<string> = []]: nothing -> list<string> {
  glob $pattern --no-dir=(not ($dirs or $any)) --no-file=($dirs and not $any) --no-symlink=$no_symlink --exclude $exclude | sort
}
