# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(lvpai_ftp_client LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "lvpai_ftp_client")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Use Microsoft's CPU NuGet package, pinned to the mobile runtime version.
set(ORT_VERSION "1.28.0")
set(ORT_DIR "${CMAKE_CURRENT_BINARY_DIR}/_deps/onnxruntime-${ORT_VERSION}")
set(ORT_ARCHIVE "${ORT_DIR}.zip")
set(ORT_PACKAGE "microsoft.ml.onnxruntime/${ORT_VERSION}/microsoft.ml.onnxruntime.${ORT_VERSION}.nupkg")
set(ORT_SHA512 "d97d83d031fa744cd67dab61e88deecc8b6c3c11b1a98951b0fcf73852bb4bd4df935d0c71674a19e80d8d3f0a98e02d9129e8df24c5f5ea38de60ef9fdb1a97")
set(ONNXRUNTIME_INCLUDE_DIR "${ORT_DIR}/build/native/include")
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(ORT_NATIVE_DIR "${ORT_DIR}/runtimes/win-arm64/native")
else()
  set(ORT_NATIVE_DIR "${ORT_DIR}/runtimes/win-x64/native")
endif()
set(ONNXRUNTIME_LIBRARY "${ORT_NATIVE_DIR}/onnxruntime.lib")
if(NOT EXISTS "${ONNXRUNTIME_LIBRARY}" OR
   NOT EXISTS "${ONNXRUNTIME_INCLUDE_DIR}/onnxruntime_cxx_api.h" OR
   NOT EXISTS "${ORT_NATIVE_DIR}/onnxruntime.dll")
  file(MAKE_DIRECTORY "${ORT_DIR}")
  file(DOWNLOAD "https://api.nuget.org/v3-flatcontainer/${ORT_PACKAGE}"
    "${ORT_ARCHIVE}" EXPECTED_HASH "SHA512=${ORT_SHA512}" TLS_VERIFY ON TIMEOUT 300)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${ORT_ARCHIVE}"
    WORKING_DIRECTORY "${ORT_DIR}" RESULT_VARIABLE ORT_EXTRACT_RESULT)
  if(NOT ORT_EXTRACT_RESULT EQUAL 0 OR NOT EXISTS "${ONNXRUNTIME_LIBRARY}")
    message(FATAL_ERROR "Could not extract the ONNX Runtime CPU package")
  endif()
endif()
set(USE_SYSTEM_ONNXRUNTIME ON)

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)
if(MSVC)
  target_compile_options(flutter_onnxruntime_plugin PRIVATE /utf-8)
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
install(FILES "${ORT_NATIVE_DIR}/onnxruntime.dll"
  "${ORT_NATIVE_DIR}/onnxruntime_providers_shared.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${ORT_DIR}/LICENSE" "${ORT_DIR}/ThirdPartyNotices.txt"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/onnxruntime" COMPONENT Runtime)

# Copy the native assets provided by the hook/build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
