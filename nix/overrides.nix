# Overrides: edit package specs from outside the tree (docs/design.md "Overrides"), and the same
# verbs in-tree as `variant pkgs.llvm { cmake.defs.merge = { … }; }` in a package.nix.
#
#   import ./. { overrides = { jq.autotools.flags.append = [ "--x" ]; }; }
#
# A tree of <package>.<field>….<verb>. Verbs:
#   set      replace the value (creates the field if missing)
#   append   add to the end of a list        prepend  add to the front
#   merge    // into an attrset               remove   drop list elements / attr names, or `true`: the field
#   edit     on a package only: a function spec -> spec, applied after the other verbs
#   features on a package only: { <feature> = value; }, no verbs (nix/features.nix)
# One node applies as set, remove, merge, prepend/append: `merge`/`append`/`prepend` create a
# missing field (or refill one `remove = true` dropped), and a list `remove` also filters what
# merge/append/prepend add. In dependencies/buildDependencies a string names a package of the
# final set, and remove matches by package name. `overrides` may be a list of trees: they are
# merged first (set/edit: last wins, list verbs concatenate, `remove = true` beats element
# removes), then applied once per package. Unknown package, remove of a missing field, a verb
# argument of the wrong type, or a verb that does not fit the value's type is an error.
let
  inherit (builtins)
    all
    any
    attrNames
    concatStringsSep
    elem
    filter
    foldl'
    isAttrs
    isList
    isString
    mapAttrs
    typeOf
    zipAttrsWith
    ;
  verbs = [
    "set"
    "append"
    "prepend"
    "merge"
    "remove"
  ];
  isVerbNode = node: isAttrs node && node != { } && all (k: elem k verbs) (attrNames node);

  mergeTrees =
    trees:
    zipAttrsWith (
      name: vals:
      # a field that happens to be called like a verb (phases.remove) holds verb nodes itself
      if elem name verbs && all isVerbNode vals then
        mergeTrees vals
      else if name == "set" || name == "edit" then
        builtins.elemAt vals (builtins.length vals - 1)
      else if name == "features" then
        foldl' (a: b: a // b) { } vals
      else if name == "remove" && any (v: v == true) vals then
        true
      else if name == "append" || name == "prepend" || name == "remove" then
        builtins.concatLists (
          map (v: if isList v then v else throw "overrides: ${name} takes a list, got a ${typeOf v}") vals
        )
      else if name == "merge" then
        foldl' (a: b: a // b) { } vals
      else if all isAttrs vals then
        mergeTrees vals
      else
        throw "overrides: conflicting values at ${name}"
    ) trees;

  # dependency lists: strings resolve in pkgs, remove matches by package name
  depFields = [
    "dependencies"
    "buildDependencies"
  ];
  pname = d: d.pname or d.name or (toString d);

  applyVerbs =
    ctx: path: node: has: old:
    let
      here = concatStringsSep "." path;
      fail = msg: throw "overrides: ${ctx.pkg}.${here}: ${msg}";
      isDeps = builtins.length path == 1 && elem (builtins.head path) depFields;
      resolve = v: if isDeps && isString v then ctx.pkgs.${v} or (fail "no package named ${v}") else v;
      arg =
        verb: want:
        let
          v = node.${verb};
        in
        if want == "list" && isList v then
          map resolve v
        else if want == "set" && isAttrs v then
          v
        else
          fail "${verb} takes a ${want}, got a ${typeOf v}";
      lists = node ? prepend || node ? append;
      drop = node ? remove && node.remove != true;
      dropped =
        if drop then map (r: if isDeps && !isString r then pname r else r) (arg "remove" "list") else [ ];
      keep = d: !(elem (if isDeps then pname d else d) dropped);
      # the value the other verbs edit: set, else the field, else what merge/append imply
      start =
        if node ? set then
          (if isDeps then arg "set" "list" else node.set)
        else if has && (node.remove or null) != true then
          old
        else if node ? merge then
          { }
        else if lists then
          [ ]
        else if node ? remove then
          (if has then null else fail "remove: no such field")
        else
          fail "no such field (use .set to create it)";
      # remove also filters what merge/append/prepend add, so a later tree can take back an earlier one's
      afterRemove =
        if !drop then
          start
        else if isList start then
          filter keep start
        else if isAttrs start then
          removeAttrs start dropped
        else
          fail "remove from a ${typeOf start}, expected a list or set";
      afterMerge =
        if !(node ? merge) then
          afterRemove
        else if isAttrs afterRemove then
          afterRemove // removeAttrs (arg "merge" "set") dropped
        else
          fail "merge into a ${typeOf afterRemove}, expected a set";
    in
    if !lists then
      afterMerge
    else if !isList afterMerge then
      fail "append to a ${typeOf afterMerge}, expected a list"
    else
      filter keep (
        (if node ? prepend then arg "prepend" "list" else [ ])
        ++ afterMerge
        ++ (if node ? append then arg "append" "list" else [ ])
      );

  # walk tree and spec together. Returns the edited value, or null with remove = true handled by the caller
  walk =
    ctx: path: tree: has: old:
    if isVerbNode tree then
      applyVerbs ctx path tree has old
    else if !isAttrs tree then
      throw "overrides: ${ctx.pkg}.${concatStringsSep "." path}: expected a verb (${concatStringsSep " " verbs}), got a ${typeOf tree}"
    else if tree ? edit then
      throw "overrides: ${ctx.pkg}.${concatStringsSep "." path}.edit: edit goes on the package, not a field"
    # a verb name whose value is not itself a node was meant as a verb (a field called `remove`
    # is still reachable: phases.remove.set = [ … ])
    else if any (k: elem k verbs && !isVerbNode tree.${k}) (attrNames tree) then
      throw "overrides: ${ctx.pkg}.${concatStringsSep "." path}: mixes verbs (${
        toString (filter (k: elem k verbs && !isVerbNode tree.${k}) (attrNames tree))
      }) with fields (${toString (filter (k: !(elem k verbs) || isVerbNode tree.${k}) (attrNames tree))})"
    else
      let
        cur =
          if has && isAttrs old then
            old
          else if has then
            throw "overrides: ${ctx.pkg}.${concatStringsSep "." path}: is a ${typeOf old}, cannot descend"
          else
            { };
        edited = mapAttrs (k: sub: walk ctx (path ++ [ k ]) sub (cur ? ${k}) (cur.${k} or null)) tree;
        removed = filter (k: tree.${k} == { remove = true; } && builtins.seq edited.${k} true) (
          attrNames tree
        );
      in
      removeAttrs (cur // edited) removed;

  # one package's subtree applied to its spec (also what `variant` in package.nix files uses)
  applyOne =
    pkgs: name: node: spec:
    if !isAttrs node then
      throw "overrides: ${name}: expected { <field>… }, got a ${typeOf node}"
    else if !builtins.isFunction (node.edit or (s: s)) then
      throw "overrides: ${name}.edit: expected a function spec -> spec, got a ${typeOf node.edit}"
    else
      (node.edit or (s: s)) (
        walk {
          pkg = name;
          inherit pkgs;
        } [ ] (removeAttrs node [ "edit" ]) true spec
      );
  # from the user's tree, where `<pkg>.features` is plain values that nix/set.nix resolved
  # before the spec existed
  apply =
    pkgs: tree: name: spec:
    if !(tree ? ${name}) then
      spec
    else if !isAttrs tree.${name} then
      applyOne pkgs name tree.${name} spec
    else
      applyOne pkgs name (removeAttrs tree.${name} [ "features" ]) spec;

  # packages the tree names that the set lacks
  unknown = pkgs: tree: filter (n: !(pkgs ? ${n})) (attrNames tree);
in
{
  merge = trees: if isList trees then mergeTrees trees else trees;
  inherit apply applyOne unknown;
}
