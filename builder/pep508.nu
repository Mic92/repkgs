# The subset of PEP 508 environment markers uv writes into uv.lock:
#   python_version / python_full_version / sys_platform / platform_machine / … compared with
#   == != < <= > >= ~= in "not in", combined with and / or / not and parentheses.
# `vars` supplies the variable values (fetch-pypi.nu builds it for our platform and python).

# true when `marker` holds for `vars`
export def evaluate [marker: string, vars: record]: nothing -> bool {
  let tokens = (tokenize (substitute $marker $vars))
  (parse-or $tokens 0).value
}

# replace every marker variable with its quoted value, so only literals and operators remain
def substitute [marker: string, vars: record]: nothing -> string {
  # platform_python_implementation is the one variable whose name differs from our vars key
  let text = ($marker | str replace -a platform_python_implementation implementation_cap)
  $vars | transpose name value | reduce --fold $text {|var, acc|
    $acc | str replace -ar $"\\b($var.name)\\b" $"'($var.value)'"
  }
}

def tokenize [text: string]: nothing -> list<string> {
  $text | parse -r "('[^']*'|\\(|\\)|\\bnot in\\b|\\bin\\b|\\band\\b|\\bor\\b|\\bnot\\b|===|==|!=|<=|>=|~=|<|>)" | get capture0
}

# recursive descent: or > and > atom; each returns the value and the index of the next token
def parse-or [tokens: list<string>, start: int]: nothing -> record<value: bool, next: int> {
  mut acc = (parse-and $tokens $start)
  while (peek $tokens $acc.next) == or {
    let rhs = (parse-and $tokens ($acc.next + 1))
    $acc = {value: ($acc.value or $rhs.value), next: $rhs.next}
  }
  $acc
}

def parse-and [tokens: list<string>, start: int]: nothing -> record<value: bool, next: int> {
  mut acc = (parse-atom $tokens $start)
  while (peek $tokens $acc.next) == and {
    let rhs = (parse-atom $tokens ($acc.next + 1))
    $acc = {value: ($acc.value and $rhs.value), next: $rhs.next}
  }
  $acc
}

# ( expr ) | not atom | 'lhs' op 'rhs'
def parse-atom [tokens: list<string>, start: int]: nothing -> record<value: bool, next: int> {
  match (peek $tokens $start) {
    "(" => { let inner = (parse-or $tokens ($start + 1)); {value: $inner.value, next: ($inner.next + 1)} }
    "not" => { let inner = (parse-atom $tokens ($start + 1)); {value: (not $inner.value), next: $inner.next} }
    _ => {
      let lhs = ($tokens | get $start | str trim -c "'")
      let op = ($tokens | get ($start + 1))
      let rhs = ($tokens | get ($start + 2) | str trim -c "'")
      {value: (compare $lhs $op $rhs), next: ($start + 3)}
    }
  }
}

def peek [tokens: list<string>, i: int]: nothing -> oneof<string, nothing> { $tokens | get -o $i }

# string operators always; ordering only between version-looking operands (PEP 440 release segments)
def compare [lhs: string, op: string, rhs: string]: nothing -> bool {
  match $op {
    "in" => ($rhs has $lhs)
    "not in" => ($rhs not-has $lhs)
    _ if not ($lhs =~ '^\d' and $rhs =~ '^\d') => (match $op { "==" => ($lhs == $rhs), "!=" => ($lhs != $rhs), _ => false })
    "~=" => ((version-order $lhs $rhs) >= 0 and (release $lhs | take ((release $rhs | length) - 1)) == (release $rhs | drop))
    _ => {
      let order = (version-order $lhs $rhs)
      match $op { "==" => ($order == 0), "!=" => ($order != 0), "<" => ($order < 0), "<=" => ($order <= 0), ">" => ($order > 0), ">=" => ($order >= 0), _ => false }
    }
  }
}

# "3.14.7" -> [3 14 7]; a non-numeric tail in a component counts as 0 ("3.14.0rc1" -> [3 14 0])
def release [version: string]: nothing -> list<int> {
  $version | split row "." | each { parse -r '^(\d+)' | get -o capture0.0 | default "0" | into int }
}

# -1 / 0 / 1, shorter versions zero-padded
def version-order [lhs: string, rhs: string]: nothing -> int {
  let a = (release $lhs)
  let b = (release $rhs)
  let width = ([($a | length) ($b | length)] | math max)
  let pad = {|v: list<int>| $v ++ (1..($width - ($v | length)) | each { 0 }) }
  (do $pad $a) | zip (do $pad $b) | each {|pair| if $pair.0 < $pair.1 { -1 } else if $pair.0 > $pair.1 { 1 } else { 0 } }
    | where $it != 0 | get -o 0 | default 0
}
