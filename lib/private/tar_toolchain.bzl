"Provide access to a GNU tar"

load("//lib:repo_utils.bzl", "repo_utils")

TarInfo = provider(
    doc = "Provide info for executing GNU tar",
    fields = {
        "command": "tar command we expect to be on the path, e.g. 'tar'",
    },
)

def _tar_toolchain_impl(ctx):
    command = ctx.attr.command

    # Make the $(TAR_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "TAR_BIN": command,
    })

    # default_info = DefaultInfo(
    #     files = depset([binary]),
    #     runfiles = ctx.runfiles(files = [binary]),
    # )
    tar_info = TarInfo(
        command = command,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        tar_info = tar_info,
        template_variables = template_variables,
        # default = default_info,
    )

    return [toolchain_info, template_variables]  #, default_info

tar_toolchain = rule(
    implementation = _tar_toolchain_impl,
    attrs = {
        "command": attr.string(
            doc = "a command to find on the system path",
        ),
    },
)

def _find_usable_system_tar(rctx):
    tar = rctx.which("tar.exe" if repo_utils.is_windows(rctx) else "tar")
    if not tar:
        fail("tar not found on PATH, and we don't handle this case yet")

    # Run tar --version and see if we are satisfied to use it
    tar_version = rctx.execute([tar, "--version"]).stdout.strip()
    if tar_version.find("bsdtar") >= 0 and repo_utils.is_darwin(rctx):
        # check if the user already installed gnu-tar as "gtar"
        gtar = rctx.which("gtar")
        if not gtar:
            fail("""\
ERROR resolving GNU tar:
tar is a BSD tar, we are running on MacOS
We don't know how to fetch gnu-tar from brew yet.

We should ctx.download https://formulae.brew.sh/api/formula/gnu-tar.json
parse the json to find the binary and sha for the local darwin,
and then use that in the toolchain.
""")
        gtar_version = rctx.execute([gtar, "--version"]).stdout.strip()
        if gtar_version.find("GNU tar") >= 0:
            tar = gtar
        else:
            fail("gtar isn't a GNU tar")

    # TODO: also check if it's really ancient or compiled without gzip support or something?
    # TODO: document how users could fetch a source tarball from http://ftp.gnu.org/gnu/tar/
    # and compile it themselves
    return tar

def _tar_toolchains_repo_impl(rctx):
    bin = _find_usable_system_tar(rctx)
    if not bin:
        fail("We don't know how to compile tar from sources yet, maybe the user has to supply their own toolchain?")

    # Expose a concrete toolchain which is the result of Bazel resolving the toolchain
    # for the execution or target platform.
    # Workaround for https://github.com/bazelbuild/bazel/issues/14009
    starlark_content = """# @generated by @aspect_bazel_lib//lib/private:tar_toolchain.bzl

# Forward all the providers
def _resolved_toolchain_impl(ctx):
    toolchain_info = ctx.toolchains["@aspect_bazel_lib//lib:tar_toolchain_type"]
    return [
        toolchain_info,
        # toolchain_info.default,
        toolchain_info.tar_info,
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
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the tar_register_toolchains macro
# so you don't normally need to interact with these targets.

load(":defs.bzl", "resolved_toolchain")
load("@aspect_bazel_lib//lib/private:tar_toolchain.bzl", "tar_toolchain")

# exports_files(["{bin}"])

tar_toolchain(name = "_toolchain", command = "{bin}", visibility = ["//visibility:public"])

toolchain(
    name = "tar_toolchain",
    # exec_compatible_with = {compatible_with},
    toolchain = ":_toolchain",
    toolchain_type = "@aspect_bazel_lib//lib:tar_toolchain_type",
)

resolved_toolchain(name = "resolved_toolchain", visibility = ["//visibility:public"])

""".format(bin = bin, compatible_with = "xxx")

    rctx.file("BUILD.bazel", build_content)

tar_toolchains_repo = repository_rule(
    _tar_toolchains_repo_impl,
    doc = """Creates a repository that exposes a tar_toolchain_type target.""",
    attrs = {

        # Predicates about what tar you're okay with
        # Ways to get other gnu-tar
    },
)
