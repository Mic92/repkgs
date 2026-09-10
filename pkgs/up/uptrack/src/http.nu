# Cached GET: one JSON file per URL under $XDG_CACHE_HOME/uptrack/ with etag, last-modified and
# body, so a rerun is conditional requests answered by 304 (which GitHub does not rate-limit).

def cache-file [url: string]: nothing -> path {
  let d = $env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join uptrack
  mkdir $d
  $d | path join ($url | hash sha256)
}

# $GITHUB_TOKEN, else whatever `gh` is logged in with: 60 requests/h unauthenticated is ~30 packages
def github-token []: nothing -> oneof<string, nothing> {
  if $env.GITHUB_TOKEN? != null { return $env.GITHUB_TOKEN }
  if (which gh | is-empty) { return }
  let r = (^gh auth token | complete)
  if $r.exit_code == 0 { $r.stdout | str trim }
}

# {status, body}. --max-age serves from cache without revalidating
export def "http cached" [url: string, --max-age: duration = 10min]: nothing -> record<status: int, body: any> {
  let f = cache-file $url
  let old = if ($f | path exists) { open $f | from json }
  if $old != null and ((date now) - ($old.fetched | into datetime)) < $max_age { return {status: 200, body: $old.body} }
  let host = $url | url parse | get host
  let hdrs = [
    (if $host == api.github.com { let t = (github-token); if $t != null { [Authorization $"Bearer ($t)"] } })
    (if $old.etag? != null { [If-None-Match $old.etag] })
    (if $old.last_modified? != null { [If-Modified-Since $old.last_modified] })
    [User-Agent uptrack]
    # hackage serves html unless asked for json. github.com (not the API) answers 406 to json-only
    [Accept "application/json, */*;q=0.5"]
  ] | compact | flatten
  let r0 = http get --full --allow-errors --headers $hdrs $url
  # an org with SAML enforcement rejects a token not authorized for it, public data is still anonymous
  let r = if $r0.status == 403 and ($r0.body | to json) =~ "SAML" {
    http get --full --allow-errors --headers ($hdrs | window 2 --stride 2 | where $it.0 != Authorization | flatten) $url
  } else { $r0 }
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
