{ package }:
package {
  name = "bash";
  uses = [ "autotools" ];
  bootstrapTools = true;
  autotools.flags = [
    "--without-bash-malloc"
    "--disable-readline" # build-machine shell for configure scripts, not for people
    "bash_cv_func_strtoimax=y"
    "bash_cv_getcwd_malloc=yes"
    "bash_cv_job_control_missing=nomissing"
    "bash_cv_sys_named_pipes=nomissing"
  ];
  tests.relocated = true;
  tests.run = false; # interactive/tty
  phases = [
    "autotools.configure"
    "autotools.build"
    "autotools.install"
    {
      name = "sh-alias";
      run = "^ln -s bash $\"($c.out)/bin/sh\"";
    }
  ];
  bin = [
    "bash"
    "sh"
  ];
}
