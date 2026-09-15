# One log line per event in Nix's structured-log form ("@nix {json}", libutil/logging.cc), so
# `nix build`/nom show the current phase and `nix log` keeps the text. `phase` events become the
# derivation's phase, everything else an info-level message. Shared by the builder and bootstrap
export def note [kind: string, msg: string = ""]: nothing -> nothing {
  let ev = if $kind == "phase" { {action: setPhase, phase: $msg} } else { {action: msg, level: 3, msg: $"($kind): ($msg)"} }
  print -e $"@nix ($ev | to json -r)"
}
