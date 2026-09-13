use checks.nu *
use glob.nu [files]
let ext = (files $"($env.pkg)/lib/python3*/site-packages/tpy/_speed*.so" | first | path relative-to $env.pkg)
has-debug $ext
assert "console script gets a launcher" (($"($env.pkg)/bin/tpy-hello" | path type) == symlink)
assert "no pyc with build paths" ((^grep -rl /build $"($env.pkg)/lib" | complete).stdout == "")
done
