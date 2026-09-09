# The `package` function: spec attrset -> derivation (+ `.tests` when tests.separate).
# Validates field and knob names at eval time, then generates the nu script
#   use core.nu *; use prepare.nu; use finish.nu; use <bs>.nu …; prepare; <bs> setup …; <step> …; finish
# that nu executes in a single nu process. Vocabulary: README.md "Writing a package".
{
  platform,
  toolchain,
  launch,
  buildSystems,
  baseTools,
  relocTools,
  nu,
}:
let
  inherit (builtins)
    attrNames
    concatMap
    concatStringsSep
    elem
    elemAt
    filter
    foldl'
    head
    isAttrs
    isString
    length
    listToAttrs
    match
    replaceStrings
    ;

  tree = builtins.path {
    path = ../builder;
    name = "build";
  };
  reserved = [
    "name"
    "version"
    "source"
    "patches"
    "uses"
    "steps"
    "buildDependencies"
    "dependencies"
    "runtimeDependencies"
    "bin"
    "tests"
    "exports"
    "env"
    "root"
    "cc"
    "bootstrapTools"
    "prebuilt"
    "install"
    "links"
  ];

  # the part of every derivation that is the same across the set: built once
  setCommon = {
    inherit (platform) system;
    __structuredAttrs = true;
    builder = "${nu}/bin/nu";
    # platform facts autoconf would otherwise probe (or guess, when cross): nix/config.site
    CONFIG_SITE = "${../nix/config.site}";
    platform = {
      inherit (platform)
        name
        cpu
        os
        names
        triple
        cross
        emulator
        ;
      probe = if platform.cross then "${toolchain.sysroot}/lib/${platform.interp}" else "";
      # `prebuilt`: upstream ELFs get our dynamic linker implanted (true) or via launch ("ldso")
      interp = "${toolchain.sysroot}/lib/${platform.interp}";
      launch = "${launch}/bin/launch";
      relocStub = "${toolchain}/lib/reloc_stub.bin";
    };
  };
  preludeBase = [
    "use ${tree}/core.nu *"
    "use ${tree}/prepare.nu"
    "use ${tree}/finish.nu"
  ];

  stepRe = "([a-z]+)\\.([a-zA-Z]+)";
  isTest =
    s:
    isString s
    && (
      let
        p = match stepRe s;
      in
      p != null && elemAt p 1 == "test"
    );
in
# sources: the package's sources.toml (nix/sources.nix) or null. It supplies version and source
# unless package.nix sets them (local trees, demos)
sources: args0:
let
  args =
    (
      if sources == null then
        { }
      else
        {
          inherit (sources) version;
          # one tarball for all, or one per cpu (prebuilt toolchains keyed "x86_64", "aarch64")
          source = if sources.has "default" then sources.default else sources.fetch platform.cpu;
        }
    )
    // args0;
  inherit (args) name;
  uses = args.uses or [ ];
  fail = msg: throw "${name}: ${msg}";

  unknownUses = filter (u: !(buildSystems ? ${u})) uses;
  unknownFields = filter (f: !(elem f (reserved ++ uses))) (attrNames args);
  unknownKnobs = concatMap (
    u:
    map (k: "${u}.${k}") (filter (k: !(elem k buildSystems.${u}.knobs)) (attrNames (args.${u} or { })))
  ) (filter (u: buildSystems ? ${u}) uses);
  checks =
    if unknownUses != [ ] then
      fail "unknown build systems ${toString unknownUses} (have: ${toString (attrNames buildSystems)})"
    else if unknownFields != [ ] then
      fail "unknown fields ${toString unknownFields}"
    else if unknownKnobs != [ ] then
      fail "unknown knobs ${toString unknownKnobs}"
    else
      true;

  # `install`/`links` alone (prebuilt binaries, data): the one step is copying them into $out
  steps =
    args.steps or (
      if length uses == 1 then
        buildSystems.${head uses}.steps
      else if uses == [ ] && (args ? install || args ? links) then
        [ ]
      else
        fail "'steps' is required with more than one build system"
    );
  testsRun = args.tests.run or true;
  # a build system's `stack` (tools that are themselves built with it): a member sees only the
  # members before it, everyone else sees all of it
  stackBefore =
    stack:
    let
      r =
        foldl' (a: p: if a.hit || p.pname == name then a // { hit = true; } else a // { l = a.l ++ [ p ]; })
          {
            hit = false;
            l = [ ];
          }
          stack;
    in
    r.l;
  # tests.separate: the build derivation skips *.test and keeps its tree in output `tree`;
  # `<pkg>.tests` restores it and runs only the test verbs, so a failing test cannot change the package
  separate = args.tests.separate or false;

  # same flags as treefmt's nu-typecheck, so what lints clean parses the same way here
  nuArgs = [
    "--no-config-file"
    "--experimental-options=[cell-path-types]"
    "-c"
  ];
  stepLine =
    s:
    if isAttrs s then
      "note step ${s.name}\ndo {\nlet c = (ctx)\n${s.run}\n}"
    else
      let
        p = match stepRe s;
      in
      if p == null || !(elem (elemAt p 0) uses) then
        fail "step '${s}' is not <one of ${toString uses}>.<verb>"
      else if elemAt p 1 == "test" && (!testsRun || separate) then
        ""
      else
        "note step ${s}\n${elemAt p 0} ${elemAt p 1}";
  prelude = preludeBase ++ map (u: "use ${tree}/${buildSystems.${u}.module}") uses;
  setups = map (u: "note setup ${u}\n${u} setup") uses;
  script = concatStringsSep "\n" (
    prelude
    ++ [ "prepare" ]
    ++ setups
    ++ map stepLine steps
    ++ [ (if separate then "finish --keep-tree" else "finish") ]
  );
  testScript = concatStringsSep "\n" (
    prelude
    ++ [ "prepare --from-tree ${drv.tree}" ]
    ++ setups
    ++ map (s: "note step ${s}\n${replaceStrings [ "." ] [ " " ] s}") (filter isTest steps)
    ++ [ "finish tests" ]
  );

  spec =
    removeAttrs args [
      "source"
      "patches"
      "buildDependencies"
      "dependencies"
      "runtimeDependencies"
      "bootstrapTools"
    ]
    // listToAttrs (
      map (u: {
        name = u;
        value = buildSystems.${u}.defaults args // (args.${u} or { });
      }) (filter (u: buildSystems.${u} ? defaults) uses)
    )
    // {
      inherit steps;
    };
  common = setCommon // {
    src = args.source;
    inherit (args) version;
    patches = args.patches or [ ];
    inherit spec;
    buildDependencies = [
      toolchain
    ]
    ++ (args.buildDependencies or [ ])
    ++ (if (args.prebuilt or false) == true then relocTools else [ ])
    ++ concatMap (u: buildSystems.${u}.tools ++ stackBefore (buildSystems.${u}.stack or [ ])) uses
    ++ (if args.bootstrapTools or false then baseTools.bootstrap else baseTools.full);
    dependencies = args.dependencies or [ ];
    runtimeDependencies = args.runtimeDependencies or [ ];
  };
  drv = derivation (
    common
    // {
      name = if platform.cross then "${name}-${platform.name}" else name;
      outputs = [ "out" ] ++ (if separate then [ "tree" ] else [ ]);
      args = nuArgs ++ [ script ];
    }
  );
  testsDrv = derivation (
    common
    // {
      name = "${drv.name}-tests";
      outputs = [ "out" ];
      package = drv.out;
      args = nuArgs ++ [ testScript ];
    }
  );
in
assert checks;
drv // { pname = name; } // (if separate then { tests = testsDrv; } else { })
