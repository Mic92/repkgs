# The declarative part of MSBuild, enough to read what a .vcxproj compiles and links.
#
#   evaluate file seeds -> {props, itemdefs, items, targets}
#
# props     record   name -> string
# itemdefs  record   item type -> default metadata record       (<ItemDefinitionGroup>)
# items     table    {type, include, path, meta}                (<ItemGroup>)
# targets   record   name -> child elements, unevaluated        (<Target>, for sub-projects)
#
# Evaluation is one pass in document order, following <Import>s, honouring Condition="…".
# Not implemented: targets/tasks, and property functions (`$([Class]::F())`, `$(Registry:…)`).
# A property computed by one stays unset, a condition using one counts as false. The caller
# seeds what the build needs: `seeds` are MSBuild global properties (the project cannot override
# them), `itemdefs` what the toolset's own .props would define (%(AdditionalDependencies))

export def evaluate [file: path, seeds: record, --itemdefs: record = {}]: nothing -> record {
  let name = ($file | path parse | get stem)
  {props: ({MSBuildProjectName: $name, ProjectName: $name} | merge $seeds), itemdefs: $itemdefs, items: [], targets: {}, seeded: ($seeds | columns)}
  | eval-file $file
  | reject seeded
}

# what a traversal project (pcbuild.proj, dirs.proj) hands to <MSBuild Projects="…"> in `target`
export def sub-projects [r: record, target: string, dir: string]: nothing -> list<string> {
  $r.targets | get -o $target | default []
  | where tag == MSBuild
  | where { passes $in $r.props $dir }
  | each {|t| split-list (expand (item-refs $t.attributes.Projects $r.items) $r.props) }
  | flatten | uniq
  | each { win-path $in $dir }
}

# a\b\c relative to the project directory -> POSIX path
export def win-path [p: string, dir: string]: nothing -> string {
  let s = ($p | str replace -a '\' '/')
  if ($s | str starts-with "/") { $s } else { $dir | path join $s | path expand -n }
}

# --- elements ---------------------------------------------------------------------------------

def eval-file [file: path]: record -> record {
  let st = $in
  let dir = ($file | path dirname)
  let outer = ($st.props.MSBuildThisFileDirectory? | default $"($dir)/")
  $st
  | upsert props.MSBuildThisFileDirectory $"($dir)/"
  | eval-elements (elements (open --raw $file | from xml)) $dir
  | upsert props.MSBuildThisFileDirectory $outer
}

def eval-elements [nodes: list<record>, dir: string]: record -> record {
  let st = $in
  $nodes | reduce -f $st {|n, s| $s | eval-element $n $dir }
}

def eval-element [n: record, dir: string]: record -> record {
  let st = $in
  if not (passes $n $st.props $dir) { return $st }
  match $n.tag {
    "PropertyGroup" => ($st | set-properties (elements $n) $dir)
    "ItemDefinitionGroup" => ($st | set-itemdefs (elements $n) $dir)
    "ItemGroup" => ((elements $n) | reduce -f $st {|it, s| $s | eval-item $it $dir })
    "ImportGroup" => ($st | eval-elements (elements $n) $dir)
    "Import" => ($st | import (expand $n.attributes.Project $st.props) $dir)
    "Target" => ($st | upsert targets ($st.targets | upsert $n.attributes.Name (elements $n)))
    _ => $st
  }
}

# $(VCTargetsPath)\Microsoft.Cpp.* is the toolset itself, which the caller stands in for
def import [project: string, dir: string]: record -> record {
  let st = $in
  let f = (win-path $project $dir)
  if $f =~ '/Microsoft\.Cpp[^/]*$|\.targets$' or not ($f | path exists) { $st } else { $st | eval-file $f }
}

def set-properties [nodes: list<record>, dir: string]: record -> record {
  let st = $in
  $nodes | reduce -f $st {|p, s|
    if $p.tag in $s.seeded or not (passes $p $s.props $dir) { return $s }
    match (try { expand (text-of $p) $s.props }) {
      null => $s
      $v => ($s | upsert props ($s.props | upsert $p.tag $v))
    }
  }
}

def set-itemdefs [nodes: list<record>, dir: string]: record -> record {
  let st = $in
  $nodes | reduce -f $st {|t, s|
    if not (passes $t $s.props $dir) { return $s }
    let sofar = ($s.itemdefs | get -o $t.tag | default {})
    $s | upsert itemdefs ($s.itemdefs | upsert $t.tag (metadata $t $sofar $s.props $dir))
  }
}

# <T Include="a;b*" Exclude="c"><M>v</M></T> adds items, <T Condition="…%(Filename)…"><M>v</M></T> edits existing ones
def eval-item [it: record, dir: string]: record -> record {
  let st = $in
  if ($it.attributes | get -o Include) == null { $st | update-items $it $dir } else if (passes $it $st.props $dir) { $st | add-items $it $dir } else { $st }
}

def add-items [it: record, dir: string]: record -> record {
  let st = $in
  let excluded = (item-paths ($it.attributes | get -o Exclude | default "") $st $dir | get path)
  let defaults = ($st.itemdefs | get -o $it.tag | default {} | merge ($it.attributes | reject -o Include Exclude Condition Label))
  let has_meta = (elements $it | is-not-empty)
  let new = (item-paths $it.attributes.Include $st $dir
    | where { $in.path not-in $excluded }
    | each {|f|
      let item = {type: $it.tag, include: $f.include, path: $f.path, meta: $defaults}
      if $has_meta { $item | with-metadata $it $st.props $dir } else { $item }
    })
  $st | upsert items ($st.items ++ $new)
}

def update-items [it: record, dir: string]: record -> record {
  let st = $in
  $st | upsert items ($st.items | each {|item|
    let hit = ($item.type == $it.tag and (passes $it $st.props $dir (well-known $item)))
    if $hit { $item | with-metadata $it $st.props $dir } else { $item }
  })
}

# "a;$(Dir)\*.c;@(Refs)" -> [{include, path}], globs expanded
def item-paths [spec: string, st: record, dir: string]: nothing -> list<record> {
  split-list (expand (item-refs $spec $st.items) $st.props)
  | each {|p|
    let f = (win-path $p $dir)
    let matches = (if $p =~ '[*?]' { glob $f } else { [$f] })
    $matches | each {|m| {include: $p, path: $m} }
  }
  | flatten
}

const WELL_KNOWN = [Identity FullPath Filename Extension]

# an item's metadata after the element's <M>v</M> children, which may read %(FullPath) & co.
def with-metadata [it: record, props: record, dir: string]: record -> record {
  let item = $in
  $item | upsert meta (metadata $it (well-known $item) $props $dir | reject -o ...$WELL_KNOWN)
}

def well-known [item: record]: nothing -> record {
  let f = ($item.path | path parse)
  $item.meta | merge {Identity: $item.include, FullPath: $item.path, Filename: $f.stem, Extension: $".($f.extension)"}
}

# child elements <M>v</M> merged onto `base` in order, each seeing the record so far as %(M)
def metadata [node: record, base: record, props: record, dir: string]: nothing -> record {
  elements $node | reduce -f $base {|m, acc|
    if (passes $m $props $dir $acc) { $acc | upsert $m.tag (expand (text-of $m) $props $acc | str trim) } else { $acc }
  }
}

def passes [n: record, props: record, dir: string, meta: record = {}]: nothing -> bool {
  match ($n.attributes | get -o Condition | default "") {
    "" => true
    $c => (try { condition $c $props $dir $meta } catch { false })
  }
}

def elements [node: record]: nothing -> list<record> { $node.content | where tag != null }

def text-of [node: record]: nothing -> string { $node.content | where tag == null | get content | str join "" | str trim }

def split-list [s: string]: nothing -> list<string> { $s | split row ";" | each { str trim } | compact -e }

# --- expressions ------------------------------------------------------------------------------

# "a$(B)c%(D)" -> [{kind: text, s: a} {kind: prop, s: B} {kind: text, s: c} {kind: meta, s: D}].
# A paren counter rather than a regex: references nest, $(X.Substring(0, $(N)))
def segments [s: string]: nothing -> list<record<kind: string, s: string>> {
  mut out = []
  mut buf = ""
  mut depth = 0
  mut kind = "text"
  for ch in ($s | split chars) {
    if $depth > 0 {
      $depth += ({"(": 1, ")": -1} | get -o $ch | default 0)
      if $depth == 0 { $out ++= [{kind: $kind, s: $buf}]; $buf = "" } else { $buf += $ch }
    } else if $ch == "(" and $buf =~ '[$%]$' {
      $kind = (if ($buf | str ends-with '$') { "prop" } else { "meta" })
      $out ++= [{kind: text, s: ($buf | str substring ..<(-1))}]
      $buf = ""
      $depth = 1
    } else {
      $buf += $ch
    }
  }
  $out ++ [{kind: text, s: $buf}] | where { $in.kind != text or $in.s != "" }
}

# $(Name), $(Name.Method(args)), %(Meta). Unknown names are "" as in MSBuild
def expand [s: string, props: record, meta: record = {}]: nothing -> string {
  segments $s | each {|seg|
    match $seg.kind {
      "text" => $seg.s
      "meta" => ($meta | get -o $seg.s | default "")
      "prop" => {
        let e = (expand $seg.s $props $meta)
        if $e =~ '^\w+$' { $props | get -o $e | default "" } else { string-method $e $props }
      }
    }
  } | str join ""
}

# the `Prop.Method(args)` calls project files make on paths and names
def string-method [e: string, props: record]: nothing -> string {
  let m = ($e | parse -r '^(?<p>\w+)\.(?<f>\w+)\((?<a>.*)\)$' | get -o 0)
  if $m == null { error make {msg: $"msbuild: cannot evaluate $\(($e)\)"} }
  let v = ($props | get -o $m.p | default "")
  let a = ($m.a | split row "," | each { str trim | str trim -c '`' | str trim -c "'" | str trim -c '"' })
  match $m.f {
    "Replace" => ($v | str replace -a $a.0 $a.1)
    "Trim" => ($v | str trim -c ($a.0 | default -e " "))
    "TrimEnd" => ($v | str trim -r -c $a.0)
    "StartsWith" => ($v | str starts-with $a.0 | into string)
    "EndsWith" => ($v | str ends-with $a.0 | into string)
    "LastIndexOf" => ($v | str index-of -e $a.0 | into string)
    "Substring" => {
      let from = ($a.0 | into int)
      if ($a | length) == 1 { $v | str substring $from.. } else { $v | str substring $from..<($from + ($a.1 | into int)) }
    }
    _ => (error make {msg: $"msbuild: cannot evaluate $\(($e)\)"})
  }
}

# @(Type) and @(Type->'…%(Identity)…') inside an Include: the items of that type so far
def item-refs [spec: string, items: list]: nothing -> string {
  $spec
  | str replace -ar r#'@\((\w+)\)'# "@($1->'%(Identity)')"
  | split row "@("
  | enumerate
  | each {|seg|
    if $seg.index == 0 { return $seg.item }
    let m = ($seg.item | parse -r r#'^(?<t>\w+)->'(?<pat>[^']*)'\)(?<rest>.*)$'# | first)
    let expanded = ($items | where type == $m.t | each {|x| $m.pat | str replace -a "%(Identity)" $x.include } | str join ";")
    $expanded + $m.rest
  }
  | str join ""
}

# --- conditions -------------------------------------------------------------------------------
#
# Condition="…" grammar:  or > and > ! > ( ) | Exists('p') | HasTrailingSlash('p') | a == b | a != b | a
# Operands are 'quoted text with $(refs)', a bare $(ref), or a bare word; compared case-insensitively.
# The string is tokenised *before* expansion so a bare $(X) that expands to "" is still an operand.

const OPERATORS = ["==" "!=" "(" ")" "!"]

def condition [c: string, props: record, dir: string, meta: record = {}]: nothing -> bool {
  let tokens = (tokens $c | each {|t|
    if $t in $OPERATORS or ($t | str lowercase) in [and or] { $t } else { {v: (expand ($t | str trim -c "'") $props $meta)} }
  })
  (parse-or $tokens 0 $dir).v
}

# operators, words, and '…' literals; a $(ref)/%(ref) is one token, or part of the literal it sits in
def tokens [c: string]: nothing -> list<string> {
  segments $c | reduce -f [] {|seg, acc|
    let piece = (match $seg.kind { "text" => $seg.s, "prop" => $"$\(($seg.s)\)", "meta" => $"%\(($seg.s)\)" })
    let last = ($acc | last | default "")
    let open_literal = ($last =~ "^'" and $last !~ "^'.*'$")
    if not $open_literal {
      return ($acc ++ (if $seg.kind == "text" { lex $piece } else { [$piece] }))
    }
    # inside '…': a reference continues the literal; text continues it up to the closing quote
    let close = (if $seg.kind == "text" { $piece | str index-of "'" } else { -1 })
    if $close == -1 { return (($acc | drop) ++ [($last + $piece)]) }
    ($acc | drop) ++ [($last + ($piece | str substring ..$close))] ++ (lex ($piece | str substring ($close + 1)..))
  }
}

def lex [s: string]: nothing -> list<string> {
  $s | parse -r r#'(?<t>'[^']*'?|==|!=|\(|\)|!|[^\s()!=']+)'# | get t
}

# recursive descent; each returns {v: result, i: next token index}
def parse-or [toks: list, i: int, dir: string]: nothing -> record<v: bool, i: int> {
  mut r = (parse-and $toks $i $dir)
  while ($toks | get -o $r.i) in [or Or OR] {
    let n = (parse-and $toks ($r.i + 1) $dir)
    $r = {v: ($r.v or $n.v), i: $n.i}
  }
  $r
}

def parse-and [toks: list, i: int, dir: string]: nothing -> record<v: bool, i: int> {
  mut r = (parse-unary $toks $i $dir)
  while ($toks | get -o $r.i) in [and And AND] {
    let n = (parse-unary $toks ($r.i + 1) $dir)
    $r = {v: ($r.v and $n.v), i: $n.i}
  }
  $r
}

def parse-unary [toks: list, i: int, dir: string]: nothing -> record<v: bool, i: int> {
  let t = ($toks | get $i)
  if $t == "!" {
    let n = (parse-unary $toks ($i + 1) $dir)
    return {v: (not $n.v), i: $n.i}
  }
  if $t == "(" {
    let n = (parse-or $toks ($i + 1) $dir)
    return {v: $n.v, i: ($n.i + 1)}
  }
  let word = ($t.v | str lowercase)
  if $word in [exists hastrailingslash] {
    # fn ( 'arg' )
    let arg = ($toks | get ($i + 2)).v
    let v = (if $word == exists { win-path $arg $dir | path exists } else { $arg =~ '[\\/]$' })
    return {v: $v, i: ($i + 4)}
  }
  match ($toks | get -o ($i + 1)) {
    "==" => {v: ($word == (($toks | get ($i + 2)).v | str lowercase)), i: ($i + 3)}
    "!=" => {v: ($word != (($toks | get ($i + 2)).v | str lowercase)), i: ($i + 3)}
    _ => {v: ($word == "true"), i: ($i + 1)}
  }
}
