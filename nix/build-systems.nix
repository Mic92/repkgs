# What `uses = [ "<name>" ]` means: the nu module implementing the verbs, the default step order,
# the tools it puts on PATH, and the knobs a package may set under `<name>.*` (anything else is an
# eval error). `sh` is for tools that spawn a shell by name (ninja, npm run, libtool).
{
  standins,
  buildPkgs,
  sh,
}:
{
  autotools = {
    module = "autotools.nu";
    steps = [
      "autotools.configure"
      "autotools.build"
      "autotools.test"
      "autotools.install"
    ];
    # make and bash come with baseTools (or the seed's for bootstrapTools packages)
    tools = [ sh ];
    knobs = [
      "flags"
      "makeFlags"
      "installFlags"
      "configureScript"
      "outOfTree"
      "testTarget"
      "buildTarget"
    ];
  };
  cmake = {
    module = "cmake.nu";
    steps = [
      "cmake.configure"
      "cmake.build"
      "cmake.test"
      "cmake.install"
    ];
    tools = [
      buildPkgs.cmake
      buildPkgs.ninja
      sh
    ];
    knobs = [
      "defs"
      "sourceDir"
      "generator"
    ];
  };
  meson = {
    module = "meson.nu";
    steps = [
      "meson.configure"
      "meson.build"
      "meson.test"
      "meson.install"
    ];
    tools = [
      buildPkgs.meson
      buildPkgs.ninja
      sh
    ];
    knobs = [
      "options"
      "sourceDir"
    ];
  };
  python = {
    module = "python.nu";
    steps = [
      "python.build"
      "python.install"
      "python.test"
    ];
    # the PEP 517 front end and its deps. Members of the stack itself get only what exists before them
    tools = [ buildPkgs.cpython ];
    stack = with buildPkgs; [
      python-flit-core
      python-packaging
      python-pyproject-hooks
      python-build
      python-installer
    ];
    knobs = [
      "backend"
      "module"
      "root"
      "pytest"
    ];
  };
  cargo = {
    module = "cargo.nu";
    steps = [
      "cargo.build"
      "cargo.test"
      "cargo.install"
    ];
    tools = [ buildPkgs.rust ];
    knobs = [
      "features"
      "noDefaultFeatures"
      "root"
      "vendor"
    ];
  };
  go = {
    module = "go.nu";
    steps = [
      "go.build"
      "go.test"
      "go.install"
    ];
    tools = [ standins.go ];
    knobs = [
      "tags"
      "ldflags"
      "packages"
      "testPackages"
      "root"
      "vendor"
      "cgo"
    ];
  };
  npm = {
    module = "npm.nu";
    steps = [
      "npm.build"
      "npm.test"
      "npm.install"
    ];
    tools = [
      standins.nodejs
      sh
    ];
    knobs = [
      "root"
      "script"
      "deps"
      "test"
      "flags"
    ];
  };
}
