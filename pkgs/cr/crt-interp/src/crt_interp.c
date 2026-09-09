// Link-time relative-interpreter entry stub (x86_64, aarch64, riscv64; freestanding).
//
// Linked into a normal dynamic PIE that has *no* PT_INTERP. The linker entry
// point is __reloc_start (via -Wl,-e,__reloc_start). At process start we:
//   1. find our own path (/proc/self/exe, or AT_EXECFN if /proc is absent), take dirname
//   2. find our disabled PT_INTERP (p_type flipped to PT_NULL post-link, .interp holds a
//      path relative to the executable's directory), open dirname + "/" + that path
//   3. mmap ld.so's PT_LOAD segments
//   4. flip the phdr back to PT_INTERP in memory (glibc wants to see one),
//      patch auxv: AT_BASE = ld.so base, AT_ENTRY = the real _start (crt1)
//   5. jump to ld.so's e_entry with the original, untouched initial stack
// ld.so then behaves exactly as if the kernel had loaded it as interpreter.
//
// -DRELOC_STUB builds the same code as a flat position-independent blob (reloc_stub.bin) that
// `reloc-fixup` implants into ELFs we did not link (upstream rustc, bun, deno): a header at offset 0
// carries the program's original e_entry (link-time vaddr, filled in by reloc-fixup) in place of
// the `_start` symbol reference.

typedef unsigned long u64;
typedef long i64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

#define AT_NULL 0
#define AT_PHDR 3
#define AT_BASE 7
#define AT_ENTRY 9
#define PT_LOAD 1
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define MAP_PRIVATE 2
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define O_RDONLY 0
#define O_CLOEXEC 02000000

typedef struct {
  u8 e_ident[16];
  u16 e_type, e_machine;
  u32 e_version;
  u64 e_entry, e_phoff, e_shoff;
  u32 e_flags;
  u16 e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Ehdr;
typedef struct {
  u32 p_type, p_flags;
  u64 p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
} Phdr;

#define AT_PHNUM 5
#define AT_PAGESZ 6
#define AT_EXECFN 31
#define AT_FDCWD -100
#define PT_NULL 0
#define PT_PHDR 6
#define PT_INTERP 3
#ifdef RELOC_STUB
// First bytes of reloc_stub.bin. reloc-fixup checks `magic`, formatelf writes `entry` into the
// implanted copy. volatile: the compiler must load it, not fold the 0 it sees here.
struct StubHeader {
  char magic[8];
  u64 entry;
};
__attribute__((section(".text.header"), used, visibility("hidden")))
const volatile struct StubHeader reloc_stub_header = {{'R', 'E', 'L', 'O', 'C', 'S', 'T', 'B'}, 0};
#else
// The real program entry (crt1.o). Hidden so its address is formed pc-relative: nothing is relocated
// yet when we run, a GOT load (aarch64/riscv64 default for extern symbols) would read 0.
extern void _start(void) __attribute__((visibility("hidden")));
#endif

#if defined(__x86_64__)
#define SYS_openat 257
#define SYS_close 3
#define SYS_write 1
#define SYS_pread64 17
#define SYS_readlinkat 267
#define SYS_mmap 9
#define SYS_mprotect 10
#define SYS_exit 60
static inline i64 sys(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
  i64 r;
  register i64 r10 __asm__("r10") = d;
  register i64 r8 __asm__("r8") = e;
  register i64 r9 __asm__("r9") = f;
  __asm__ volatile("syscall"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
                   : "rcx", "r11", "memory");
  return r;
}
#else  // aarch64 and riscv64 share the generic syscall table
#define SYS_openat 56
#define SYS_close 57
#define SYS_write 64
#define SYS_pread64 67
#define SYS_readlinkat 78
#define SYS_mmap 222
#define SYS_mprotect 226
#define SYS_exit 93
static inline i64 sys(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
#if defined(__aarch64__)
  register i64 x8 __asm__("x8") = n;
  register i64 x0 __asm__("x0") = a;
  register i64 x1 __asm__("x1") = b;
  register i64 x2 __asm__("x2") = c;
  register i64 x3 __asm__("x3") = d;
  register i64 x4 __asm__("x4") = e;
  register i64 x5 __asm__("x5") = f;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
  return x0;
#elif defined(__riscv)
  register i64 a7 __asm__("a7") = n;
  register i64 a0 __asm__("a0") = a;
  register i64 a1 __asm__("a1") = b;
  register i64 a2 __asm__("a2") = c;
  register i64 a3 __asm__("a3") = d;
  register i64 a4 __asm__("a4") = e;
  register i64 a5 __asm__("a5") = f;
  __asm__ volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5) : "memory");
  return a0;
#else
#error unsupported architecture
#endif
}
#endif

static u64 slen(const char* s) {
  u64 n = 0;
  while (s[n]) n++;
  return n;
}
static void die(const char* m) {
  sys(SYS_write, 2, (i64) "reloc-interp: ", 14, 0, 0, 0);
  sys(SYS_write, 2, (i64)m, slen(m), 0, 0, 0);
  sys(SYS_write, 2, (i64) "\n", 1, 0, 0, 0);
  sys(SYS_exit, 127, 0, 0, 0, 0, 0);
}

__attribute__((used)) static u64 reloc_main(u64* sp, u64 pagesz_unused) {
  // walk initial stack: argc, argv..., NULL, envp..., NULL, auxv
  u64 argc = sp[0];
  u64* p = sp + 1 + argc + 1;
  while (*p) p++;
  u64* auxv = p + 1;

  // locate own phdrs and the disabled interp entry
  Phdr* self_ph = 0;
  u64 self_phnum = 0;
  u64 PG = 4096;
  const char* execfn = 0;
  for (u64* a = auxv; a[0] != AT_NULL; a += 2) {
    if (a[0] == AT_PHDR) self_ph = (Phdr*)a[1];
    if (a[0] == AT_PHNUM) self_phnum = a[1];
    if (a[0] == AT_PAGESZ) PG = a[1];  // 16K/64K pages on some aarch64 kernels
    if (a[0] == AT_EXECFN) execfn = (const char*)a[1];
  }
  if (!self_ph) die("no AT_PHDR");
  u64 self_bias = 0;
  int have_phdr = 0;
  Phdr* interp_ph = 0;
  for (u64 i = 0; i < self_phnum; i++) {
    if (self_ph[i].p_type == PT_PHDR) {
      self_bias = (u64)self_ph - self_ph[i].p_vaddr;
      have_phdr = 1;
    }
    if (self_ph[i].p_type == PT_NULL && self_ph[i].p_filesz > 1) interp_ph = &self_ph[i];
  }
  if (!interp_ph) die("no disabled PT_INTERP (PT_NULL with contents) found");
#ifdef RELOC_STUB
  // reloc-fixup always leaves a PT_PHDR in implanted files, so the bias is exact for ET_EXEC too
  if (!have_phdr) die("no PT_PHDR");
  u64 real_entry = self_bias + reloc_stub_header.entry;
#else
  (void)have_phdr;
  u64 real_entry = (u64)&_start;
#endif
  const char* rel = (const char*)(self_bias + interp_ph->p_vaddr);

  // 1. own path. /proc/self/exe is symlink-resolved and absolute. AT_EXECFN is whatever execve got
  // (may be relative to cwd, which is still unchanged here, or via a symlink) — good enough as the
  // fallback for early boot / containers without /proc.
  char path[4096];
  i64 n = sys(SYS_readlinkat, AT_FDCWD, (i64) "/proc/self/exe", (i64)path, sizeof path - 1, 0, 0);
  if (n <= 0) {
    if (!execfn) die("neither /proc/self/exe nor AT_EXECFN");
    n = (i64)slen(execfn);
    if ((u64)n >= sizeof path) die("path too long");
    for (i64 i = 0; i < n; i++) path[i] = execfn[i];
  }
  // dirname
  while (n > 0 && path[n - 1] != '/') n--;
  // append relative interp (absolute also tolerated)
  u64 rl = slen(rel);
  if (rel[0] == '/') n = 0;
  if ((u64)n + rl + 1 > sizeof path) die("path too long");
  for (u64 i = 0; i <= rl; i++) path[n + i] = rel[i];

  // 2. open + read headers
  i64 fd = sys(SYS_openat, AT_FDCWD, (i64)path, O_RDONLY | O_CLOEXEC, 0, 0, 0);
  if (fd < 0) die("cannot open interpreter (relative path)");
  union {
    Ehdr eh;
    u8 raw[4096];
  } hdr;
  if (sys(SYS_pread64, fd, (i64)&hdr, sizeof hdr, 0, 0, 0) < (i64)sizeof(Ehdr)) die("short read");
  Ehdr* eh = &hdr.eh;
  if (eh->e_phoff + (u64)eh->e_phnum * sizeof(Phdr) > sizeof hdr) die("phdrs out of first page");
  Phdr* ph = (Phdr*)(hdr.raw + eh->e_phoff);

  // 3. reserve address range covering all PT_LOADs, then map each segment
  u64 lo = ~0UL, hi = 0;
  for (int i = 0; i < eh->e_phnum; i++)
    if (ph[i].p_type == PT_LOAD) {
      if (ph[i].p_vaddr < lo) lo = ph[i].p_vaddr;
      if (ph[i].p_vaddr + ph[i].p_memsz > hi) hi = ph[i].p_vaddr + ph[i].p_memsz;
    }
  lo &= ~(PG - 1);
  hi = (hi + PG - 1) & ~(PG - 1);
  i64 base = sys(SYS_mmap, 0, hi - lo, 0, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base < 0 && base > -4096) die("mmap reserve failed");
  u64 bias = (u64)base - lo;
  for (int i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type != PT_LOAD) continue;
    u64 seg_start = (ph[i].p_vaddr & ~(PG - 1));
    u64 off = ph[i].p_offset & ~(PG - 1);
    u64 file_end = ph[i].p_vaddr + ph[i].p_filesz;
    u64 mem_end = ph[i].p_vaddr + ph[i].p_memsz;
    int prot = ((ph[i].p_flags & 4) ? PROT_READ : 0) | ((ph[i].p_flags & 2) ? PROT_WRITE : 0) |
               ((ph[i].p_flags & 1) ? PROT_EXEC : 0);
    u64 map_len = ((file_end + PG - 1) & ~(PG - 1)) - seg_start;
    if (map_len && sys(SYS_mmap, bias + seg_start, map_len, prot, MAP_PRIVATE | MAP_FIXED, fd, off) < 0)
      die("mmap segment failed");
    if (mem_end > file_end) {
      // zero tail of last file page, then anonymous pages for the rest of bss
      if (prot & PROT_WRITE) {
        u8* z = (u8*)(bias + file_end);
        u64 e = (file_end + PG - 1) & ~(PG - 1);
        while ((u64)z < bias + e && (u64)z < bias + mem_end) *z++ = 0;
      }
      u64 anon_start = (file_end + PG - 1) & ~(PG - 1);
      u64 anon_end = (mem_end + PG - 1) & ~(PG - 1);
      if (anon_end > anon_start && sys(SYS_mmap, bias + anon_start, anon_end - anon_start, prot,
                                       MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS, -1, 0) < 0)
        die("mmap bss failed");
    }
  }
  sys(SYS_close, fd, 0, 0, 0, 0, 0);

  // 4. re-enable PT_INTERP in our in-memory phdrs, patch auxv
  u64 pg_lo = (u64)interp_ph & ~(PG - 1), pg_hi = ((u64)interp_ph + sizeof(Phdr) + PG - 1) & ~(PG - 1);
  if (sys(SYS_mprotect, pg_lo, pg_hi - pg_lo, PROT_READ | PROT_WRITE, 0, 0, 0) < 0) die("mprotect phdr rw");
  interp_ph->p_type = PT_INTERP;
  sys(SYS_mprotect, pg_lo, pg_hi - pg_lo, PROT_READ, 0, 0, 0);
  int have_base = 0, have_entry = 0;
  for (u64* a = auxv; a[0] != AT_NULL; a += 2) {
    if (a[0] == AT_BASE) {
      a[1] = bias;
      have_base = 1;
    }
    if (a[0] == AT_ENTRY) {
      a[1] = real_entry;
      have_entry = 1;
    }
  }
  if (!have_base || !have_entry) die("auxv lacks AT_BASE/AT_ENTRY");

  // 5. return ld.so entry. The asm below restores sp and jumps
  return bias + eh->e_entry;
}

#if defined(__x86_64__)
__asm__(
    ".section .text.entry,\"ax\"\n.globl __reloc_start\n.type __reloc_start,@function\n"
    "__reloc_start:\n"
    "  mov %rsp, %r12\n"  // keep pristine initial stack pointer (callee-saved)
    "  mov %rsp, %rdi\n"
    "  and $-16, %rsp\n"  // ABI alignment for the C call
    "  call reloc_main\n"
    "  mov %r12, %rsp\n"  // original stack: argc at (%rsp), exactly as the kernel left it
    "  xor %edx, %edx\n"  // rdx = rtld_fini = 0 as at kernel entry
    "  jmp *%rax\n"       // enter ld.so
);
#elif defined(__aarch64__)
__asm__(
    ".section .text.entry,\"ax\"\n.globl __reloc_start\n.type __reloc_start,%function\n"
    "__reloc_start:\n"
    "  bti c\n"
    "  mov x19, sp\n"  // callee-saved copy of the initial sp
    "  mov x0, sp\n"
    "  and sp, x0, #-16\n"
    "  bl reloc_main\n"
    "  mov sp, x19\n"
    "  mov x16, x0\n"
    "  mov x0, #0\n"  // x0 = rtld_fini = 0 as at kernel entry
    "  br x16\n");
#elif defined(__riscv)
__asm__(
    ".section .text.entry,\"ax\"\n.globl __reloc_start\n.type __reloc_start,@function\n"
    "__reloc_start:\n"
    "  mv s1, sp\n"  // callee-saved copy of the initial sp
    "  mv a0, sp\n"
    "  andi sp, sp, -16\n"
    "  call reloc_main\n"
    "  mv sp, s1\n"
    "  mv t0, a0\n"
    "  li a0, 0\n"  // a0 = rtld_fini = 0 as at kernel entry
    "  jr t0\n");
#endif
