# The `package` function: spec attrset -> derivation (+ `.tests` when tests.separate).
# Validates field and option names at eval time, then generates the nu script
#   use core.nu *; use prepare.nu; use finish.nu; use implant.nu; use <bs>.nu …; prepare; <bs> setup …; <phase> …; finish
# that nu executes in a single nu process. Vocabulary: README.md "Writing a package".
{
  platform,
  toolchain,
  launch,
  dlaudit,
  buildSystems,
  baseTools,
  relocTools,
  nu,
  # overrides applied to a spec before validation: name -> spec -> spec (nix/overrides.nix)
  edit,
}:
let
  elf = platform.binfmt == "elf";
  hardening = import ./hardening.nix;
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
    length
    listToAttrs
    match
    ;

  tree = builtins.path {
    path = ../builder;
    name = "build";
  };
  reserved = [
    "name"
    "platforms"
    "version"
    "source"
    "patches"
    "uses"
    "phases"
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
        binfmt
        names
        triple
        rustTriple
        cross
        emulator
        ;
      inherit (toolchain) sysroot;
      configTriple = platform.configTriple or platform.triple;
      probe = if platform.cross then "${toolchain.sysroot}/lib/${platform.interp}" else "";
      # `prebuilt`: upstream ELFs get our dynamic linker implanted (true) or via launch ("ldso")
      interp = "${toolchain.sysroot}/lib/${platform.interp}";
      launch = if elf then "${launch}/bin/launch" else "";
      # finish.nu runs the version check under it: a failed dlopen fails the build
      dlaudit = if elf then "${dlaudit}/lib/dlaudit.so" else "";
      relocStub = "${toolchain}/lib/reloc_stub.bin";
    };
    # nix/hardening.nix as data for builder/env.nu: the flag table and what is on for this platform
    hardening = {
      inherit (hardening) flags cxx link;
      enabled = hardening.forPlatform platform;
    };
  };
  phaseRe = "([a-z][a-z0-9]*)\\.([a-zA-Z]+)";
  # "<bs>.test" or an inline phase named "test"
  isTest =
    s:
    if isAttrs s then
      s.name == "test"
    else
      let
        p = match phaseRe s;
      in
      p != null && elemAt p 1 == "test";
in
# sources: the package's sources.toml (nix/sources.nix) or null. It supplies version and source
# unless package.nix sets them (local trees, demos)
# dir: the package's directory, where a phase prefix that is no build system finds <prefix>.nu
sources0: dir: args0:
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
  # fields whose sub-keys are a fixed vocabulary: a typo there is as silent as one at top level
  subFields = {
    tests = [
      "run"
      "separate"
      "parallel"
      "version"
      "relocated"
      "dlopen"
    ];
    cc = [
      "cflags"
      "cxxflags"
      "ldflags"
      "hardening"
    ];
    "cc.hardening" = [
      "fortify"
      "stackprotector"
      "stackclashprotection"
      "trivialautovarinit"
      "format"
      "strictoverflow"
      "strictflexarrays"
      "zerocallusedregs"
      "noplt"
      "libcxxhardening"
      "relro"
      "bindnow"
      "relr"
    ];
  };
  subKeys =
    prefix: set:
    if isAttrs set then
      concatMap (
        k:
        let
          path = "${prefix}.${k}";
        in
        if !(elem k subFields.${prefix}) then
          [ path ]
        else if subFields ? ${path} then
          subKeys path set.${k}
        else
          [ ]
      ) (attrNames set)
    else
      [ ];
  unknownFields =
    filter (f: !(elem f (reserved ++ uses))) (attrNames args)
    ++ subKeys "tests" (args.tests or { })
    ++ subKeys "cc" (args.cc or { });
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
  # a library among the build tools or a tool among the libraries: natively both platforms
  # coincide and nothing would notice, so it is checked here
  wrongPlatform =
    map (d: "dependencies: ${d.pname} is built for ${d.platform}") (
      filter (d: (d.platform or platform.name) != platform.name) (args.dependencies or [ ])
    )
    ++ map (d: "buildDependencies: ${d.pname} is built for ${d.platform}") (
      filter (d: (d.platform or platform.system) != platform.system) (args.buildDependencies or [ ])
    );
  # `supported` without forcing the derivation (docs/design.md): platforms.cpu, platforms.cross,
  # a per-cpu tarball in sources.toml, and the dependencies' own verdicts
  badCpu = args ? platforms.cpu && !(elem platform.cpu args.platforms.cpu);
  nativeOnly = (args.platforms.cross or true) == false && platform.cross;
  bsReasons = filter (r: r != null) (map (u: buildSystems.${u}.unsupported) uses);
  noTarball =
    sources0 != null && !(args0 ? source) && !(sources0.has "default") && !(sources0.has platform.cpu);
  unsupportedDeps = filter (d: !(d.supported or true)) (
    common.dependencies
    ++ (args.buildDependencies or [ ])
    ++ concatMap (u: buildSystems.${u}.tools args) uses
  );
  unsupportedReason =
    if badCpu then
      "${name}: not for ${platform.cpu} (platforms.cpu)"
    else if nativeOnly then
      "${name}: runs its own binaries while installing, cannot be cross-built (platforms.cross)"
    else if bsReasons != [ ] then
      "${name}: ${head bsReasons}"
    else if noTarball then
      "${name}: sources.toml has no '${platform.cpu}' source"
    else if unsupportedDeps != [ ] then
      "${name} -> ${(head unsupportedDeps).unsupportedReason}"
    else
      null;
  supported = unsupportedReason == null;
  unknownPlatformKeys = attrNames (
    removeAttrs (args.platforms or { }) [
      "cpu"
      "cross"
    ]
  );

  checks =
    if unknownUses != [ ] then
      fail "unknown build systems ${toString unknownUses} (have: ${toString (attrNames buildSystems)})"
    else if unknownFields != [ ] || unknownPlatformKeys != [ ] then
      fail "unknown fields ${toString (unknownFields ++ map (k: "platforms.${k}") unknownPlatformKeys)}"
    else if badOptions != [ ] then
      fail (builtins.concatStringsSep "; " badOptions)
    else if wrongPlatform != [ ] then
      fail (builtins.concatStringsSep "; " wrongPlatform)
    else
      true;

  # `install`/`links` alone (prebuilt binaries, data): the one phase is copying them into $out
  phases =
    args.phases or (
      if length uses == 1 then
        buildSystems.${head uses}.phases
      else if uses == [ ] && (args ? install || args ? links) then
        [ ]
      else
        fail "'phases' is required with more than one build system"
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
  # `<pkg>.tests` restores it and runs only the test phases: a test failure fails that derivation,
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
  # a phase's nu text, ungated
  phaseBody =
    s:
    if isAttrs s then
      "note phase ${s.name}\ndo {\ncd (${workdir})\nlet c = (ctx)\n${s.run}\n}"
    else
      let
        p = match phaseRe s;
        bs = elemAt p 0;
        call =
          if elem bs uses then "do {\ncd (${bs} workdir)\n${bs} ${elemAt p 1}\n}" else "${bs} ${elemAt p 1}";
      in
      # a prefix that is neither: nix reports "path …/<bs>.nu does not exist"
      if p == null then
        fail "phase '${s}' is not <build system or module>.<phase>"
      else
        "note phase ${s}\n${call}";
  # in the build script: test phases drop out when disabled or separate, and otherwise ask prepare
  # (cross without binfmt decides at build time that tests cannot run)
  phaseLine =
    s:
    if !isTest s then
      phaseBody s
    else if !testsRun || separate then
      ""
    else
      "if (ctx).testsRun {\n${phaseBody s}\n}";
  # a phase "zig.restore" whose prefix is no `uses` entry is the package's own module zig.nu next
  # to package.nix, for phases too long to read inline. It imports the builder by bare name
  modules = foldl' (acc: m: if m == null || elem m (uses ++ acc) then acc else acc ++ [ m ]) [ ] (
    map (
      s:
      let
        p = if isAttrs s then null else match phaseRe s;
      in
      if p == null then null else head p
    ) phases
  );
  # <store dir>/<m>.nu: nu names a module after its file, a bare store path would be <hash>-<m>
  storeModule =
    m:
    "${
      builtins.path {
        path = dir;
        name = "module";
        filter = p: _: baseNameOf p == "${m}.nu";
      }
    }/${m}.nu";
  prelude =
    map (f: "use ${tree}/${f}") (
      [
        "core.nu *"
        "prepare.nu"
        "finish.nu"
        "implant.nu"
      ]
      ++ map (u: buildSystems.${u}.module) uses
    )
    ++ map (m: "use ${storeModule m}") modules;
  # every phase starts in a known directory: `<bs> workdir` for a build system's phases, the first
  # build system's for inline phases and package modules. setup exports env, hence --env
  workdir = if uses == [ ] then "(ctx).src" else "${builtins.head uses} workdir";
  setups = map (
    u: "note setup ${u}\ndo --env {\nmkdir (${u} workdir)\ncd (${u} workdir)\n${u} setup\n}"
  ) uses;
  # also `pkg.script`: lints/package-scripts.nu has nu parse it before anything builds
  script = concatStringsSep "\n" (
    prelude
    ++ [ "prepare" ]
    ++ setups
    ++ map phaseLine phases
    ++ [ (if separate then "finish --keep-tree" else "finish") ]
  );
  testScript = concatStringsSep "\n" (
    prelude
    ++ [ "prepare --from-tree ${drv.tree}" ]
    ++ setups
    ++ map phaseBody (filter isTest phases)
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
      }) uses
    )
    // {
      inherit phases prebuilt;
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
  platform = platform.name;
  # what package.nix wrote and read, for `variant`
  args = args0;
  sources = sources0;
  inherit dir;
  inherit supported unsupportedReason script;
}
// (if separate then { tests = testsDrv; } else { })
// (
  if supported then
    { }
  else
    listToAttrs (
      map
        (n: {
          name = n;
          value = throw unsupportedReason;
        })
        (
          [
            "drvPath"
            "outPath"
            "tests"
          ]
          ++ drv.outputs
        )
    )
)
