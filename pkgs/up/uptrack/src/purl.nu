# Package-URL, https://github.com/package-url/purl-spec: pkg:type/namespace/name@version?k=v&k=v#subpath
# We use purls as identities only: version and subpath are accepted and dropped.

export def "purl parse" [s: string]: nothing -> record<type: string, namespace: string, name: string, qualifiers: record> {
  let m = $s | str trim | parse -r '^(?i)pkg:/*(?<type>[^/]+)/(?<path>[^?#]+?)(?:\?(?<q>[^#]*))?(?:#.*)?$'
  if ($m | is-empty) { error make {msg: $"not a purl: ($s)"} }
  let m = $m | first
  let segs = $m.path | split row '/' | where $it != '' | each { url decode }
  {
    type: $m.type
    namespace: ($segs | drop 1 | str join '/')
    name: ($segs | last | str replace -r '@.*$' '')
    qualifiers: ($m.q? | default "" | parse -r '(?<k>[^&=]+)=(?<v>[^&]*)' | each {|kv| [$kv.k ($kv.v | url decode)] } | into record)
  }
}
