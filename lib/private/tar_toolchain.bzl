"Provide access to a BSD tar"

BSDTAR_PLATFORMS = {
    "darwin_amd64": struct(
        compatible_with = [
            "@platforms//os:osx",
            "@platforms//cpu:x86_64",
        ],
    ),
    "darwin_arm64": struct(
        compatible_with = [
            "@platforms//os:osx",
            "@platforms//cpu:aarch64",
        ],
    ),
    "linux_amd64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "linux_arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    ),
    "windows_amd64": struct(
        release_platform = "win64",
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
    ),
}

BSDTAR_PREBUILT = {
    "darwin_amd64": (
        "https://github.com/aspect-build/bsdtar-prebuilt/releases/download/v3.7.4-3/tar_darwin_amd64",
        "e872943518f946a4a73106c1fa811c0211cb74a6e6d673f5a2ffbfaf40806ec0",
    ),
    "darwin_arm64": (
        "https://github.com/aspect-build/bsdtar-prebuilt/releases/download/v3.7.4-3/tar_darwin_arm64",
        "81d992eeefb519421dc18db63fce51f7fef7204b94e17e9b490af7699b565ff1",
    ),
    "linux_amd64": (
        "https://github.com/aspect-build/bsdtar-prebuilt/releases/download/v3.7.4-3/tar_linux_amd64",
        "9dba82030199b2660086e458fa6481cf73089ee5c47d216e647bb2a6b0fae792",
    ),
    "linux_arm64": (
        "https://github.com/aspect-build/bsdtar-prebuilt/releases/download/v3.7.4-3/tar_linux_arm64",
        "105f91ad792fce13030bd249d8f9a14fd7ceaf908e1caeb99685b0b1fac44be2",
    ),
    "windows_amd64": (
        "https://github.com/libarchive/libarchive/releases/download/v3.7.4/libarchive-v3.7.4-amd64.zip",
        "7ced6865d5e22e1dab0c3f3d65094d946ae505ec4e8db026f82c9e1c413f3c59",
    ),
}

def _bsdtar_binary_repo(rctx):
    (url, sha256) = BSDTAR_PREBUILT[rctx.attr.platform]
    if rctx.attr.platform.startswith("windows"):
        rctx.download_and_extract(
            url = url,
            type = "zip",
            sha256 = sha256,
        )
        binary = "libarchive/bin/bsdtar.exe"
    else:
        rctx.download(
            url = url,
            output = "tar",
            executable = True,
            sha256 = sha256,
        )
        binary = "tar"

    rctx.file("BUILD.bazel", """\
# @generated by @aspect_bazel_lib//lib/private:tar_toolchain.bzl

load("@aspect_bazel_lib//lib/private:tar_toolchain.bzl", "tar_toolchain")

package(default_visibility = ["//visibility:public"])

tar_toolchain(name = "bsdtar_toolchain", binary = "{}")
""".format(binary))

bsdtar_binary_repo = repository_rule(
    implementation = _bsdtar_binary_repo,
    attrs = {
        "platform": attr.string(mandatory = True, values = BSDTAR_PLATFORMS.keys()),
    },
)

TarInfo = provider(
    doc = "Provide info for executing BSD tar",
    fields = {
        "binary": "bsdtar executable",
    },
)

def _tar_toolchain_impl(ctx):
    binary = ctx.executable.binary

    # Make the $(BSDTAR_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "BSDTAR_BIN": binary.path,
    })

    default_info = DefaultInfo(
        files = depset(ctx.files.binary + ctx.files.files),
    )
    tarinfo = TarInfo(
        binary = binary,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        tarinfo = tarinfo,
        template_variables = template_variables,
        default = default_info,
    )

    return [toolchain_info, template_variables, default_info]

tar_toolchain = rule(
    implementation = _tar_toolchain_impl,
    attrs = {
        "binary": attr.label(
            doc = "a command to find on the system path",
            allow_files = True,
            executable = True,
            cfg = "exec",
        ),
        "files": attr.label_list(allow_files = True),
    },
)

def _tar_toolchains_repo_impl(rctx):
    # Expose a concrete toolchain which is the result of Bazel resolving the toolchain
    # for the execution or target platform.
    # Workaround for https://github.com/bazelbuild/bazel/issues/14009
    starlark_content = """\
# @generated by @aspect_bazel_lib//lib/private:tar_toolchain.bzl

# Forward all the providers
def _resolved_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains["@aspect_bazel_lib//lib:tar_toolchain_type"]
    return [
        toolchain_info,
        toolchain_info.default,
        toolchain_info.tarinfo,
        toolchain_info.template_variables,
    ]

# Copied from java_toolchain_alias
# https://cs.opensource.google/bazel/bazel/+/master:tools/jdk/java_toolchain_alias.bzl
resolved_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = ["@aspect_bazel_lib//lib:tar_toolchain_type"],
    incompatible_use_toolchain_transition = True,
)
"""
    rctx.file("defs.bzl", starlark_content)

    build_content = """# @generated by @aspect_bazel_lib//lib/private:tar_toolchain.bzl
load(":defs.bzl", "resolved_toolchain")
load("@local_config_platform//:constraints.bzl", "HOST_CONSTRAINTS")

resolved_toolchain(name = "resolved_toolchain", visibility = ["//visibility:public"])"""

    for [platform, meta] in BSDTAR_PLATFORMS.items():
        build_content += """
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    toolchain = "@{user_repository_name}_{platform}//:bsdtar_toolchain",
    toolchain_type = "@aspect_bazel_lib//lib:tar_toolchain_type",
)
""".format(
            platform = platform,
            user_repository_name = rctx.attr.user_repository_name,
            compatible_with = meta.compatible_with,
        )

    rctx.file("BUILD.bazel", build_content)

tar_toolchains_repo = repository_rule(
    _tar_toolchains_repo_impl,
    doc = """Creates a repository that exposes a tar_toolchain_type target.""",
    attrs = {
        "user_repository_name": attr.string(doc = "Base name for toolchains repository"),
    },
)
