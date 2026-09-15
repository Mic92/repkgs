{ package }:
package {
  name = "which";
  uses = [ "autotools" ];
  # its 1990s getopt.h declares `extern int getopt();`, a conflict with unistd.h's in C23
  autotools.flags = [ "CFLAGS=-std=gnu17" ];
}
