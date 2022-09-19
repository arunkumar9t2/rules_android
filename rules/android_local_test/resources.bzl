# Copyright 2020 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Implementation."""

load("//rules:acls.bzl", "acls")
load(
    "//rules:processing_pipeline.bzl",
    "ProviderInfo",
    "processing_pipeline",
)
load("//rules:resources.bzl", _resources = "resources")
load("//rules:utils.bzl", "compilation_mode", "get_android_toolchain", "utils")
load("//rules:attrs.bzl", _attrs = "attrs")

def _process_manifest(ctx, **_unused_sub_ctxs):
    manifest_ctx = None
    manifest_values = _resources.process_manifest_values(
        ctx,
        ctx.attr.manifest_values,
    )
    manifest_ctx = _resources.bump_min_sdk(
        ctx,
        manifest = ctx.file.manifest,
        manifest_values = ctx.attr.manifest_values,
    )

    return ProviderInfo(
        name = "manifest_ctx",
        value = manifest_ctx,
    )

def _process_resources_for_android_local_test(ctx, manifest_ctx, java_package, **unused_ctx):
    packaged_resources_ctx = _resources.package(
        ctx,
        resource_files = ctx.files.resource_files,
        assets = ctx.files.assets,
        assets_dir = ctx.attr.assets_dir,
        resource_configs = ctx.attr.resource_configuration_filters,
        densities = ctx.attr.densities,
        nocompress_extensions = ctx.attr.nocompress_extensions,
        compilation_mode = compilation_mode.get(ctx),
        shrink_resources = _attrs.tristate.no,
        manifest = manifest_ctx.processed_manifest,
        manifest_values = utils.expand_make_vars(ctx, ctx.attr.manifest_values),
        java_package = java_package,
        use_legacy_manifest_merger = False,
        should_throw_on_conflict = not acls.in_allow_resource_conflicts(str(ctx.label)),
        deps = ctx.attr.deps + ctx.attr.associates,
        aapt = get_android_toolchain(ctx).aapt2.files_to_run,
        android_jar = ctx.attr._android_sdk[AndroidSdkInfo].android_jar,
        busybox = get_android_toolchain(ctx).android_resources_busybox.files_to_run,
        host_javabase = ctx.attr._host_javabase,
    )
    return ProviderInfo(
        name = "packaged_resources_ctx",
        value = packaged_resources_ctx,
    )

PROCESSORS = dict(
    ManifestProcessor = _process_manifest,
    ResourceProcessor = _process_resources_for_android_local_test,
)
