// GOCACHEPROG mode (argv[0] = gocacheprog): Go's JSON-lines cache protocol on stdin/stdout
// mapped onto the cache socket. Bodies materialised under $GOCACHEPROG_DIR (default
// $TMPDIR/gocacheprog) because the go tool wants a DiskPath.
#ifndef PKGS_CC_GOCACHE_MODE_H_
#define PKGS_CC_GOCACHE_MODE_H_

#include <string>
#include <string_view>

namespace jig {

auto RunGoCacheProg(const std::string& socket_path) -> int;

// exposed for tests (Go encodes ActionID/OutputID/body as base64)
auto Base64Encode(std::string_view bytes) -> std::string;
auto Base64Decode(std::string_view text) -> std::string;

}  // namespace jig

#endif  // PKGS_CC_GOCACHE_MODE_H_
