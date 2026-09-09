# Version normalisation and ordering. One comparator covers semver, pep440 and distro-style
# "loose": numeric runs compare as numbers, pre-release words sort before the release, other
# words after (1.0rc1 < 1.0 == 1.0.0 < 1.0.post1 < 1.0.1).

const PRE = [dev pre preview alpha a beta b rc c DEV PRE ALPHA BETA RC]

# tag or file name → bare version: v1.2, release-1.2, jq-1.8.2, curl-8_1_0, R_2_7_2, llvmorg-21.1.8
export def "version from-tag" [tag: string]: nothing -> string {
  # `name-` first (names may contain digits: pcre2-10.44, bun-v1.4.2), then a letters-only prefix
  # (v4.0.6, go1.25, R_2_7_2, v3_4_10: `v3_` must not count as a name)
  let t = ($tag | str replace -r '^(?:[A-Za-z][A-Za-z0-9]*-(?=[vV]?\d))?(?:[A-Za-z]+[._]?(?=\d))?' '')
  if $t =~ '^\d+_\d+' { $t | str replace -a '_' '.' } else if $t =~ '^\d+(-\d+)+$' { $t | str replace -a '-' '.' } else { $t }
}

# components with a class: 0 pre-release word, (1 absent), 2 other word, 3 number; build metadata dropped
const ABSENT = {class: 1, value: 0}
const ZERO = {class: 3, value: 0}
def ranks [v: string]: nothing -> table<class: int, value: any> {
  $v | str replace -r '^[vV](?=\d)|\+.*$' '' | parse -r '(\d+|[A-Za-z]+)' | get capture0 | each {|p|
    if $p =~ '^\d' { {class: 3, value: ($p | into int)} } else if $p in $PRE { {class: 0, value: ($PRE | enumerate | where item == $p).0.index} } else { {class: 2, value: $p} }
  }
}

# contains alpha/beta/rc/dev/pre
export def "version is-prerelease" [v: string]: nothing -> bool { ranks $v | any {|r| $r.class == 0 } }

# -1, 0, 1. A missing component equals 0 after a number (1.0 == 1.0.0) and sits between
# pre-release and number otherwise (1.0rc1 < 1.0 < 1.0post1)
export def "version cmp" [a: string, b: string]: nothing -> int {
  let ra = (ranks $a)
  let rb = (ranks $b)
  for i in 0..<([($ra | length) ($rb | length)] | math max) {
    let x = ($ra | get -o $i | default $ABSENT)
    let y = ($rb | get -o $i | default $ABSENT)
    let x = (if $x.class == 1 and $y.class == 3 { $ZERO } else { $x })
    let y = (if $y.class == 1 and $x.class == 3 { $ZERO } else { $y })
    if $x != $y { return (if $x.class < $y.class or ($x.class == $y.class and $x.value < $y.value) { -1 } else { 1 }) }
  }
  0
}

# newest of a list, null when empty
export def "version max" []: list<string> -> oneof<string, nothing> {
  reduce -f null {|v, best| if $best == null or (version cmp $v $best) > 0 { $v } else { $best } }
}

# ">=1.2,<2", "==3.12.*", "!=4.0". Empty allows everything
export def "version satisfies" [v: string, range: oneof<string, nothing>]: nothing -> bool {
  if $range == null { return true }
  $range | split row ',' | each { str trim } | where $it != '' | all {|c|
    let m = $c | parse -r '^(>=|<=|==|!=|>|<)?\s*(.+?)(\.\*)?$' | first
    let op = $m.capture0 | default '=='
    let r = if $m.capture2 == '.*' {
      if $v == $m.capture1 or ($v | str starts-with $"($m.capture1).") { 0 } else { version cmp $v $m.capture1 }
    } else { version cmp $v $m.capture1 }
    match $op { '==' | '' => ($r == 0), '!=' => ($r != 0), '>' => ($r > 0), '>=' => ($r >= 0), '<' => ($r < 0), '<=' => ($r <= 0) }
  }
}
