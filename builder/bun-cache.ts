// Populates $BUN_INSTALL_CACHE_DIR from a fetch.bunDeps output so `bun install --offline` finds
// every package:  <cache>/<name>@<version>@@@1  ->  <deps>/p/<name>@<version>
// Versions with a pre-release or build part are not spelled literally: bun replaces those parts
// by their Wyhash11 (src/install/PackageManager/PackageManagerDirectories.zig), e.g.
// typescript@5.7.0-beta -> typescript@5.7.0-50d49428a66e9f35@@@1. That hash is why this runs
// under bun/TS rather than in nu; the algorithm is zig 0.11's std.hash.Wyhash, ported below.
//
// usage: bun bun-cache.ts <deps dir> <cache dir>     |     bun bun-cache.ts --print <name@version>
import { mkdirSync, symlinkSync } from "node:fs";
import { dirname, join } from "node:path";

const U64 = (1n << 64n) - 1n;
const PRIMES = [0xa0761d6478bd642fn, 0xe7037ed1a0b428dbn, 0x8ebc6af09c88c6e3n, 0x589965cc75374cc3n, 0x1d8e4e27c47d124fn];

const le = (b: Uint8Array, at: number, n: number): bigint => {
  let v = 0n;
  for (let i = n - 1; i >= 0; i--) v = (v << 8n) | BigInt(b[at + i]);
  return v;
};
// zig's read_8bytes_swapped: two LE u32 halves, high half first
const le8swapped = (b: Uint8Array, at: number): bigint => (le(b, at, 4) << 32n) | le(b, at + 4, 4);
const mum = (a: bigint, b: bigint): bigint => { const r = (a & U64) * (b & U64); return ((r >> 64n) ^ r) & U64; };
const mix0 = (a: bigint, b: bigint, seed: bigint): bigint => mum(a ^ seed ^ PRIMES[0], b ^ seed ^ PRIMES[1]);
const mix1 = (a: bigint, b: bigint, seed: bigint): bigint => mum(a ^ seed ^ PRIMES[2], b ^ seed ^ PRIMES[3]);

// 1..7 trailing bytes packed the way WyhashStateless.final does (4-, 2-, 1-byte reads, big end first)
function packTail(b: Uint8Array, at: number, n: number): bigint {
  let v = 0n, off = at;
  for (const width of [4, 2, 1]) {
    if (n & width) { v = (v << BigInt(8 * width)) | le(b, off, width); off += width; }
  }
  return v;
}

function wyhash11(text: string): bigint {
  const b = new TextEncoder().encode(text);
  let seed = 0n, at = 0;
  for (; at + 32 <= b.length; at += 32) {
    seed = mix0(le(b, at, 8), le(b, at + 8, 8), seed) ^ mix1(le(b, at + 16, 8), le(b, at + 24, 8), seed);
  }
  // remaining 0..31 bytes: up to three groups of 8 (read swapped) and a packed tail, folded as
  // mix0(first 16) ^ mix1(next 16); an absent second operand is PRIMES[4]
  const rest = b.length - at;
  const word = (i: number): bigint => {           // i-th 8-byte operand of the remainder
    const start = at + 8 * i, have = rest - 8 * i;
    return have >= 8 ? le8swapped(b, start) : have > 0 ? packTail(b, start, have) : PRIMES[4];
  };
  if (rest > 0) {
    seed = rest <= 16 ? mix0(word(0), word(1), seed) : mix0(word(0), word(1), seed) ^ mix1(word(2), word(3), seed);
  }
  return mum(seed ^ BigInt(b.length), PRIMES[4]);
}

const hex16 = (v: bigint): string => v.toString(16).padStart(16, "0");

// "name@1.2.3-pre+build" -> the directory name bun looks for
export function cacheDirName(id: string): string {
  const at = id.lastIndexOf("@");
  if (at <= 0) return `${id}@@@1`;
  const name = id.slice(0, at), version = id.slice(at + 1);
  const [core, build] = version.split("+", 2);
  const dash = core.indexOf("-");
  const release = dash < 0 ? core : core.slice(0, dash);
  const pre = dash < 0 ? undefined : core.slice(dash + 1);
  let spelled = release;
  if (pre !== undefined) spelled += `-${hex16(wyhash11(pre))}`;
  if (build !== undefined) spelled += `+${hex16(wyhash11(build)).toUpperCase()}`;
  return `${name}@${spelled}@@@1`;
}

if (import.meta.main) {
  const [first, second] = process.argv.slice(2);
  if (first === "--print") {
    console.log(cacheDirName(second));
  } else {
    const deps = first, cache = second;
    const index: { id: string; dir: string }[] = await Bun.file(join(deps, "index.json")).json();
    for (const entry of index) {
      const link = join(cache, cacheDirName(entry.id));
      mkdirSync(dirname(link), { recursive: true });
      symlinkSync(join(deps, entry.dir), link);
    }
  }
}
