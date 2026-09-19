// `launch`: the one program behind every script and every wrapped binary (docs/design.md §3
// "shebangs, env wrappers").
//
// ELF: bin/foo is a symlink to ../../<hash>-launch/bin/launch (a static-pie store neighbour).
// launch finds out *which* bin/foo it was started as, reads bin/.foo.launch next to it, and execs
// the described program.
// PE: bin/foo.exe is a copy of launch.exe (no dependable symlinks on Windows), the record's PATH is
// how bin/.foo.exe finds DLLs in store neighbours (no RUNPATH), CreateProcess stands in for execve.
// Everything in the record is relative to the package root ({root}) or a store neighbour ({store}
// = dirname of root), so the package and its closure relocate together. No shell is involved.
//
// Record (JSON, written by builder/launchers.nu):
//   {"program": "{root}/bin/.foo"                    or "{store}/<hash>-cpython/bin/python3",
//    "args":    ["{root}/bin/.foo"],               prepended before the user's args
//    "argv0":   "{argv0}",                         optional, default = program. {argv0} is what
//                                                  we were invoked as, unresolved: a venv's
//                                                  bin/python3 -> ours must still see the venv
//    "env":     {"PATH":  {"prepend": ["{store}/<hash>-jq/bin"], "sep": ":"},
//                "TZDIR": {"default": "{store}/<hash>-tzdata/share/zoneinfo"},
//                "FOO":   {"set": "bar"}, "BAR": {"unset": []}}}
//   "sep" defaults to the platform's PATH separator.

#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <stdlib.h>  // NOLINT(modernize-deprecated-headers): setenv/unsetenv are POSIX, not <cstdlib>
#include <unistd.h>
#endif

#include <algorithm>  // NOLINT(misc-include-cleaner): std::min in the _WIN32 half
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <format>
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

constexpr int kExitLaunchFailure = 127;

[[noreturn]] void Die(std::string_view what, std::string_view arg = {}) {
  std::println(stderr, "launch: {}{}{}", what, arg.empty() ? "" : ": ", arg);
  std::_Exit(kExitLaunchFailure);
}

// built -fno-exceptions: only the error_code overloads of <filesystem>
auto Canonical(const fs::path& path) -> fs::path {
  std::error_code err;
  fs::path out = fs::canonical(path, err);
  if (err) {
    Die(err.message(), path.string());
  }
  return out;
}

auto Str(const Json& value, std::string_view what) -> std::string {
  if (!value.is_string()) {
    Die("not a string in record", what);
  }
  return value.get<std::string>();
}

#ifdef _WIN32

constexpr std::string_view kPathSep = ";";

// the environment is UTF-16: through the narrow CRT a user's PATH would lose what the ANSI code
// page cannot hold
auto Wide(std::string_view str) -> std::wstring {
  if (str.empty()) {
    return {};
  }
  const int len =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str.data(), static_cast<int>(str.size()), nullptr, 0);
  if (len <= 0) {
    Die("not UTF-8", str);
  }
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, str.data(), static_cast<int>(str.size()), out.data(), len);
  return out;
}

auto Narrow(std::wstring_view str) -> std::string {
  if (str.empty()) {
    return {};
  }
  const int len =
      WideCharToMultiByte(CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0, nullptr, nullptr);
  if (len <= 0) {
    Die("WideCharToMultiByte failed");
  }
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, str.data(), static_cast<int>(str.size()), out.data(), len, nullptr, nullptr);
  return out;
}

auto GetEnv(const std::string& name) -> std::optional<std::string> {
  const std::wstring wname = Wide(name);
  // size query, then fetch. Another thread cannot change it in between: there is none
  const DWORD size = GetEnvironmentVariableW(wname.c_str(), nullptr, 0);
  if (size == 0) {
    return std::nullopt;
  }
  std::wstring buf(size, L'\0');
  const DWORD len = GetEnvironmentVariableW(wname.c_str(), buf.data(), size);
  if (len >= size) {
    Die("GetEnvironmentVariable failed", name);
  }
  buf.resize(len);
  return Narrow(buf);
}

void SetEnv(const std::string& name, const std::string& value) {
  if (SetEnvironmentVariableW(Wide(name).c_str(), Wide(value).c_str()) == 0) {
    Die("SetEnvironmentVariable failed", name);
  }
}

void UnsetEnv(const std::string& name) { SetEnvironmentVariableW(Wide(name).c_str(), nullptr); }

auto InvokedPath(std::string_view /*argv0*/) -> fs::path {
  std::wstring buf(32768, L'\0');
  const DWORD len = GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
  if (len == 0 || len >= buf.size()) {
    Die("GetModuleFileName failed");
  }
  buf.resize(len);
  // Wine does not resolve unix symlinks here: run store paths, not result links
  const fs::path self(buf);
  return Canonical(self.parent_path()) / self.filename();
}

auto LastError(std::string_view call) -> std::string { return std::format("{} failed ({})", call, GetLastError()); }

// CommandLineToArgvW in reverse, for the record's args. The user's own arguments are passed on
// as the tail of our command line, unparsed
void AppendArg(std::wstring& line, std::wstring_view arg) {
  line += L" \"";
  size_t slashes = 0;
  for (const wchar_t chr : arg) {
    if (chr == L'\\') {
      ++slashes;
      continue;
    }
    line.append(chr == L'"' ? (slashes * 2) + 1 : slashes, L'\\');
    slashes = 0;
    line += chr;
  }
  line.append(slashes * 2, L'\\');
  line += L'"';
}

auto UserArgs() -> std::wstring_view {
  std::wstring_view rest(GetCommandLineW());
  size_t end = 0;
  if (rest.starts_with(L'"')) {
    end = rest.find(L'"', 1);
    end = end == std::wstring_view::npos ? rest.size() : end + 1;
  } else {
    end = std::min(rest.find_first_of(L" \t"), rest.size());
  }
  return rest.substr(end);
}

// No execve: CreateProcess in a kill-on-close job so the child cannot outlive us, wait, pass on
// the exit code. Ctrl-C reaches the child through the console, the launcher ignores it
[[noreturn]] void Run(const fs::path& program, std::string& argv0, std::vector<std::string>& pre,
                      std::span<char*> /*args*/) {
  std::wstring line;
  AppendArg(line, Wide(argv0));
  for (const auto& arg : pre) {
    AppendArg(line, Wide(arg));
  }
  line += UserArgs();
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};
  limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
  if (job == nullptr || SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit, sizeof(limit)) == 0) {
    Die(LastError("CreateJobObject"));
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION proc{};
  if (CreateProcessW(program.c_str(), line.data() + 1, nullptr, nullptr, /*bInheritHandles=*/TRUE, CREATE_SUSPENDED,
                     nullptr, nullptr, &startup, &proc) == 0) {
    Die(LastError("CreateProcess"), program.string());
  }
  // a job we are in ourselves may forbid nesting (pre Windows 8): then the child just runs unsupervised
  AssignProcessToJobObject(job, proc.hProcess);
  SetConsoleCtrlHandler(nullptr, TRUE);
  if (ResumeThread(proc.hThread) == static_cast<DWORD>(-1)) {
    Die(LastError("ResumeThread"), program.string());
  }
  CloseHandle(proc.hThread);
  DWORD code = 0;
  if (WaitForSingleObject(proc.hProcess, INFINITE) != WAIT_OBJECT_0 || GetExitCodeProcess(proc.hProcess, &code) == 0) {
    Die(LastError("WaitForSingleObject"), program.string());
  }
  std::_Exit(static_cast<int>(code));
}

#else

constexpr std::string_view kPathSep = ":";

auto GetEnv(const std::string& name) -> std::optional<std::string> {
  const char* value = std::getenv(name.c_str());  // NOLINT(concurrency-mt-unsafe): single-threaded
  if (value == nullptr) {
    return std::nullopt;
  }
  return std::string(value);
}

void SetEnv(const std::string& name, const std::string& value) {
  if (setenv(name.c_str(), value.c_str(), 1) != 0) {  // NOLINT(concurrency-mt-unsafe): single-threaded
    Die(std::strerror(errno), name);                  // NOLINT(concurrency-mt-unsafe)
  }
}

void UnsetEnv(const std::string& name) {
  unsetenv(name.c_str());  // NOLINT(concurrency-mt-unsafe): single-threaded
}

// argv[0] as a path: as given when it has a '/', else looked up on PATH like the shell did.
auto Argv0Path(std::string_view argv0) -> fs::path {
  std::error_code err;
  if (argv0.contains('/')) {
    return fs::absolute(argv0, err);
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
      return fs::absolute(cand, err);
    }
    pos = end + 1;
  }
  Die("not found on PATH", argv0);
}

constexpr int kMaxHops = 32;

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
      return Canonical(cur.parent_path()) / cur.filename();
    }
    cur = target.is_absolute() ? target : cur.parent_path() / target;
  }
  Die("symlink loop", argv0);
}

[[noreturn]] void Run(const fs::path& program, std::string& argv0, std::vector<std::string>& pre,
                      std::span<char*> args) {
  std::vector<char*> nargv;
  nargv.reserve(pre.size() + args.size() + 1);
  nargv.push_back(argv0.data());
  for (auto& arg : pre) {
    nargv.push_back(arg.data());
  }
  nargv.insert(nargv.end(), args.begin() + 1, args.end());
  nargv.push_back(nullptr);
  execv(program.c_str(), nargv.data());
  Die(std::strerror(errno), program.native());  // NOLINT(concurrency-mt-unsafe): single-threaded
}

#endif

struct Context {
  std::string root;   // <pkg>
  std::string store;  // dirname of <pkg>
  std::string self;   // <pkg>/bin/foo
  std::string argv0;  // as invoked
};

auto Expand(std::string text, const Context& ctx) -> std::string {
  for (const auto& [key, val] : std::initializer_list<std::pair<std::string_view, const std::string&>>{
           {"{root}", ctx.root},
           {"{store}", ctx.store},
           {"{self}", ctx.self},
           {"{argv0}", ctx.argv0},
       }) {
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
      out.push_back(Expand(Str(elem, "list element"), ctx));
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
    out += parts.at(i);
  }
  return out;
}

// {"prepend"|"append": [..], "sep": ":"} | {"set": ".."} | {"default": ".."} | {"unset": ..}
void ApplyEnv(const std::string& name, const Json& spec, const Context& ctx) {
  if (!spec.is_object()) {
    Die("env entry must be an object", name);
  }
  const std::string sep = spec.contains("sep") ? Str(spec.at("sep"), "sep") : std::string(kPathSep);
  for (const auto& [oper, val] : spec.items()) {
    if (oper == "sep") {
      continue;
    }
    const auto cur = GetEnv(name);
    if (oper == "unset") {
      UnsetEnv(name);
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
  ctx.argv0 = args.front();
  const fs::path self = InvokedPath(args.front());
  ctx.self = self.string();
  const fs::path bindir = self.parent_path();
  ctx.root = bindir.parent_path().string();
  ctx.store = bindir.parent_path().parent_path().string();
  const fs::path recpath = bindir / ("." + self.filename().string() + ".launch");

  std::ifstream input(recpath);
  if (!input) {
    Die("cannot read record", recpath.string());
  }
  const Json rec = Json::parse(input, nullptr, /*allow_exceptions=*/false);
  if (rec.is_discarded() || !rec.is_object()) {
    Die("bad record", recpath.string());
  }
  if (!rec.contains("program")) {
    Die("record lacks program", recpath.string());
  }

  const std::string program = Expand(Str(rec.at("program"), "program"), ctx);
  std::string argv0 = rec.contains("argv0") ? Expand(Str(rec.at("argv0"), "argv0"), ctx) : program;
  std::vector<std::string> pre;
  if (rec.contains("args")) {
    pre = StringList(rec.at("args"), ctx);
  }
  if (rec.contains("env")) {
    if (!rec.at("env").is_object()) {
      Die("env must be an object", recpath.string());
    }
    for (const auto& [name, spec] : rec.at("env").items()) {
      ApplyEnv(name, spec, ctx);
    }
  }
  Run(program, argv0, pre, args);
}
