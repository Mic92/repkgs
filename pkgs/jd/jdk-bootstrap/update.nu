# uptrack hook. Temurin file names spell the tag jdk-25.0.4.1+1 as 25.0.4.1_1 and the URL path
# wants + as %2B: neither is {version} nor {tag}, so the candidates carry both as extra pin keys
use datasource.nu
use purl.nu *

export def resolve [pkg: record]: nothing -> table {
  datasource versions (purl parse $pkg.upstream.purl) | each {|c|
    let v = ($c.tag | str replace "jdk-" "")
    $c | merge {version: $v, path: ($c.tag | str replace "+" "%2B"), file: ($v | str replace -ar "[.+]" "_")}
  }
}
