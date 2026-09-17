use checks.nu *
let py = $"($env.pkg)/bin/python3"
let out = (with-env {REPKGS_PROJECT: $env.src} { ^$py -c "import tproj; tproj.main()" } | str trim)
assert "devEnv imports the project from REPKGS_PROJECT" ($out == "tproj-hello 1.0")
assert "without it the project is not importable" ((do { ^$py -c "import tproj" } | complete).exit_code != 0)
done
