// GHC's -jsem protocol (a POSIX named semaphore ghc sem_waits on for every capability beyond its
// first) backed by jigd slots. A token in the semaphore is a daemon slot this build holds
// idle. The broker keeps one such spare, orders another slot when it was taken and returns slots
// when ghc gives tokens back. Only sem_trywait/sem_post observe the count (no sem_getvalue: macOS
// lacks it).
#pragma once

#include <semaphore.h>

#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace jsem {

// created O_EXCL with `tokens`, unlinked on destruction. `name` has a leading slash
class Sem {
 public:
  static auto Create(const std::string& name, unsigned tokens) -> std::unique_ptr<Sem>;
  ~Sem();
  Sem(const Sem&) = delete;
  auto operator=(const Sem&) -> Sem& = delete;
  Sem(Sem&&) = delete;
  auto operator=(Sem&&) -> Sem& = delete;

  auto TryWait() -> bool;
  void Post();

 private:
  Sem() = default;
  std::string name_;
  sem_t* sem_ = nullptr;
};

// polled every tick: want=true places or checks on an order (nullptr = not yet), want=false
// cancels a pending one. Dropping a Token gives it back
using Token = std::shared_ptr<void>;
using TokenSource = std::function<Token(bool want)>;

auto DaemonUp(const std::string& socket_path) -> bool;
// orders one slot per call sequence over its own connection, which the daemon frees on close
auto DaemonSource(std::string socket_path, std::string build) -> TokenSource;

class Broker {
 public:
  Broker(Sem& sem, TokenSource source) : sem_(&sem), source_(std::move(source)) {}
  // keep one idle token, return the rest, order one if none
  void Tick();
  [[nodiscard]] auto held() const -> size_t { return held_.size(); }

 private:
  Sem* sem_;
  TokenSource source_;
  std::vector<Token> held_;
};

}  // namespace jsem
