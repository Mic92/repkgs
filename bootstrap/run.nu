# Derivation entry point: export the structured attrs as environment (lists space-joined, that
# is how recipes split them), run the recipe, print the compile-cache summary, then clear
# group/other write bits on $out (the sandbox umask leaves them set, the daemon rejects that).
def main [
  recipe: path  # bootstrap/<name>.nu to run with lib.nu beside it
]: nothing -> nothing {
  let attrs = (open $env.NIX_ATTRS_JSON_FILE)
  $attrs | reject --optional outputs args builder | items {|k, v|
    {$k: (if ($v | describe | str starts-with list) { $v | str join " " } else { $v | into string })}
  } | reduce {|it| merge $it } | load-env
  $env.out = $attrs.outputs.out
  $env.JIG_LOG = $"($env.NIX_BUILD_TOP)/jig.log"
  ^nu --no-config-file $recipe
  if ($env.JIG_LOG | path exists) {
    let kinds = (open --raw $env.JIG_LOG | lines | each { split row " " | first } | uniq -c)
    print -e $"== cache: ($kinds | each { $"($in.value)=($in.count)" } | str join ' ')"
  }
  ^chmod -R go-w $env.out
}
