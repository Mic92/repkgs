#include "broker.h"

#include <fcntl.h>
#include <poll.h>
#include <semaphore.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <format>
#include <iterator>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace jsem {

namespace {
constexpr mode_t kMode = 0600;

class Conn {
 public:
  explicit Conn(int fd) : fd_(fd) {}
  ~Conn() {
    if (fd_ >= 0) {
      ::close(fd_);
    }
  }
  Conn(const Conn&) = delete;
  auto operator=(const Conn&) -> Conn& = delete;
  Conn(Conn&&) = delete;
  auto operator=(Conn&&) -> Conn& = delete;

  static auto Open(const std::string& socket_path) -> std::unique_ptr<Conn> {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (socket_path.empty() || socket_path.size() >= sizeof(addr.sun_path)) {
      return nullptr;
    }
    std::ranges::copy(socket_path, std::begin(addr.sun_path));
    auto conn = std::make_unique<Conn>(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast): the sockets API is defined this way
    if (conn->fd_ < 0 || ::connect(conn->fd_, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
      return nullptr;
    }
    return conn;
  }

  auto Send(std::string_view line) const -> bool {
    while (!line.empty()) {
      const ssize_t sent = ::send(fd_, line.data(), line.size(), MSG_NOSIGNAL);
      if (sent <= 0) {
        return false;
      }
      line.remove_prefix(static_cast<size_t>(sent));
    }
    return true;
  }

  [[nodiscard]] auto Readable() const -> bool {
    pollfd pfd{.fd = fd_, .events = POLLIN, .revents = 0};
    return ::poll(&pfd, 1, 0) == 1;
  }

  // true when the daemon answered "OK\n"
  [[nodiscard]] auto Ok() const -> bool {
    std::string reply;
    std::array<char, 64> buf{};
    while (!reply.ends_with('\n')) {
      const ssize_t got = ::read(fd_, buf.data(), buf.size());
      if (got <= 0) {
        return false;
      }
      reply.append(buf.data(), static_cast<size_t>(got));
    }
    return reply == "OK\n";
  }

 private:
  int fd_;
};
}  // namespace

auto Sem::Create(const std::string& name, unsigned tokens) -> std::unique_ptr<Sem> {
  ::sem_unlink(name.c_str());  // a stale one from a killed build
  sem_t* raw = ::sem_open(name.c_str(), O_CREAT | O_EXCL, kMode, tokens);
  if (raw == SEM_FAILED) {
    return nullptr;
  }
  std::unique_ptr<Sem> sem(new Sem());
  sem->name_ = name;
  sem->sem_ = raw;
  return sem;
}

auto Sem::Open(const std::string& name) -> std::unique_ptr<Sem> {
  sem_t* raw = ::sem_open(name.c_str(), 0);
  if (raw == SEM_FAILED) {
    return nullptr;
  }
  std::unique_ptr<Sem> sem(new Sem());
  sem->sem_ = raw;
  return sem;
}

Sem::~Sem() {
  ::sem_close(sem_);
  if (!name_.empty()) {
    ::sem_unlink(name_.c_str());
  }
}

auto Sem::TryWait() -> bool { return ::sem_trywait(sem_) == 0; }
void Sem::Post() { ::sem_post(sem_); }

auto DaemonUp(const std::string& socket_path) -> bool { return Conn::Open(socket_path) != nullptr; }

auto DaemonSource(std::string socket_path, std::string build) -> TokenSource {
  auto pending = std::make_shared<std::unique_ptr<Conn>>();
  return [socket_path = std::move(socket_path), build = std::move(build), pending](bool want) -> Token {
    if (!want) {
      pending->reset();
      return nullptr;
    }
    if (!*pending) {
      *pending = Conn::Open(socket_path);
      if (!*pending || !(*pending)->Send(std::format("SLOT {}\n", build))) {
        pending->reset();
        return nullptr;
      }
    }
    if (!(*pending)->Readable()) {
      return nullptr;
    }
    std::shared_ptr<Conn> conn = std::move(*pending);
    return conn->Ok() ? conn : nullptr;
  };
}

Broker::~Broker() {
  for (size_t i = 0; i < held_.size() && sem_->TryWait(); ++i) {
  }
}

void Broker::Tick() {
  size_t idle = 0;
  while (sem_->TryWait()) {
    ++idle;
  }
  // tokens ghc holds = held - idle. Put the spare back only while a slot backs it, else a waiter
  // could take a token nobody admitted
  const size_t in_use = held_.size() - std::min(held_.size(), idle);
  held_.resize(std::min(held_.size(), in_use + 1));
  const bool spare = held_.size() == in_use + 1;
  if (Token token = source_(!spare)) {
    held_.push_back(std::move(token));
  }
  if (held_.size() > in_use) {
    sem_->Post();
  }
}

}  // namespace jsem
