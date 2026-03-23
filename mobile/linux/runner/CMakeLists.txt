cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Copy the Rust shared library into the Linux bundle so FRB can load it.
set(PUSHSTR_RUST_LIB_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/../../../pushstr_rust/target/debug/libpushstr_rust.so")
set(PUSHSTR_RUST_LIB_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/../../../pushstr_rust/target/release/libpushstr_rust.so")
if(CMAKE_BUILD_TYPE MATCHES "Debug")
  set(PUSHSTR_RUST_LIB_SOURCE "${PUSHSTR_RUST_LIB_DEBUG}")
else()
  set(PUSHSTR_RUST_LIB_SOURCE "${PUSHSTR_RUST_LIB_RELEASE}")
endif()
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/bundle/lib"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${PUSHSTR_RUST_LIB_SOURCE}"
    "${CMAKE_BINARY_DIR}/bundle/lib/libpushstr_rust.so"
  VERBATIM
)
