# cmake by its ./bootstrap, for pkgs/ll/llvm/toolchain.nu only
use ../../../bootstrap/lib.nu *

def main []: nothing -> nothing {
  let src = (unpack cmake)
  let sh = (tool sh)
  mkdir $"($env.NIX_BUILD_TOP)/build"
  cd $"($env.NIX_BUILD_TOP)/build"
  with-env {CC: cc, CXX: c++, MAKE: (tool make), CONFIG_SHELL: $sh} {
    (x $sh $"($src)/bootstrap" $"--prefix=($env.out)" $"--parallel=(cores)" --no-system-libs --no-qt-gui
      -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_TESTING=OFF -DBUILD_CursesDialog=OFF -DCMake_BUILD_LTO=OFF
      $"-DCMAKE_SYSTEM_PREFIX_PATH=($env.sysroot)")
  }
  x make -j (cores | into string) $"SHELL=($sh)"
  x make install $"SHELL=($sh)"
  rm -rf $"($env.out)/doc" ...(files --dirs $"($env.out)/share/cmake-*/Help")
}
