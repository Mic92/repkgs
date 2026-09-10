# ExDoc as an escript (mix, hex deps from mix.lock)
{ package }:
package {
  name = "ex_doc";
  uses = [ "mix" ];
  mix.escript = [ "ex_doc" ];
}
