# MacOSX.sdk out of the Command Line Tools package: xar -> Payload (pbzx-framed xz cpio) -> the
# SDK directory, laid out at $out so `-isysroot $out` works. Headers, .tbd stubs, libc++: all Apple's.
use ../../../bootstrap/lib.nu *

# -isysroot: libSystem, libc++ and the frameworks as .tbd stubs. The deployment target rides in the
# triple, ld64.lld ad-hoc signs arm64 output itself. -stdlib for both languages, so cxxflags is empty
const FLAGS = [-isysroot SYSROOT -resource-dir=SYSROOT/lib/clang -rtlib=compiler-rt -stdlib=libc++ --ld-path=LLD]

# pbzx: "pbzx", u64 flags, then {u64 flags, u64 size, xz stream} while flags bit 24 is set.
# The xz streams concatenated are one valid .xz, so only the framing goes.
const PBZX = "
import struct, sys
f, o = open(sys.argv[1], 'rb'), sys.stdout.buffer
assert f.read(4) == b'pbzx'
flags, = struct.unpack('>Q', f.read(8))
while flags & (1 << 24):
    flags, n = struct.unpack('>QQ', f.read(16))
    o.write(f.read(n))
"

def main []: nothing -> nothing {
  let tmp = $"($env.NIX_BUILD_TOP)/x"
  mkdir $tmp
  cd $tmp
  x bsdtar -xf $env.src Payload
  $PBZX | save pbzx.py
  ^python3 pbzx.py Payload | ^bsdtar -xf - "*/SDKs/MacOSX*.*.sdk/*"
  let sdk = (glob "Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk" | first)
  say $"($sdk | path basename) -> ($env.out)"
  # perl/man/bin are for running on a Mac
  rm -rf $"($sdk)/usr/share" $"($sdk)/usr/bin" $"($sdk)/System/Library/Perl"
  mv $sdk $env.out
  cc-facts $env.out {include-dirs: [usr/include], flags: $FLAGS, cxxflags: []}
}
