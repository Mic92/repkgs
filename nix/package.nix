# The `package` function: spec attrset -> derivation (+ `.tests` when tests.separate).
# Validates field and option names at eval time, then generates the nu script
#   use core.nu *; use prepare.nu; use finish.nu; use implant.nu; use <bs>.nu …; prepare; <bs> setup …; <step> …; finish
# that nu executes in a single nu process. Vocabulary: README.md "Writing a package".
{
  platform,
  toolchain,
  launch,
  buildSystems,
  baseTools,
  relocTools,
  nu,
  # overrides applied to a spec before validation: name -> spec -> spec (nix/overrides.nix)
  edit,
}:
let
  inherit (builtins)
    any
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
    "modules"
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
    "use ${tree}/implant.nu"
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
sources0: args0:
let
  edited = if edit == null then args0 else edit args0.name args0;
  # an override may repin the package: `pin.merge = { version = "…"; }` plus
  # `hash.merge = { default = "sha256-…"; }` re-read sources.toml under the new [pin]
  repinned = edit != null && sources0 != null && (edited ? pin || edited ? hash);
  sources = if repinned then sources0.repin (edited.pin or { }) (edited.hash or { }) else sources0;
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
    // (
      if repinned then
        removeAttrs edited [
          "pin"
          "hash"
        ]
      else
        edited
    );
  inherit (args) name;
  uses = args.uses or [ ];
  fail = msg: throw "${name}: ${msg}";

  unknownUses = filter (u: !(buildSystems ? ${u})) uses;
  unknownFields = filter (f: !(elem f (reserved ++ uses))) (attrNames args);
  # one message per option the package sets that its build system does not declare, or declares
  # with another type. Shallow (`typeOf`) on set options only, so it costs nothing per default.
  badOptions = concatMap (
    u:
    let
      declared = buildSystems.${u}.options;
    in
    concatMap (
      k:
      let
        got = builtins.typeOf args.${u}.${k};
        want = declared.${k}.type;
      in
      if !(declared ? ${k}) then
        [ "unknown option ${u}.${k} (have: ${toString (attrNames declared)})" ]
      else if !(elem got want) then
        [ "option ${u}.${k} is a ${got}, expected ${builtins.concatStringsSep " or " want}" ]
      else
        [ ]
    ) (attrNames (args.${u} or { }))
  ) (filter (u: buildSystems ? ${u}) uses);
  checks =
    if unknownUses != [ ] then
      fail "unknown build systems ${toString unknownUses} (have: ${toString (attrNames buildSystems)})"
    else if unknownFields != [ ] then
      fail "unknown fields ${toString unknownFields}"
    else if badOptions != [ ] then
      fail (builtins.concatStringsSep "; " badOptions)
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
  # `<pkg>.tests` restores it and runs only the test verbs: a test failure fails that derivation,
  # not the package, and a retry does not rebuild
  separate = args.tests.separate or false;

  # same flags as treefmt's nu-typecheck, so what lints clean parses the same way here
  # include path: a package's own module says `use core.nu *` wherever it lives
  nuArgs = [
    "--no-config-file"
    "--include-path=${tree}"
    "--experimental-options=[cell-path-types]"
    "-c"
  ];
  stepLine =
    s:
    if isAttrs s then
      "note step ${s.name}\ndo {\ncd (${workdir})\nlet c = (ctx)\n${s.run}\n}"
    else
      let
        p = match stepRe s;
      in
      if p == null || !(elem (elemAt p 0) (uses ++ attrNames modules)) then
        fail "step '${s}' is not <one of ${toString (uses ++ attrNames modules)}>.<verb>"
      else if elemAt p 1 == "test" && (!testsRun || separate) then
        ""
      else
        let
          bs = elemAt p 0;
          call =
            if elem bs uses then "do {\ncd (${bs} workdir)\n${bs} ${elemAt p 1}\n}" else "${bs} ${elemAt p 1}";
        in
        # cross without binfmt decides at build time (prepare) that tests cannot run
        if elemAt p 1 == "test" then
          "if (ctx).testsRun {\nnote step ${s}\n${call}\n}"
        else
          "note step ${s}\n${call}";
  # `modules.zig = ./build.nu`: the package's own verbs as one more nu module, for steps too long
  # to read inline ("zig.restore"). It imports the builder by bare name (`use core.nu *`)
  modules = args.modules or { };
  prelude =
    preludeBase
    ++ map (u: "use ${tree}/${buildSystems.${u}.module}") uses
    ++ map (m: "module ${m} { export use ${modules.${m}} * }\nuse ${m}") (attrNames modules);
  # every step starts in a known directory: `<bs> workdir` for a build system's verbs, the first
  # build system's for inline steps and package modules. setup exports env, hence --env
  workdir = if uses == [ ] then "(ctx).src" else "${builtins.head uses} workdir";
  setups = map (
    u: "note setup ${u}\ndo --env {\nmkdir (${u} workdir)\ncd (${u} workdir)\n${u} setup\n}"
  ) uses;
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

  # an upstream-binary package says `prebuilt`, or one of its build systems does (pyapp: wheels)
  prebuilt = args.prebuilt or (any (u: buildSystems.${u}.prebuilt == true) uses);
  spec =
    removeAttrs args [
      "source"
      "patches"
      "buildDependencies"
      "dependencies"
      "bootstrapTools"
    ]
    // listToAttrs (
      map (u: {
        name = u;
        value = buildSystems.${u}.defaults args // (args.${u} or { });
      }) (filter (u: args ? ${u} || buildSystems.${u}.defaults args != { }) uses)
    )
    // {
      inherit steps prebuilt;
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
    ++ (if prebuilt == true then relocTools else [ ])
    ++ concatMap (u: buildSystems.${u}.tools args ++ stackBefore buildSystems.${u}.stack) uses
    ++ (if args.bootstrapTools or false then baseTools.bootstrap else baseTools.full);
    dependencies = (args.dependencies or [ ]) ++ concatMap (u: buildSystems.${u}.dependencies) uses;
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
drv
// {
  pname = name;
  args = args0; # what package.nix wrote, for `variant`
}
// (if separate then { tests = testsDrv; } else { })
