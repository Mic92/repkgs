# What cpython's package.nix adds to the interpreter:
#   cpython.env { src | lock, … }     an environment: every locked dependency plus bin/python3
#   cpython.project { src, … }        { package = the application; devEnv = an env whose python
#                                     also imports the checkout named by $REPKGS_PROJECT }
# Both are pyapp packages around fetch.pythonDeps. Example: tests/builder/pyproject.
{
  package,
  fetch,
  pkgs,
  buildPkgs,
  python,
}:
let
  inherit (builtins)
    attrNames
    baseNameOf
    concatLists
    dirOf
    elem
    filter
    fromTOML
    head
    match
    pathExists
    readFile
    ;
  norm = builtins.replaceStrings [ "_" "." ] [ "-" "-" ];
  namedBuild = names: map (n: buildPkgs.${n}) names;
  # per PyPI name: C libraries to link, build tools, config settings (builder/sys-libs.nu)
  table = (builtins.fromJSON (readFile ../builder/sys-libs.json)).python;

  # git sources: uv.lock has url?rev#sha and no content hash, so they are fetched here by commit
  gitSources =
    lock:
    concatLists (
      map (
        p:
        let
          m = match "([^?#]+)(\\?[^#]*)?#(.*)" (p.source.git or "");
        in
        if p ? source.git then
          [
            {
              inherit (p) name;
              path = builtins.fetchGit {
                url = head m;
                rev = builtins.elemAt m 2;
                allRefs = true;
              };
            }
          ]
        else
          [ ]
      ) (lock.package or [ ])
    );

  mk =
    mode:
    {
      src, # the project (its pyproject.toml names it); with `lock`, only used for the name
      lock ? null, # a uv.lock elsewhere than src/uv.lock
      name ? null,
      extras ? [ ],
      groups ? [ ], # PEP 735 dependency groups, env and dev only
      prefer ? "wheel", # or "sdist", for every package the lock has both for
      # per locked package, by PyPI name: { prefer, sys, tools, patches, env, run (nu, in its
      # unpacked source), configSettings }
      overrides ? { },
      sys ? [ ], # extra C libraries by package name, on top of sys-libs.json
      tools ? [ ], # extra build tools by package name
      check ? [ ], # modules that must import from the result
      env ? { },
      environ ? { }, # PEP 508 marker overrides, e.g. { platform_release = "6.6"; }
    }:
    let
      pp = src + "/pyproject.toml";
      pname =
        if name != null then
          name
        else if pathExists pp then
          norm (fromTOML (readFile pp)).project.name
        else
          baseNameOf src;
      source = builtins.path {
        path = src;
        name = "${pname}-src";
        filter =
          p: _t:
          !(elem (baseNameOf p) [
            ".git"
            ".venv"
            "result"
            "__pycache__"
            ".direnv"
          ]);
      };
      lockFile = if lock == null then src + "/uv.lock" else lock;
      lockData = fromTOML (readFile lockFile);
      root =
        if lock == null then
          source
        else
          builtins.path {
            path = dirOf lock;
            name = "${pname}-lock";
          };
      ovNames = attrNames overrides;
      ov =
        n: k: d:
        overrides.${n}.${k} or d;
      locked = filter (n: table ? ${n}) (map (p: p.name) (lockData.package or [ ]));
      fromTable = k: concatLists (map (n: table.${n}.${k} or [ ]) locked);
      tableSys = filter (n: pkgs ? ${n}) (
        concatLists (map (n: if table.${n} ? pkg then [ table.${n}.pkg ] else [ ]) locked)
      );
    in
    package {
      name = if mode == "project" then pname else "${pname}-${mode}";
      inherit source;
      version = "0";
      uses = [ "pyapp" ];
      pyapp = {
        inherit mode check;
        deps = fetch.pythonDeps {
          inherit python extras prefer;
          source = root;
          groups = if mode == "project" then [ ] else groups;
          sdist = filter (n: ov n "prefer" prefer == "sdist") ovNames;
          git = gitSources lockData;
          environ = builtins.toJSON environ;
        };
        overrides = builtins.mapAttrs (_n: o: {
          env = o.env or { };
          patches = map toString (o.patches or [ ]);
          run = o.run or "";
          configSettings = o.configSettings or { };
        }) overrides;
      };
      sys = sys ++ tableSys ++ concatLists (map (n: ov n "sys" [ ]) ovNames);
      buildDependencies = namedBuild (
        tools
        ++ filter (n: buildPkgs ? ${n}) (fromTable "tools")
        ++ concatLists (map (n: ov n "tools" [ ]) ovNames)
      );
      dependencies = [
        python
        pkgs.libgcc-shim
      ];
      inherit env;
      tests.version = false;
      exports = false;
    };
in
{
  env = args: mk "env" (if args ? src then args else args // { src = dirOf args.lock; });
  project = args: {
    package = mk "project" args;
    devEnv = mk "dev" args;
  };
}
