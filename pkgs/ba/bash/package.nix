{ package }:
package {
  name = "bash";
  uses = [ "autotools" ];
  bootstrapTools = true;
  # locale dir, bashdb and the loadables kit relative to where bash is
  patches = [ ./relocatable.patch ];
  autotools.flags = [
    "--without-bash-malloc"
    "--disable-readline" # build-machine shell for configure scripts, not for people
    "bash_cv_func_strtoimax=y"
    "bash_cv_getcwd_malloc=yes"
    "bash_cv_job_control_missing=nomissing"
    "bash_cv_sys_named_pipes=nomissing"
  ];
  tests.run = false; # interactive/tty
  links."bin/sh" = "bash";
  bin = [
    "bash"
    "sh"
  ];
}
