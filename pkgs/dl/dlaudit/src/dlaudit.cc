// rtld-audit(7) module: names a dlopen that found nothing. The dynamic loader asks
// la_objsearch for every name it looks up and tells la_objopen about every object it maps.
// A search by soname with no open before the next search or exit was a failed dlopen: those
// go to $DLAUDIT_OUT as "<name>\n". Names with a slash (gconv modules, plugins by path) fail
// loudly on their own; glibc's optional loads by soname (nss, libidn2, libgcc_s for unwinding)
// are not the package's business.
//
// Loaded into a namespace of its own before libc is fully up and run inside the loader's lock:
// no allocation, no iostreams, no exceptions, nothing but string_view over fixed buffers and
// raw syscalls. Built -nostdlib++ so it drags no libc++ into the audited process.
#include <fcntl.h>
#include <link.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <string_view>

namespace {

constexpr std::array<std::string_view, 4> kGlibcOwn{"libnss_", "libnsl", "libidn2", "libgcc_s.so"};
constexpr size_t kMaxName = 255;

// the module's whole state: process-global by nature (one loader, callbacks serialised by its lock)
struct State {
  int out = -1;
  std::array<char, kMaxName + 1> pending{};  // soname searched and not yet opened, then '\n'
  size_t pending_len = 0;
};
State g_state;  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

auto Ignored(std::string_view name) -> bool {
  return name.contains('/') || name.size() > kMaxName ||
         std::ranges::any_of(kGlibcOwn, [&](std::string_view own) -> bool { return name.starts_with(own); });
}

void Flush() {
  if (g_state.pending_len > 0 && g_state.out >= 0) {
    // pending_len <= kMaxName by Ignored(); at() would pull libc++'s verbose_abort into the .so
    g_state.pending[g_state.pending_len] = '\n';  // NOLINT(cppcoreguidelines-pro-bounds-constant-array-index)
    // a short write loses one diagnostic line of a build that is failing anyway
    static_cast<void>(::write(g_state.out, g_state.pending.data(), g_state.pending_len + 1));
  }
  g_state.pending_len = 0;
}

auto Pending() -> std::string_view { return {g_state.pending.data(), g_state.pending_len}; }

}  // namespace

// NOLINTBEGIN(readability-identifier-naming): names fixed by rtld-audit(7)
extern "C" {

auto la_version(unsigned version) -> unsigned {
  if (const char* path = std::getenv("DLAUDIT_OUT")) {  // NOLINT(concurrency-mt-unsafe): loader init, single thread
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-vararg): open(2)
    g_state.out = ::open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
  }
  return version;
}

// LA_SER_ORIG is the name as dlopen/DT_NEEDED gave it, later flags are the loader trying
// directories for that same name
auto la_objsearch(const char* name, uintptr_t* /*cookie*/, unsigned flag) -> char* {
  if (flag == LA_SER_ORIG) {
    Flush();
    const std::string_view wanted(name);
    if (!Ignored(wanted)) {
      std::ranges::copy(wanted, g_state.pending.begin());
      g_state.pending_len = wanted.size();
    }
  }
  return const_cast<char*>(name);  // NOLINT(cppcoreguidelines-pro-type-const-cast): the interface's signature
}

// opened under its soname or a versioned alias of what was asked (libfoo.so -> libfoo.so.1)
auto la_objopen(struct link_map* map, Lmid_t /*lmid*/, uintptr_t* /*cookie*/) -> unsigned {
  std::string_view opened(map->l_name);
  if (const size_t slash = opened.rfind('/'); slash != std::string_view::npos) {
    opened.remove_prefix(slash + 1);
  }
  if (g_state.pending_len > 0 && opened.starts_with(Pending())) {
    g_state.pending_len = 0;
  }
  return 0;
}

// DT_NEEDED phase over: anything pending there already failed loudly
void la_preinit(uintptr_t* /*cookie*/) { Flush(); }

[[gnu::destructor]] void dlaudit_fini() { Flush(); }
}
// NOLINTEND(readability-identifier-naming)
