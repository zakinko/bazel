load("@rules_python//python:py_runtime.bzl", "py_runtime")
load("@rules_python//python:py_runtime_pair.bzl", "py_runtime_pair")

package(default_visibility = ["//visibility:public"])

exports_files([
    "platforms_netbsd.patch",
    "rules_java_netbsd.patch",
    "rules_go_netbsd.patch",
    "zstd_jni_netbsd.patch",
])

# There is no remote JDK for NetBSD, so whichever remote JDK the build asks
# for has to resolve to the one installed on this machine.
config_setting(
    name = "remotejdk_21_setting",
    values = {"java_runtime_version": "remotejdk_21"},
)

config_setting(
    name = "jdk_21_setting",
    values = {"java_runtime_version": "21"},
)

toolchain(
    name = "local_jdk_21_runtime",
    target_settings = [":remotejdk_21_setting"],
    toolchain = "@local_jdk//:jdk",
    toolchain_type = "@bazel_tools//tools/jdk:runtime_toolchain_type",
)

toolchain(
    name = "local_jdk_21_bootstrap",
    target_settings = [":remotejdk_21_setting"],
    toolchain = "@local_jdk//:jdk",
    toolchain_type = "@bazel_tools//tools/jdk:bootstrap_runtime_toolchain_type",
)

toolchain(
    name = "local_jdk_21_runtime_v",
    target_settings = [":jdk_21_setting"],
    toolchain = "@local_jdk//:jdk",
    toolchain_type = "@bazel_tools//tools/jdk:runtime_toolchain_type",
)

toolchain(
    name = "local_jdk_21_bootstrap_v",
    target_settings = [":jdk_21_setting"],
    toolchain = "@local_jdk//:jdk",
    toolchain_type = "@bazel_tools//tools/jdk:bootstrap_runtime_toolchain_type",
)

py_runtime(
    name = "netbsd_py3_runtime",
    interpreter_path = "/usr/pkg/bin/python3.13",
    python_version = "PY3",
    stub_shebang = "#!/usr/pkg/bin/python3.13",
)

py_runtime_pair(
    name = "netbsd_py_runtime_pair",
    py3_runtime = ":netbsd_py3_runtime",
)

toolchain(
    name = "netbsd_python3_toolchain",
    toolchain = ":netbsd_py_runtime_pair",
    toolchain_type = "@rules_python//python:toolchain_type",
)
