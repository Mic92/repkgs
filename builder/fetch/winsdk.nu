#!/usr/bin/env nu
# Producer for fetch.windowsSdk { manifest, arch }: VisualStudio.vsman (sources.toml) pins every
# payload by sha256. Selected like xwin: the newest VC CRT (headers with the STL, <arch> Desktop and
# Store libs) as .vsix, and from the newest Win11 SDK the header/lib/UCRT .msi plus all of its
# cabinets (an .msi names the ones it needs only inside itself; unused ones cost a download, not
# output). winsdk-assemble.nu unpacks.
use dyn-drv.nu

const MSIS = [
  "Windows SDK Desktop Headers x86", "Windows SDK Desktop Libs {arch}", "Windows SDK OnecoreUap Headers {arch}"
  "Windows SDK for Windows Store Apps Headers", "Windows SDK for Windows Store Apps Headers OnecoreUap"
  "Windows SDK for Windows Store Apps Libs", "Universal CRT Headers Libraries and Sources"
]

def newest []: list<string> -> string { sort-by -c {|a, b| ($a | split row "." | each { into int }) < ($b | split row "." | each { into int }) } | last }

def main []: nothing -> nothing {
  let arch = ({x86_64: x64, aarch64: arm64} | get -o $env.arch)
  if $arch == null { error make {msg: $"windows-sdk: Microsoft ships no ($env.arch) SDK"} }
  let pkgs = (open --raw $env.manifest | from json | get packages | where language? == null)
  let package = {|id: string| $pkgs | where id == $id | first }
  let crt = (do $package "Microsoft.VisualStudio.Product.BuildTools" | get dependencies | columns
    | parse -r '^Microsoft\.VisualStudio\.Component\.VC\.([\d.]+)\.x86\.x64$' | get capture0 | newest)
  let crt_arch = (if $arch == "arm64" { "ARM64" } else { $arch })
  let vsix = ([Headers $"($crt_arch).Desktop" $"($crt_arch).Store"] | each {|k| do $package $"Microsoft.VC.($crt).CRT.($k).base" | get payloads.0 | insert kind crt })
  let sdk_id = ($pkgs | get id | where $it =~ '^Win11SDK_[\d.]+$' | str replace "Win11SDK_" "" | newest | $"Win11SDK_($in)")
  let sdk = (do $package $sdk_id | get payloads | update fileName { str replace -a '\' "/" | path basename })
  let msis = ($MSIS | each {|n| $sdk | where fileName == $"($n | str replace '{arch}' $arch)-x86_en-us.msi" | first | insert kind msi })
  let cabs = ($sdk | where fileName =~ '\.cab$' | insert kind cab)
  let fetched = ($vsix ++ $msis ++ $cabs | rename -c {fileName: file} | select file url sha256 kind | dyn-drv fetchurls)
  print -e $"windowsSdk: CRT ($crt), ($sdk_id) for ($arch)"
  dyn-drv collect $"windows-sdk-($env.arch)" [] (($fetched | get drv) ++ [$env.sevenzip_drv]) --script winsdk-assemble.nu --attrs {sevenzip: $env.sevenzip, payloads: ($fetched | select file kind out)}
}
