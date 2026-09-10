# Overrides: edit package specs from outside the tree (docs/design.md "Overrides").
#
#   import ./. { overrides = { jq.autotools.flags.append = [ "--x" ]; }; }
#
# A tree of <package>.<field>….<verb>. Verbs:
#   set      replace the value (creates the field if missing)
#   append   add to the end of a list        prepend  add to the front
#   merge    // into an attrset               remove   drop list elements / attr names, or `true`: the field
#   edit     on a package only: a function spec -> spec, applied after the other verbs
# In dependencies/buildDependencies a string names a package of the final set, and remove
# matches by package name. `overrides` may be a list of trees: they are merged first (set: last
# wins, list verbs concatenate), then applied once per package. Unknown package, missing field
# without set, or a verb that does not fit the value's type is an error.
let
  inherit (builtins)
    all
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
    "edit"
  ];
  isVerbNode = node: isAttrs node && node != { } && all (k: elem k verbs) (attrNames node);

  mergeTrees =
    trees:
    zipAttrsWith (
      name: vals:
      if name == "set" || name == "edit" then
        builtins.elemAt vals (builtins.length vals - 1)
      else if name == "append" || name == "prepend" || name == "remove" then
        builtins.concatLists vals
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
      resolveList = map resolve;
      base =
        if node ? set then
          (if isList node.set then resolveList node.set else resolve node.set)
        else if has then
          old
        else if node ? merge then
          { }
        else
          fail "no such field (use .set to create it)";
      needList = verb: v: if isList v then v else fail "${verb} on a ${typeOf v}, expected a list";
      afterRemove =
        if !(node ? remove) then
          base
        else if node.remove == true then
          null
        else if isList base then
          let
            drop = map (r: if isString r then r else pname r) node.remove;
          in
          filter (d: !(elem (if isDeps then pname d else d) drop)) base
        else if isAttrs base then
          removeAttrs base node.remove
        else
          fail "remove ${typeOf node.remove} on a ${typeOf base}";
      afterMerge =
        if !(node ? merge) then
          afterRemove
        else if isAttrs afterRemove then
          afterRemove // node.merge
        else
          fail "merge on a ${typeOf afterRemove}, expected a set";
      afterLists =
        (if node ? prepend then resolveList (needList "prepend" node.prepend) else [ ])
        ++ (if node ? prepend || node ? append then needList "append/prepend" afterMerge else afterMerge)
        ++ (if node ? append then resolveList (needList "append" node.append) else [ ]);
    in
    if node ? prepend || node ? append then afterLists else afterMerge;

  # walk tree and spec together. Returns the edited value, or null with remove = true handled by the caller
  walk =
    ctx: path: tree: has: old:
    if isVerbNode tree then
      applyVerbs ctx path tree has old
    else if !isAttrs tree then
      throw "overrides: ${ctx.pkg}.${concatStringsSep "." path}: expected a verb (${concatStringsSep " " verbs}), got a ${typeOf tree}"
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
        removed = filter (k: (tree.${k}.remove or null) == true) (attrNames tree);
      in
      removeAttrs (cur // edited) removed;

  apply =
    pkgs: tree: name: spec:
    if tree ? ${name} then
      (tree.${name}.edit or (s: s)) (
        walk {
          pkg = name;
          inherit pkgs;
        } [ ] (removeAttrs tree.${name} [ "edit" ]) true spec
      )
    else
      spec;

  # packages the tree names that the set lacks
  unknown = pkgs: tree: filter (n: !(pkgs ? ${n})) (attrNames tree);
in
{
  merge = trees: if isList trees then mergeTrees trees else trees;
  inherit apply unknown;
}
