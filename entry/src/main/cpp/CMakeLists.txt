cmake_minimum_required(VERSION 3.16)
project(ohsurfing C CXX)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

file(GLOB_RECURSE CIPHER_SOURCES CONFIGURE_DEPENDS "core/src/cipher/*.c")
add_library(ohsurfing SHARED
    AuthBridge.cpp
    core/src/States.c
    core/src/DialerClient.c
    core/src/NetClient.c
    core/src/utils/PlatformAuth.c
    core/src/utils/AuthLogger.c
    ${CIPHER_SOURCES}
)
target_compile_definitions(ohsurfing PRIVATE OH_SURFING=1)
target_include_directories(ohsurfing PRIVATE core/inc core/src/cipher/algo/ios/lzma)
target_link_libraries(ohsurfing PUBLIC libace_napi.z.so)
