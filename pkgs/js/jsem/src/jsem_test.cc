#include <unistd.h>

#include <cassert>
#include <cstdio>
#include <format>
#include <memory>
#include <string>

#include "broker.h"

namespace {
void TestBroker() {
  const std::string name = std::format("/jsem_test_{}", ::getpid());
  const std::unique_ptr<jsem::Sem> sem = jsem::Sem::Create(name, 0);
  assert(sem != nullptr);
  int out = 0;
  const jsem::TokenSource source = [&out](bool want) -> jsem::Token {
    if (!want) {
      return nullptr;
    }
    ++out;
    return {&out, [&out](void*) -> void { --out; }};
  };
  const auto value = [&sem] -> int {
    int count = 0;
    while (sem->TryWait()) {
      ++count;
    }
    for (int i = 0; i < count; ++i) {
      sem->Post();
    }
    return count;
  };
  {
    jsem::Broker broker(*sem, source);
    broker.Tick();  // empty: order one, it becomes the spare
    assert(out == 1 && value() == 1 && broker.held() == 1);
    broker.Tick();  // spare untouched: steady
    assert(out == 1 && value() == 1);
    assert(sem->TryWait());  // ghc takes it
    broker.Tick();           // spare gone: order another
    assert(out == 2 && value() == 1 && broker.held() == 2);
    assert(sem->TryWait());  // ghc takes that too
    broker.Tick();
    assert(out == 3 && broker.held() == 3);
    sem->Post();  // ghc returns two
    sem->Post();
    broker.Tick();  // three idle: keep one, return two
    assert(out == 1 && value() == 1 && broker.held() == 1);
  }
  assert(out == 0);  // broker gone: everything returned
}

void TestNoDaemon() {
  assert(!jsem::DaemonUp("/nonexistent/sock"));
  assert(jsem::DaemonSource("/nonexistent/sock", "-")(true) == nullptr);
}
}  // namespace

auto main() -> int {
  TestBroker();
  TestNoDaemon();
  std::puts("jsem_test: ok");
  return 0;
}
