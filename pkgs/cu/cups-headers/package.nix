# The JDK dlopens libcups at run time and only needs <cups/*.h> to build. Full cups (daemon,
# gnutls, avahi …) is not worth it for that.
{ package }:
package {
  name = "cups-headers";
  steps = [
    {
      name = "install";
      run = ''
        let inc = $"((ctx).out)/include/cups"
        mkdir $inc
        for h in (glob cups/*.h) { cp $h $inc }
      '';
    }
  ];
}
