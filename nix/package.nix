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
  # [pin] sys in sources.toml names packages of the set
  pkgs,
  lib,
}:
let
  elf = platform.binfmt == "elf";
  inherit (lib)
    join
    lines
    ;
  inherit (builtins)
    all
    any
    attrNames
    concatMap
    elem
    elemAt
    filter
    foldl'
    head
    hasContext
    isAttrs
    isList
    isString
    length
    listToAttrs
    match
    ;

  # the builder modules every script imports: one string for the set
  preludeCommon = "use ${tree}/core.nu *\nuse ${tree}/prepare.nu\nuse ${tree}/finish.nu\nuse ${tree}/implant.nu";
  tree = builtins.path {
    path = ../builder;
    name = "build";
  };
  reserved = [
    "name"
    "features"
    "platforms"
    "version"
    "source"
    "patches"
    "uses"
    "phases"
    "buildDependencies"
    "dependencies"
    "sys"
    "bin"
    "tests"
    "exports"
    "env"
    "root"
    "cc"
    "bootstrapTools"
    "prebuilt"
    "debug"
    "install"
    "links"
    "completions"
  ];

  # the part of every derivation that is the same across the set: built once
  setCommon = {
    inherit (platform) system;
    __structuredAttrs = true;
    # content-addressed: rebuilds that change no bytes do not propagate
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
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
        osNames
        clangTarget
        gnuTriple
        rustTriple
        opensslTarget
        buildRustTriple
        cross
        emulator
        abi
        libc
        posix
        ext
        hardening
        ;
      inherit (toolchain) sysroot;
      probe = if platform.cross then "${toolchain.sysroot}/lib/${platform.interp}" else "";
      # `prebuilt`: upstream ELFs get our dynamic linker implanted (true) or via launch ("ldso")
      interp = "${toolchain.sysroot}/lib/${platform.interp}";
      launch = if elf then "${launch}/bin/launch" else "";
      # finish.nu runs the version check under it: a failed dlopen fails the build
      dlaudit = if elf then "${dlaudit}/lib/dlaudit.so" else "";
      relocStub = "${toolchain}/lib/reloc_stub.bin";
    };
  };
  phaseRe = "([a-z][a-z0-9]*)\\.([a-zA-Z][a-zA-Z-]*)";
in
# sources: the package's sources.toml (nix/sources.nix) or null. It supplies version and source
# unless package.nix sets them (local trees, demos)
# dir: the package's directory, where a phase prefix that is no build system finds <prefix>.nu
sources0: dir: features: fn: args0:
let
  edited = if edit == null then args0 else edit args0.name args0;
  # an override may repin the package: `pin.merge = { version = "…"; }` plus
  # `hash.merge = { default = "sha256-…"; }` re-read sources.toml under the new [pin]
  repinned = edit != null && sources0 != null && (edited ? pin || edited ? hash);
  sources = if repinned then sources0.repin (edited.pin or { }) (edited.hash or { }) else sources0;
  # `completions.<shell> = [ files ]`, sugar for `install`: each file goes where that shell
  # looks. bash and zsh find completions by command name (`<cmd>`, `_<cmd>`), fish and nu keep the
  # file name. A ./path beside package.nix arrives with a store hash prefix, dropped here
  completionDirs = {
    bash = "share/bash-completion/completions";
    zsh = "share/zsh/site-functions";
    fish = "share/fish/vendor_completions.d";
    nu = "share/nushell/vendor/autoload";
  };
  completionName =
    shell: f:
    let
      m = match "([a-z0-9]{32}-)?((.*)\\.${shell}|.*)" (baseNameOf f);
      stem = if elemAt m 2 != null then elemAt m 2 else elemAt m 1;
    in
    if shell == "bash" then
      stem
    else if shell == "zsh" then
      (if match "_.*" stem != null then stem else "_" + stem)
    else
      elemAt m 1;
  completionsInstall =
    shells:
    listToAttrs (
      concatMap (
        shell:
        map (f: {
          name = "${completionDirs.${shell}}/${completionName shell f}";
          value = f;
        }) shells.${shell}
      ) (attrNames shells)
    );
  args =
    (
      if sources == null then
        { }
      else
        {
          inherit (sources) version;
          # one tarball for all, or one per platform ("x86_64-linux", "aarch64-macos")
          source = if sources.has "default" then "default" else "${platform.cpu}-${platform.os}";
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
    )
    // (
      if edited ? completions then
        { install = completionsInstall edited.completions // (edited.install or { }); }
      else
        { }
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
      "dlopen"
    ];
    cc = [
      "cflags"
      "cxxflags"
      "ldflags"
      "hardening"
    ];
    completions = attrNames completionDirs;
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
  # `<bs> = on cond { … }` for a build system used on some platforms only leaves { } on the others
  unknownFields =
    filter (k: args.${k} != { }) (attrNames (removeAttrs args (reserved ++ uses)))
    ++ (if args ? tests then subKeys "tests" args.tests else [ ])
    ++ (if args ? cc then subKeys "cc" args.cc else [ ])
    ++ (if args ? completions then subKeys "completions" args.completions else [ ]);
  # a library among the build tools or a tool among the libraries: natively both platforms
  # coincide and nothing would notice, so it is checked here
  wrongPlatform =
    map (d: "dependencies: ${d.pname} is built for ${d.platform}") (
      filter (d: (d.platform or platform.name) != platform.name) (args.dependencies or [ ])
    )
    ++ map (d: "buildDependencies: ${d.pname} is built for ${d.platform}") (
      filter (d: (d.platform or platform.system) != platform.system) (args.buildDependencies or [ ])
    );
  # `supported` without forcing the derivation (docs/design.md): platforms.{cpu,os,abi,libc,posix,cross},
  # a per-cpu tarball in sources.toml, and the dependencies' own verdicts
  badCpu = args ? platforms.cpu && !(elem platform.cpu args.platforms.cpu);
  badOs = args ? platforms.os && !(elem platform.os args.platforms.os);
  badAbi = args ? platforms.abi && !(elem platform.abi args.platforms.abi);
  badLibc = args ? platforms.libc && !(elem platform.libc args.platforms.libc);
  needsPosix = (args.platforms.posix or false) && !platform.posix;
  nativeOnly = (args.platforms.cross or true) == false && platform.cross;
  bsReasons = filter (r: r != null) (map (u: buildSystems.${u}.unsupported) uses);
  # `source` as a plain string names a sources.toml key; a cpu the file has no tarball for is
  # unsupported. Paths and derivations (strings with context) are the source itself
  sourceKey =
    let
      s = args.source or null;
    in
    if isString s && !hasContext s then s else null;
  noTarball = sourceKey != null && !(sources.has sourceKey);
  src = if sourceKey != null then sources.fetch sourceKey else args.source;
  unsupportedDeps = filter (d: !(d.supported or true)) (
    common.dependencies
    ++ (args.buildDependencies or [ ])
    ++ concatMap (u: buildSystems.${u}.tools spec) uses
  );
  unsupportedReason =
    if badCpu then
      "${name}: not for ${platform.cpu} (platforms.cpu)"
    else if badOs then
      "${name}: not for ${platform.os} (platforms.os)"
    else if badAbi then
      "${name}: not for the ${platform.abi} ABI (platforms.abi)"
    else if badLibc then
      "${name}: not on ${platform.libc} (platforms.libc)"
    else if needsPosix then
      "${name}: needs a POSIX system (platforms.posix)"
    else if nativeOnly then
      "${name}: runs its own binaries while installing, cannot be cross-built (platforms.cross)"
    else if bsReasons != [ ] then
      "${name}: ${head bsReasons}"
    else if noTarball then
      "${name}: sources.toml has no '${sourceKey}' source"
    else if unsupportedDeps != [ ] then
      "${name} -> ${(head unsupportedDeps).unsupportedReason}"
    else
      null;
  supported = unsupportedReason == null;
  unknownPlatformKeys = attrNames (
    removeAttrs (args.platforms or { }) [
      "cpu"
      "os"
      "abi"
      "libc"
      "posix"
      "cross"
    ]
  );

  # the declaration's shape. Values from outside are checked where they are resolved (nix/features.nix)
  badFeatures =
    if args ? features then
      filter (
        n:
        let
          d = args.features.${n};
          t = builtins.typeOf d.default;
        in
        !(
          isAttrs d
          && d ? default
          &&
            removeAttrs d [
              "default"
              "values"
              "doc"
            ] == { }
          && elem t [
            "bool"
            "string"
            "list"
            "int"
          ]
          && (
            !(d ? values)
            || isList d.values && all (v: elem v d.values) (if t == "list" then d.default else [ d.default ])
          )
        )
      ) (attrNames args.features)
    else
      [ ];
  checks =
    if badFeatures != [ ] then
      fail "features ${toString badFeatures}: want { default (bool, string, list or int), values? (a list the default is from), doc? }"
    else if unknownUses != [ ] then
      fail "unknown build systems ${toString unknownUses} (have: ${toString (attrNames buildSystems)})"
    else if unknownFields != [ ] || unknownPlatformKeys != [ ] then
      fail "unknown fields ${toString (unknownFields ++ map (k: "platforms.${k}") unknownPlatformKeys)}"
    else if wrongPlatform != [ ] then
      fail (join "; " wrongPlatform)
    else
      true;

  # `install`/`links` alone (prebuilt binaries, data): the one phase is copying them into $out.
  # `phases` is the whole list, or edits to the first build system's list (README):
  # { before.<phase> = [..]; after.<phase> = [..]; replace.<phase> = phase | [..]; remove = [..]; }
  phases =
    if (args.phases or [ ]) == [ ] then
      if length uses == 1 then
        buildSystems.${head uses}.phases
      else if uses == [ ] && (args ? install || args ? links) then
        [ ]
      else
        fail "'phases' is required with more than one build system (a list, or edits to the first one's)"
    else if isList args.phases then
      args.phases
    else
      let
        e = args.phases;
        known = buildSystems.${head uses}.phases;
        # an edit gated off with `on cond [ … ]` names a phase of the other platform's build system
        nonEmpty = set: filter (n: set.${n} != [ ]) (attrNames set);
        named =
          nonEmpty (e.before or { })
          ++ nonEmpty (e.after or { })
          ++ attrNames (e.replace or { })
          ++ (e.remove or [ ]);
        unknown = filter (n: !elem n known) named;
        bad = filter (
          n:
          !elem n [
            "before"
            "after"
            "replace"
            "remove"
          ]
        ) (attrNames e);
        asList = x: if isList x then x else [ x ];
      in
      if bad != [ ] then
        fail "phases: unknown edit ${head bad} (before, after, replace, remove)"
      else if unknown != [ ] then
        fail "phases: ${head unknown} is not a phase of ${head uses} (${toString known})"
      else
        concatMap (
          p:
          if elem p (e.remove or [ ]) then
            [ ]
          else
            asList (e.before.${p} or [ ]) ++ asList (e.replace.${p} or p) ++ asList (e.after.${p} or [ ])
        ) known;
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
  # a phase as { test, body }: inline ones and package-module ones built here, a build system's
  # come ready from nix/build-systems.nix. A prefix that is neither: nix reports "path …/<bs>.nu
  # does not exist". An inline phase's env changes carry over to later phases, its cwd does not
  phase =
    s:
    if isAttrs s then
      {
        test = s.name == "test";
        body = "note phase ${s.name}\nlet pwd = $env.PWD\ndo --env {\ncd (${workdir})\nlet c = (ctx)\n${s.run}\n}\ncd $pwd";
      }
    else
      bsPhases.${s} or (
        let
          p = match phaseRe s;
        in
        if p == null then
          fail "phase '${s}' is not <build system or module>.<phase>"
        else if elem (elemAt p 0) uses then
          {
            test = false;
            body = "note phase ${s}\ndo {\ncd (${elemAt p 0} workdir)\n${elemAt p 0} ${elemAt p 1}\n}";
          }
        else
          {
            test = elemAt p 1 == "test";
            body = "note phase ${s}\n${elemAt p 0} ${elemAt p 1}";
          }
      );
  # "<bs>.<verb>" -> { test, body } for the build systems in use, ready made in build-systems.nix
  bsPhases =
    if length uses == 1 then
      buildSystems.${head uses}.phase
    else
      foldl' (a: u: a // buildSystems.${u}.phase) { } uses;
  # in the build script: test phases drop out when disabled or separate, and otherwise ask prepare
  # (cross without binfmt decides at build time that tests cannot run)
  phaseLine =
    s:
    let
      p = phase s;
    in
    if !p.test then
      p.body
    else if !testsRun || separate then
      ""
    else
      "if (ctx).testsRun {\n${p.body}\n}";
  # a phase "zig.restore" whose prefix is no `uses` entry is the package's own module zig.nu next
  # to package.nix, for phases too long to read inline. It imports the builder by bare name
  modules =
    if !(args ? phases) then
      [ ]
    else
      foldl' (acc: m: if m == null || elem m (uses ++ acc) then acc else acc ++ [ m ]) [ ] (
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
  prelude = [
    preludeCommon
  ]
  ++ map (u: "use ${tree}/${buildSystems.${u}.module}") uses
  ++ map (m: "use ${storeModule m}") modules;
  # each build system's OPTIONS table for prepare.nu to merge the spec over
  systemsArg = "{${join ", " (map (u: "${u}: $" + u + ".OPTIONS") uses)}}";
  # every phase starts in a known directory: `<bs> workdir` for a build system's phases, the first
  # build system's for inline phases and package modules. setup exports env, hence --env
  workdir = if uses == [ ] then "(ctx).src" else "${builtins.head uses} workdir";
  setups = map (u: buildSystems.${u}.setup) uses;
  # also `pkg.script`: lints/package-scripts.nu has nu parse it before anything builds
  script = lines (
    prelude
    ++ [ "prepare ${systemsArg}" ]
    ++ setups
    ++ map phaseLine phases
    ++ [ (if separate then "finish --keep-tree" else "finish") ]
  );
  testScript = lines (
    prelude
    ++ [ "prepare ${systemsArg} --from-tree ${drv.tree}" ]
    ++ setups
    ++ map (p: p.body) (filter (p: p.test) (map phase phases))
    ++ [ "finish tests" ]
  );

  # an upstream-binary package says `prebuilt`, or one of its build systems does (pyapp: wheels)
  prebuilt = args.prebuilt or (any (u: buildSystems.${u}.prebuilt == true) uses);
  # DWARF goes to the `debug` output (finish.nu). false when the build cannot be made to keep it
  debug = args.debug or (prebuilt == false);
  # [pin] sys of sources.toml. null: no sources.toml, dependencies are all by hand
  sys = args.sys or (if sources == null then null else sources.sys);
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
        value = buildSystems.${u}.defaults src // (args.${u} or { });
      }) uses
    )
    // {
      # sys for sys-libs.nu `check`
      inherit
        phases
        prebuilt
        debug
        sys
        ;
    }
    # resolved values, for phases: `(ctx).spec.features.tls`
    // (if features == { } then { } else { inherit features; });
  # PATH order: the base tools (GNU userland, then the seed) go last and only once, so a build
  # system that lists the seed as its `sh` does not pull toybox ahead of coreutils and grep
  buildDeps =
    base:
    filter (d: !(elem d base)) (
      [ toolchain ]
      ++ (args.buildDependencies or [ ])
      ++ (if prebuilt == true then relocTools else [ ])
      ++ concatMap (u: buildSystems.${u}.tools spec ++ stackBefore buildSystems.${u}.stack) uses
    )
    ++ base;
  common = setCommon // {
    inherit src;
    inherit (args) version;
    patches = args.patches or [ ];
    inherit spec;
    buildDependencies = buildDeps (
      if args.bootstrapTools or false then baseTools.bootstrap else baseTools.full
    );
    # [pin] sys: libraries the lock files can link (builder/sys-libs.nu). Those the set lacks
    # here are left to the locked package (vendored copy or feature off)
    dependencies =
      (args.dependencies or [ ])
      ++ map (n: pkgs.${n}) (filter (n: pkgs.${n}.supported or false) (if sys == null then [ ] else sys))
      ++ concatMap (u: buildSystems.${u}.dependencies) uses;
  };
  drv = derivation (
    common
    // {
      name = if platform.cross then "${name}-${platform.name}" else name;
      outputs = [
        "out"
        "debug"
      ]
      ++ (if separate then [ "tree" ] else [ ]);
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
  decl = args0.features or { };
  inherit dir features fn;
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
