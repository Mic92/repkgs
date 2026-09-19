# find_library() answers with a file in the sysroot (<sysroot>/usr/lib/libm.so, the macOS SDK's
# libz.tbd or Foo.framework). Recorded in an installed *Config.cmake or .pc that path names this
# build's sysroot for every dependent. The linker finds -lm / -framework Foo in whichever sysroot
# is current, so hand that back instead. Injected through CMAKE_PROJECT_TOP_LEVEL_INCLUDES by
# builder/systems/cmake.nu with -DPKGS_SYSROOT.
function(find_library var)
  _find_library(${var} ${ARGN})
  set(lib "${${var}}")
  string(FIND "${lib}" "${PKGS_SYSROOT}/" at)
  if(NOT at EQUAL 0)
    return()
  elseif(lib MATCHES "/lib([^/]+)\\.(so|a|tbd|dylib)$")
    set(lib "-l${CMAKE_MATCH_1}")
  elseif(lib MATCHES "/([^/]+)\\.framework$")
    set(lib "-framework ${CMAKE_MATCH_1}")
  else()
    return()
  endif()
  get_property(type CACHE ${var} PROPERTY TYPE)
  if(type)
    set_property(CACHE ${var} PROPERTY VALUE "${lib}")
  else()
    set(${var} "${lib}" PARENT_SCOPE)
  endif()
endfunction()
