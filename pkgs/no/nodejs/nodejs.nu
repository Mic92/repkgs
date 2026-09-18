use core.nu *

const SHARED = [zlib openssl zstd brotli libuv nghttp2 cares sqlite]

# configure.py, not autoconf. Cross: code generators like mksnapshot are built for the target and
# run under qemu (--emulator, --no-cross-compiling). --cross-compiling would add gyp's host
# toolset, which generates a broken ninja file (two rules for js_protocol.stamp)
export def configure []: nothing -> nothing {
  let p = (ctx).platform
  let toolset = (if ($p.emulator | is-empty) { [--cross-compiling] } else { [--no-cross-compiling $"--emulator=($p.emulator | str join ' ')"] })
  let cross = (if $p.cross { [$"--dest-cpu=($p.names.gyp)" $"--dest-os=($p.osNames.gyp)" ...$toolset] } else { [] })
  # any JS under qemu-loongarch64 faults on a pointer with bits 40..63 set (V8 JIT or TCG bug), so
  # node_mksnapshot cannot run there. The snapshot only saves startup time
  let snapshot = (if $p.cpu == "loongarch64" { [--without-node-snapshot] } else { [] })
  (x python3 configure.py --prefix=/ --ninja ...($SHARED | each { $"--shared-($in)" })
    --with-intl=small-icu --without-corepack ...$cross ...$snapshot)
}

export def build []: nothing -> nothing {
  x ninja -C out/Release $"-j((ctx).njobs)"
}

export def install []: nothing -> nothing {
  x python3 tools/install.py install --dest-dir "" --prefix (ctx).out --build-dir out/Release
}
