# macOS: find_library() answers with the SDK's stub (<sysroot>/usr/lib/libz.tbd,
# <sysroot>/System/Library/Frameworks/Foo.framework). Recorded in an installed *Config.cmake or .pc
# that path names this build's SDK for every dependent. The linker resolves -lz / -framework Foo
# against whatever SDK is current, so hand that back instead. Injected through
# CMAKE_PROJECT_TOP_LEVEL_INCLUDES by builder/systems/cmake.nu.
function(find_library var)
  _find_library(${var} ${ARGN})
  set(lib "${${var}}")
  if(lib MATCHES "^${CMAKE_OSX_SYSROOT}/usr/lib/lib([^/]+)\\.(tbd|dylib)$")
    set(lib "-l${CMAKE_MATCH_1}")
  elseif(lib MATCHES "^${CMAKE_OSX_SYSROOT}/System/Library/Frameworks/([^/]+)\\.framework$")
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
