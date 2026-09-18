{ package }:
package {
  name = "brotli";
  uses = [ "cmake" ];
  patches = [ ./upstream-loongarch-model-attr.patch ];
}
