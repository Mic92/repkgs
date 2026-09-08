// `launch`: the one program behind every script and every wrapped binary (docs/design.md §3
// "shebangs, env wrappers").
//
// bin/foo is a symlink to ../../<hash>-launch/bin/launch (a static-pie store neighbour, like any
// runtime dependency). launch finds out *which* bin/foo it was started as, reads bin/.foo.launch
// next to it, and execs the described program. Everything in the record is relative to the package
// root ({root}) or a store neighbour ({store} = dirname of root), so the package and its closure
// relocate together. No shell is involved. Cost is one extra execve.
//
// Record (JSON, written by builder/core.nu `launchers`):
//   {"program": "{root}/libexec/foo"                or "{store}/<hash>-cpython/bin/python3",
//    "args":    ["{root}/bin/.foo.script"],        prepended before the user's args
//    "argv0":   "{self}",                          optional, default = program (interpreters
//                                                  derive their prefix from argv[0], as with #!)
//    "env":     {"PATH":  {"prepend": ["{store}/<hash>-jq/bin"], "sep": ":"},
//                "TZDIR": {"default": "{store}/<hash>-tzdata/share/zoneinfo"},
//                "FOO":   {"set": "bar"}, "BAR": {"unset": []}}}

#include <stdlib.h>  // NOLINT(modernize-deprecated-headers): setenv/unsetenv are POSIX, not <cstdlib>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <json.hpp>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using Json = nlohmann::json;

namespace {

constexpr int kMaxHops = 32;
constexpr int kExitLaunchFailure = 127;

[[noreturn]] void Die(std::string_view what, std::string_view arg = {}) {
  std::println(stderr, "launch: {}{}{}", what, arg.empty() ? "" : ": ", arg);
  std::_Exit(kExitLaunchFailure);
}

auto GetEnv(const std::string& name) -> std::optional<std::string> {
  const char* value = std::getenv(name.c_str());  // NOLINT(concurrency-mt-unsafe): single-threaded
  if (value == nullptr) {
    return std::nullopt;
  }
  return std::string(value);
}

void SetEnv(const std::string& name, const std::string& value) {
  setenv(name.c_str(), value.c_str(), 1);  // NOLINT(concurrency-mt-unsafe): single-threaded
}

// argv[0] as a path: as given when it has a '/', else looked up on PATH like the shell did.
auto Argv0Path(std::string_view argv0) -> fs::path {
  if (argv0.contains('/')) {
    return fs::absolute(argv0);
  }
  const auto path = GetEnv("PATH");
  if (!path) {
    Die("argv[0] has no '/' and PATH is unset", argv0);
  }
  for (size_t pos = 0; pos <= path->size();) {
    size_t end = path->find(':', pos);
    if (end == std::string::npos) {
      end = path->size();
    }
    const fs::path cand = fs::path(path->substr(pos, end - pos)) / argv0;
    if (access(cand.c_str(), X_OK) == 0) {
      return fs::absolute(cand);
    }
    pos = end + 1;
  }
  Die("not found on PATH", argv0);
}

// The per-program symlink <pkg>/bin/foo: follow argv[0]'s symlink chain hop by hop (profiles,
// result links) and stop at the hop whose *target* is named "launch". Its directory is
// canonicalized, its basename kept: that name selects the record.
auto InvokedPath(std::string_view argv0) -> fs::path {
  fs::path cur = Argv0Path(argv0);
  for (int hop = 0; hop < kMaxHops; ++hop) {
    std::error_code err;
    const fs::path target = fs::read_symlink(cur, err);
    if (err) {
      Die("not a launcher symlink", cur.native());
    }
    if (target.filename() == "launch") {
      return fs::canonical(cur.parent_path()) / cur.filename();
    }
    cur = target.is_absolute() ? target : cur.parent_path() / target;
  }
  Die("symlink loop", argv0);
}

struct Context {
  std::string root;   // <pkg>
  std::string store;  // dirname of <pkg>
  std::string self;   // <pkg>/bin/foo
};

auto Expand(std::string text, const Context& ctx) -> std::string {
  for (const auto& [key, val] : std::initializer_list<std::pair<std::string_view, const std::string&>>{
           {"{root}", ctx.root}, {"{store}", ctx.store}, {"{self}", ctx.self}}) {
    for (size_t pos = 0; (pos = text.find(key, pos)) != std::string::npos; pos += val.size()) {
      text.replace(pos, key.size(), val);
    }
  }
  return text;
}

auto StringList(const Json& value, const Context& ctx) -> std::vector<std::string> {
  std::vector<std::string> out;
  if (value.is_string()) {
    out.push_back(Expand(value.get<std::string>(), ctx));
  } else if (value.is_array()) {
    for (const auto& elem : value) {
      out.push_back(Expand(elem.get<std::string>(), ctx));
    }
  } else {
    Die("env value must be string or array");
  }
  return out;
}

auto Join(const std::vector<std::string>& parts, std::string_view sep) -> std::string {
  std::string out;
  for (size_t i = 0; i < parts.size(); ++i) {
    if (i != 0) {
      out += sep;
    }
    out += parts[i];
  }
  return out;
}

// {"prepend"|"append": [..], "sep": ":"} | {"set": ".."} | {"default": ".."} | {"unset": ..}
void ApplyEnv(const std::string& name, const Json& spec, const Context& ctx) {
  const std::string sep = spec.value("sep", ":");
  for (const auto& [oper, val] : spec.items()) {
    if (oper == "sep") {
      continue;
    }
    const auto cur = GetEnv(name);
    if (oper == "unset") {
      unsetenv(name.c_str());  // NOLINT(concurrency-mt-unsafe): single-threaded
    } else if (oper == "set") {
      SetEnv(name, Join(StringList(val, ctx), sep));
    } else if (oper == "default") {
      if (!cur) {
        SetEnv(name, Join(StringList(val, ctx), sep));
      }
    } else if (oper == "prepend" || oper == "append") {
      std::vector<std::string> parts = StringList(val, ctx);
      if (cur && !cur->empty()) {
        parts.insert(oper == "prepend" ? parts.end() : parts.begin(), *cur);
      }
      SetEnv(name, Join(parts, sep));
    } else {
      Die("unknown env op", oper);
    }
  }
}

}  // namespace

auto main(int argc, char** argv) -> int {  // NOLINT(bugprone-exception-escape): built -fno-exceptions, libc++ aborts
  const std::span<char*> args(argv, static_cast<size_t>(argc));
  if (args.empty()) {
    Die("no argv[0]");
  }
  Context ctx;
  const fs::path self = InvokedPath(args[0]);
  ctx.self = self.native();
  const fs::path bindir = self.parent_path();
  ctx.root = bindir.parent_path().native();
  ctx.store = bindir.parent_path().parent_path().native();
  const fs::path recpath = bindir / ("." + self.filename().native() + ".launch");

  std::ifstream input(recpath);
  if (!input) {
    Die("cannot read record", recpath.native());
  }
  const Json rec = Json::parse(input, nullptr, /*allow_exceptions=*/false);
  if (rec.is_discarded() || !rec.is_object()) {
    Die("bad record", recpath.native());
  }
  if (!rec.contains("program")) {
    Die("record lacks program", recpath.native());
  }

  const std::string program = Expand(rec["program"].get<std::string>(), ctx);
  std::string argv0 = rec.contains("argv0") ? Expand(rec["argv0"].get<std::string>(), ctx) : program;
  std::vector<std::string> pre;
  if (rec.contains("args")) {
    pre = StringList(rec["args"], ctx);
  }
  if (rec.contains("env")) {
    for (const auto& [name, spec] : rec["env"].items()) {
      ApplyEnv(name, spec, ctx);
    }
  }

  std::vector<char*> nargv;
  nargv.reserve(pre.size() + args.size() + 1);
  nargv.push_back(argv0.data());
  for (auto& arg : pre) {
    nargv.push_back(arg.data());
  }
  nargv.insert(nargv.end(), args.begin() + 1, args.end());
  nargv.push_back(nullptr);
  execv(program.c_str(), nargv.data());
  Die(std::strerror(errno), program);  // NOLINT(concurrency-mt-unsafe): single-threaded
}
