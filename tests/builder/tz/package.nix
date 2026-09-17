{ package }:
package {
  name = "test-tz";
  version = "1";
  source = ./src;
  phases = [
    {
      name = "build";
      run = ''
        mkdir $"($c.out)/bin"
        x cc tz.c -o $"($c.out)/bin/tz"
      '';
    }
  ];
}
