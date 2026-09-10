// `jig cache put-dir|get-dir <key> <dir>`: a directory tree in the cache as content-addressed
// file blobs plus one listing under <key>, so trees sharing files share storage.
#pragma once

#include <string>

namespace jig {

auto PutDir(const std::string& socket_path, const std::string& key, const std::string& dir) -> int;
auto GetDir(const std::string& socket_path, const std::string& key, const std::string& dir) -> int;

}  // namespace jig
