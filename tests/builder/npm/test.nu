use checks.nu *
assert "bin gets a launcher" (($"($env.pkg)/bin/test-npm" | path type) == symlink)
assert "installed script keeps #!/usr/bin/env" ((open --raw $"($env.pkg)/lib/node_modules/test-npm/cli.js" | lines | first) == "#!/usr/bin/env node")
assert "debug output exists and is empty" ((ls $env.debug | length) == 0)
done
