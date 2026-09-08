# Cached GET: one JSON file per URL under $XDG_CACHE_HOME/uptrack/ with etag, last-modified and
# body, so a rerun is conditional requests answered by 304 (which GitHub does not rate-limit).

def cache-file [url: string]: nothing -> path {
  let d = $env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join uptrack
  mkdir $d
  $d | path join ($url | hash sha256)
}

# {status, body}. --max-age serves from cache without revalidating
export def "http cached" [url: string, --max-age: duration = 10min]: nothing -> record<status: int, body: any> {
  let f = cache-file $url
  let old = if ($f | path exists) { open $f | from json }
  if $old != null and ((date now) - ($old.fetched | into datetime)) < $max_age { return {status: 200, body: $old.body} }
  let host = $url | url parse | get host
  let hdrs = [
    (if $host == api.github.com and $env.GITHUB_TOKEN? != null { [Authorization $"Bearer ($env.GITHUB_TOKEN)"] })
    (if $old.etag? != null { [If-None-Match $old.etag] })
    (if $old.last_modified? != null { [If-Modified-Since $old.last_modified] })
    [User-Agent uptrack]
  ] | compact | flatten
  let r = http get --full --allow-errors --headers $hdrs $url
  if $r.status == 304 {
    $old | upsert fetched (date now | format date '%+') | to json | save -f $f
    return {status: 200, body: $old.body}
  }
  if $r.status >= 400 { return {status: $r.status, body: $r.body} }
  let hdr = {|n| $r.headers.response | where name == $n | get -o 0.value }
  let body = if ($r.body | describe) == binary { $r.body | decode } else { $r.body }
  {etag: (do $hdr etag), last_modified: (do $hdr last-modified), fetched: (date now | format date '%+'), body: $body} | to json | save -f $f
  {status: 200, body: $body}
}
