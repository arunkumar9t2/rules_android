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
load("//rules:apk_packaging.bzl", _apk_packaging = "apk_packaging")
load("//rules:baseline_profiles.bzl", _baseline_profiles = "baseline_profiles")
load("//rules:common.bzl", "common")
load("//rules:data_binding.bzl", "data_binding")
load("//rules:desugar.bzl", _desugar = "desugar")
load("//rules:dex.bzl", _dex = "dex")
load("//rules:dex_desugar_aspect.bzl", _get_dex_desugar_aspect_deps = "get_aspect_deps")
load("//rules:intellij.bzl", _intellij = "intellij")
load("//rules:java.bzl", "java")
load("//rules:min_sdk_version.bzl", _min_sdk_version = "min_sdk_version")
load(
    "//rules:native_deps.bzl",
    _process_native_deps = "process",
)
load(
    "//rules:processing_pipeline.bzl",
    "ProviderInfo",
    "processing_pipeline",
)
load("//rules:proguard.bzl", "proguard")
load("//rules:providers.bzl", "StarlarkAndroidDexInfo", "StarlarkApkInfo")
load("//rules:resources.bzl", _resources = "resources")
load(
    "//rules:utils.bzl",
    "ANDROID_TOOLCHAIN_TYPE",
    "compilation_mode",
    "get_android_sdk",
    "get_android_toolchain",
    "utils",
)
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":r8.bzl", "process_r8", "process_resource_shrinking_r8")

def _base_validations_processor(ctx, **_unused_ctxs):
    if ctx.attr.min_sdk_version != 0 and not acls.in_android_binary_min_sdk_version_attribute_allowlist(str(ctx.label)):
        fail("Target %s is not allowed to set a min_sdk_version value." % str(ctx.label))

    use_r8 = acls.use_r8(str(ctx.label)) and bool(ctx.files.proguard_specs)
    return ProviderInfo(
        name = "validation_ctx",
        value = struct(
            use_r8 = use_r8,
            providers = [],
        ),
    )

def _process_manifest(ctx, **unused_ctxs):
    manifest_ctx = _resources.bump_min_sdk(
        ctx,
        manifest = ctx.file.manifest,
        manifest_values = ctx.attr.manifest_values,
    )

    return ProviderInfo(
        name = "manifest_ctx",
        value = manifest_ctx,
    )

def _process_resources(ctx, manifest_ctx, java_package, **unused_ctxs):
    resource_apks = []
    for apk in utils.collect_providers(StarlarkApkInfo, ctx.attr.resource_apks):
        resource_apks.append(apk.signed_apk)

    packaged_resources_ctx = _resources.package(
        ctx,
        assets = ctx.files.assets,
        assets_dir = ctx.attr.assets_dir,
        resource_files = ctx.files.resource_files,
        manifest = manifest_ctx.processed_manifest,
        manifest_values = manifest_ctx.processed_manifest_values,
        manifest_merge_order = ctx.attr._manifest_merge_order[BuildSettingInfo].value,
        resource_configs = ctx.attr.resource_configuration_filters,
        densities = ctx.attr.densities,
        nocompress_extensions = ctx.attr.nocompress_extensions,
        java_package = java_package,
        compilation_mode = compilation_mode.get(ctx),
        shrink_resources = ctx.attr.shrink_resources,
        use_android_resource_shrinking = ctx.fragments.android.use_android_resource_shrinking,
        use_android_resource_cycle_shrinking = ctx.fragments.android.use_android_resource_cycle_shrinking,
        use_legacy_manifest_merger = use_legacy_manifest_merger(ctx),
        should_throw_on_conflict = not acls.in_allow_resource_conflicts(str(ctx.label)),
        enable_data_binding = ctx.attr.enable_data_binding,
        enable_manifest_merging = ctx.attr._enable_manifest_merging,
        deps = utils.dedupe_split_attr(ctx.split_attr.deps),
        resource_apks = resource_apks,
        instruments = ctx.attr.instruments,
        aapt = get_android_toolchain(ctx).aapt2.files_to_run,
        android_jar = get_android_sdk(ctx).android_jar,
        legacy_merger = ctx.attr._android_manifest_merge_tool.files_to_run,
        xsltproc = ctx.attr._xsltproc_tool.files_to_run,
        instrument_xslt = ctx.file._add_g3itr_xslt,
        busybox = get_android_toolchain(ctx).android_resources_busybox.files_to_run,
        host_javabase = ctx.attr._host_javabase,
        # The AndroidApplicationResourceInfo will be added to the list of providers in finalize()
        # if R8-based resource shrinking is not performed.
        add_application_resource_info_to_providers = False,
    )
    return ProviderInfo(
        name = "packaged_resources_ctx",
        value = packaged_resources_ctx,
    )

def _validate_manifest(ctx, packaged_resources_ctx, **unused_ctxs):
    validation_outputs = []

    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        manifest_validation_output = _resources.validate_manifest(
            ctx,
            manifest = packaged_resources_ctx.processed_manifest,
            should_validate_multidex =
                ctx.attr.multidex == "native" and
                not acls.in_android_binary_multidex_native_min_sdk_allowlist(str(ctx.label)),
            min_sdk_version = ctx.attr.min_sdk_version,
            manifest_validation_tool = get_android_toolchain(ctx).manifest_validation_tool.files_to_run,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )
        if manifest_validation_output:
            validation_outputs.append(manifest_validation_output)

    return ProviderInfo(
        name = "manifest_validation_ctx",
        value = struct(
            validation_outputs = validation_outputs,
        ),
    )

def _process_native_libs(ctx, **_unusued_ctxs):
    providers = []
    native_libs_info = _process_native_deps(
        ctx,
        filename = "nativedeps",
    )
    providers.append(native_libs_info)
    return ProviderInfo(
        name = "native_libs_ctx",
        value = struct(
            native_libs_info = native_libs_info,
            providers = providers,
        ),
    )

def _process_build_stamp(_unused_ctx, **_unused_ctxs):
    return ProviderInfo(
        name = "stamp_ctx",
        value = struct(
            resource_files = [],
            deps = [],
            java_info = None,
            providers = [],
        ),
    )

def _process_proto(_unused_ctx, **_unused_ctxs):
    return ProviderInfo(
        name = "proto_ctx",
        value = struct(
            providers = [],
            class_jar = None,
            java_info = None,
        ),
    )

def _process_data_binding(ctx, java_package, packaged_resources_ctx, **_unused_ctxs):
    if ctx.attr.enable_data_binding and not acls.in_databinding_allowed(str(ctx.label)):
        fail("This target is not allowed to use databinding and enable_data_binding is True.")
    return ProviderInfo(
        name = "db_ctx",
        value = data_binding.process(
            ctx,
            defines_resources = True,
            enable_data_binding = ctx.attr.enable_data_binding,
            java_package = java_package,
            layout_info = packaged_resources_ctx.data_binding_layout_info,
            artifact_type = "APPLICATION",
            deps = utils.collect_providers(DataBindingV2Info, utils.dedupe_split_attr(ctx.split_attr.deps)),
            data_binding_exec = get_android_toolchain(ctx).data_binding_exec.files_to_run,
            data_binding_annotation_processor =
                get_android_toolchain(ctx).data_binding_annotation_processor[JavaPluginInfo],
            data_binding_annotation_template =
                utils.only(get_android_toolchain(ctx).data_binding_annotation_template.files.to_list()),
        ),
    )

def _process_jvm(ctx, db_ctx, packaged_resources_ctx, proto_ctx, stamp_ctx, **_unused_ctxs):
    native_name = ctx.label.name.removesuffix(common.PACKAGED_RESOURCES_SUFFIX)
    java_info = java.compile_android(
        ctx,
        # Use the same format as the class jar from native android_binary.
        # Some macros expect the class jar to be named like this.
        ctx.actions.declare_file("%s/lib%s.jar" % (ctx.label.name, native_name)),
        ctx.actions.declare_file(ctx.label.name + "-src.jar"),
        srcs = ctx.files.srcs + db_ctx.java_srcs,
        javac_opts = ctx.attr.javacopts + db_ctx.javac_opts,
        r_java = packaged_resources_ctx.r_java,
        enable_deps_without_srcs = True,
        deps = utils.collect_providers(JavaInfo, utils.dedupe_split_attr(ctx.split_attr.deps) + stamp_ctx.deps),
        plugins =
            utils.collect_providers(JavaPluginInfo, ctx.attr.plugins) +
            db_ctx.java_plugins,
        annotation_processor_additional_outputs =
            db_ctx.java_annotation_processor_additional_outputs,
        annotation_processor_additional_inputs =
            db_ctx.java_annotation_processor_additional_inputs,
        strict_deps = "DEFAULT",
        java_toolchain = common.get_java_toolchain(ctx),
    )
    java_info = java_common.add_constraints(
        java_info,
        constraints = ["android"],
    )

    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        java_infos = [java_info, packaged_resources_ctx.r_java]
        if stamp_ctx.java_info:
            java_infos.append(stamp_ctx.java_info)
        if proto_ctx.java_info:
            java_infos.append(proto_ctx.java_info)
        java_info = java_common.merge(java_infos)

    return ProviderInfo(
        name = "jvm_ctx",
        value = struct(
            java_info = java_info,
            providers = [java_info],
        ),
    )

def _process_build_info(_unused_ctx, **unused_ctxs):
    return ProviderInfo(
        name = "build_info_ctx",
        value = struct(
            deploy_manifest_lines = [],
            providers = [],
        ),
    )

def _process_dex(ctx, validation_ctx, packaged_resources_ctx, deploy_ctx, bp_ctx, optimize_ctx, **_unused_ctxs):
    if validation_ctx.use_r8:
        return ProviderInfo(
            name = "dex_ctx",
            value = struct(providers = []),
        )

    providers = []
    final_proguard_output_map = None
    postprocessing_output_map = None
    deploy_jar = deploy_ctx.deploy_jar
    is_binary_optimized = len(ctx.attr.proguard_specs) > 0
    main_dex_list = ctx.file.main_dex_list
    multidex = ctx.attr.multidex
    optimizing_dexer = ctx.attr._optimizing_dexer
    java8_legacy_dex_map = None
    proguarded_jar = optimize_ctx.proguard_output.output_jar if is_binary_optimized else None
    proguard_output_map = optimize_ctx.proguard_output.mapping if is_binary_optimized else None
    binary_jar = proguarded_jar if proguarded_jar else deploy_jar
    binary_runtime_jars = deploy_ctx.binary_runtime_jars
    forbidden_dexopts = ctx.fragments.android.get_target_dexopts_that_prevent_incremental_dexing

    if (main_dex_list and multidex != "manual_main_dex") or \
       (not main_dex_list and multidex == "manual_main_dex"):
        fail("Both \"main_dex_list\" and \"multidex='manual_main_dex'\" must be specified.")

    #  Multidex mode: generate classes.dex.zip, where the zip contains
    #  [classes.dex, classes2.dex, ... classesN.dex]
    if ctx.attr.multidex == "legacy":
        main_dex_list = _dex.generate_main_dex_list(
            ctx,
            jar = binary_jar,
            android_jar = get_android_sdk(ctx).android_jar,
            desugar_java8_libs = ctx.fragments.android.desugar_java8_libs,
            legacy_apis = ctx.files._desugared_java8_legacy_apis,
            main_dex_classes = get_android_sdk(ctx).main_dex_classes,
            main_dex_list_opts = ctx.attr.main_dex_list_opts,
            main_dex_proguard_spec = packaged_resources_ctx.main_dex_proguard_config,
            proguard_specs = list(ctx.files.main_dex_proguard_specs),
            shrinked_android_jar = get_android_sdk(ctx).shrinked_android_jar,
            main_dex_list_creator = get_android_sdk(ctx).main_dex_list_creator,
            legacy_main_dex_list_generator =
                ctx.attr._legacy_main_dex_list_generator.files_to_run if ctx.attr._legacy_main_dex_list_generator else get_android_sdk(ctx).legacy_main_dex_list_generator,
            proguard_tool = get_android_sdk(ctx).proguard,
        )
    elif ctx.attr.multidex == "manual_main_dex":
        main_dex_list = _dex.transform_dex_list_through_proguard_map(
            ctx,
            proguard_output_map = proguard_output_map,
            main_dex_list = main_dex_list,
            dex_list_obfuscator = get_android_toolchain(ctx).dex_list_obfuscator.files_to_run,
        )

    should_optimize_dex = optimizing_dexer and proguarded_jar and not acls.in_disable_optimizing_dexer(str(ctx.label))
    if proguard_output_map:
        enable_postprocess_dexing = _dex.enable_postprocess_dexing(ctx)

        # Proguard map from preprocessing will be merged with Proguard map for desugared
        # library.
        if (should_optimize_dex or enable_postprocess_dexing) and ctx.fragments.android.desugar_java8_libs:
            postprocessing_output_map = _dex.get_dx_artifact(ctx, "_proguard_output_for_desugared_library.map")
            final_proguard_output_map = _dex.get_dx_artifact(ctx, "_proguard.map")
        elif (should_optimize_dex or enable_postprocess_dexing):
            # No desugared library, Proguard map from postprocessing is the final Proguard map.
            postprocessing_output_map = _dex.get_dx_artifact(ctx, "_proguard.map")
            final_proguard_output_map = postprocessing_output_map
        elif ctx.fragments.android.desugar_java8_libs:
            # No postprocessing, Proguard map from merging with the desugared library map is the
            # final Proguard map.
            postprocessing_output_map = proguard_output_map
            final_proguard_output_map = _dex.get_dx_artifact(ctx, "_proguard.map")

        else:
            # No postprocessing, no desugared library, the final Proguard map is the Proguard map
            # from shrinking
            postprocessing_output_map = proguard_output_map
            final_proguard_output_map = proguard_output_map

    incremental_dexing = _dex.get_effective_incremental_dexing(
        force_incremental_dexing = ctx.attr.incremental_dexing,
        has_forbidden_dexopts = len([d for d in ctx.attr.dexopts if d in forbidden_dexopts]) > 0,
        is_binary_optimized = is_binary_optimized,
        incremental_dexing_after_proguard_by_default = ctx.fragments.android.incremental_dexing_after_proguard_by_default,
        incremental_dexing_shards_after_proguard = ctx.fragments.android.incremental_dexing_shards_after_proguard,
        use_incremental_dexing = ctx.fragments.android.use_incremental_dexing,
    )

    classes_dex_zip = _dex.get_dx_artifact(ctx, "classes.dex.zip")
    if incremental_dexing or should_optimize_dex:
        _dex.process_incremental_dexing(
            ctx,
            output = classes_dex_zip,
            deps = _get_dex_desugar_aspect_deps(ctx),
            dexopts = ctx.attr.dexopts,
            native_multidex = multidex == "native",
            runtime_jars = binary_runtime_jars,
            main_dex_list = main_dex_list,
            min_sdk_version = _min_sdk_version.clamp(ctx.attr.min_sdk_version),
            proguarded_jar = proguarded_jar,
            library_jar = optimize_ctx.proguard_output.library_jar,
            proguard_output_map = proguard_output_map,
            postprocessing_output_map = postprocessing_output_map,
            startup_profile = optimize_ctx.proguard_output.startup_profile_rewritten,
            inclusion_filter_jar = binary_jar if is_instrumentation(ctx) and not is_binary_optimized else None,
            transitive_runtime_jars_for_archive = deploy_ctx.transitive_runtime_jars_for_archive,
            desugar_dict = deploy_ctx.desugar_dict,
            shuffle_jars = get_android_toolchain(ctx).shuffle_jars.files_to_run,
            dexbuilder = get_android_toolchain(ctx).dexbuilder.files_to_run,
            dexbuilder_after_proguard = get_android_toolchain(ctx).dexbuilder_after_proguard.files_to_run,
            dexmerger = get_android_toolchain(ctx).dexmerger.files_to_run,
            dexsharder = get_android_toolchain(ctx).dexsharder.files_to_run,
            optimizing_dexer = optimizing_dexer.files_to_run if optimizing_dexer else None,
            min_sdk_config = packaged_resources_ctx.resource_minsdk_proguard_config,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )
    else:
        _dex.process_monolithic_dexing(
            ctx,
            output = classes_dex_zip,
            input = binary_jar,
            dexopts = ctx.attr.dexopts,
            min_sdk_version = ctx.attr.min_sdk_version,
            main_dex_list = main_dex_list,
            dexbuilder = get_android_sdk(ctx).dx,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )

    # TODO(b/261110876): Remove dex postprocessing once Optimizing dexing is enabled by default
    if _dex.enable_postprocess_dexing(ctx):
        rexed_dex_zip = ctx.actions.declare_file(ctx.label.name + "/_rex/rexed_dexes.zip")

        # TODO(zhaoqxu): Populate final_rex_package_map to the Native rule if needed.
        _final_rex_package_map = _dex.postprocess_dexing(
            ctx,
            rexed_dex_zip = rexed_dex_zip,
            classes_dex_zip = classes_dex_zip,
            proguard_map = proguard_output_map,
            postprocessing_output_map = postprocessing_output_map,
            main_dex_list = main_dex_list,
            multidex = ctx.attr.multidex,
            rexopts = getattr(ctx.attr, "rexopts", []),
            rex_wrapper = get_android_toolchain(ctx).rex_wrapper.files_to_run,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )
        classes_dex_zip = rexed_dex_zip

    if ctx.fragments.android.desugar_java8_libs and classes_dex_zip.extension == "zip":
        final_classes_dex_zip = _dex.get_dx_artifact(ctx, "final_classes_dex.zip")

        java8_legacy_dex, java8_legacy_dex_map = _dex.get_java8_legacy_dex_and_map(
            ctx,
            android_jar = get_android_sdk(ctx).android_jar,
            binary_jar = binary_jar,
            build_customized_files = is_binary_optimized,
            min_sdk_version = _min_sdk_version.clamp(ctx.attr.min_sdk_version),
        )

        if final_proguard_output_map:
            proguard.merge_proguard_maps(
                ctx,
                output = final_proguard_output_map,
                inputs = [java8_legacy_dex_map, postprocessing_output_map],
                proguard_maps_merger = get_android_toolchain(ctx).proguard_maps_merger.files_to_run,
                toolchain_type = ANDROID_TOOLCHAIN_TYPE,
            )

        _dex.append_java8_legacy_dex(
            ctx,
            output = final_classes_dex_zip,
            input = classes_dex_zip,
            java8_legacy_dex = java8_legacy_dex,
            dex_zips_merger = get_android_toolchain(ctx).dex_zips_merger.files_to_run,
        )
    else:
        final_classes_dex_zip = classes_dex_zip
        final_proguard_output_map = postprocessing_output_map if postprocessing_output_map else proguard_output_map

    dex_info = AndroidDexInfo(
        deploy_jar = deploy_jar,
        filtered_deploy_jar = deploy_ctx.filtered_deploy_jar,
        final_classes_dex_zip = final_classes_dex_zip,
        final_proguard_output_map = final_proguard_output_map,
        java_resource_jar = binary_jar if ctx.fragments.android.get_java_resources_from_optimized_jar else deploy_jar,
    )
    providers.append(dex_info)
    providers.append(AndroidPreDexJarInfo(binary_jar))

    if postprocessing_output_map:
        providers.append(ProguardMappingInfo(postprocessing_output_map))

    return ProviderInfo(
        name = "dex_ctx",
        value = struct(
            dex_info = dex_info,
            java8_legacy_dex_map = java8_legacy_dex_map,
            providers = providers,
        ),
    )

def _process_deploy_jar(ctx, validation_ctx, stamp_ctx, packaged_resources_ctx, jvm_ctx, build_info_ctx, proto_ctx, **_unused_ctxs):
    if validation_ctx.use_r8:
        return ProviderInfo(
            name = "deploy_ctx",
            value = struct(providers = []),
        )

    filtered_deploy_jar, desugar_dict = None, {}
    transitive_runtime_jars_for_archive = []
    binary_runtime_jars = []
    java_toolchain = common.get_java_toolchain(ctx)

    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        java_info = jvm_ctx.java_info
    else:
        java_info = java_common.merge([jvm_ctx.java_info, stamp_ctx.java_info]) if stamp_ctx.java_info else jvm_ctx.java_info
        binary_runtime_jars.append(packaged_resources_ctx.class_jar)
        if proto_ctx.class_jar:
            binary_runtime_jars.append(proto_ctx.class_jar)
    binary_runtime_jars += java_info.runtime_output_jars

    if ctx.configuration.coverage_enabled and hasattr(ctx.attr, "_jacoco_runtime"):
        # In offline instrumentation mode, we add the Jacoco runtime to the classpath.
        binary_runtime_jars.extend(ctx.attr._jacoco_runtime[DefaultInfo].files.to_list())

    info = _dex.merge_infos(utils.collect_providers(StarlarkAndroidDexInfo, _get_dex_desugar_aspect_deps(ctx)))
    incremental_dexopts = _dex.filter_dexopts(ctx.attr.dexopts, ctx.fragments.android.get_dexopts_supported_in_incremental_dexing)
    dex_archives = info.dex_archives_dict.get("".join(incremental_dexopts), depset()).to_list()
    if ctx.fragments.android.desugar_java8:
        desugared_jars = []
        desugar_dict = {d.jar: d.desugared_jar for d in dex_archives if d.desugared_jar}

        for jar in binary_runtime_jars:
            desugared_jar = ctx.actions.declare_file(ctx.label.name + "/" + jar.basename + "_migrated_desugared.jar")
            _desugar.desugar(
                ctx,
                input = jar,
                output = desugared_jar,
                classpath = java_info.transitive_compile_time_jars,
                bootclasspath = java_toolchain[java_common.JavaToolchainInfo].bootclasspath.to_list(),
                min_sdk_version = _min_sdk_version.clamp(ctx.attr.min_sdk_version),
                desugar_exec = get_android_toolchain(ctx).desugar.files_to_run,
                toolchain_type = ANDROID_TOOLCHAIN_TYPE,
            )
            desugared_jars.append(desugared_jar)
            desugar_dict[jar] = desugared_jar

        # Remove the library resource JARs from the binary's runtime classpath.
        # Resource classes from android_library dependencies are replaced by the binary's resource
        # class. We remove them only at the top level so that resources included by a library
        # that is a dependency of a java_library are still included, since these resources are
        # propagated via android-specific providers and won't show up when we collect the library
        # resource JARs.
        # TODO(b/69552500): Instead, handle this properly so R JARs aren't put on the classpath
        # for both binaries and libraries.
        library_r_jar_dict = {jar: True for jar in _get_library_r_jars(ctx.attr.deps)}
        transitive_runtime_jars_for_archive = [jar for jar in java_info.transitive_runtime_jars.to_list() if jar not in library_r_jar_dict]
        for jar in transitive_runtime_jars_for_archive:
            desugared_jars.append(desugar_dict.get(jar, jar))

        runtime_jars = depset(desugared_jars)
    else:
        runtime_jars = depset(binary_runtime_jars, transitive = [java_info.transitive_runtime_jars])

    output = ctx.actions.declare_file(ctx.label.name + "_migrated_deploy.jar")
    deploy_jar = java.create_deploy_jar(
        ctx,
        output = output,
        runtime_jars = runtime_jars,
        java_toolchain = java_toolchain,
        build_target = ctx.label.name,
        deploy_manifest_lines = build_info_ctx.deploy_manifest_lines,
        check_desugar_deps = ctx.fragments.android.check_desugar_deps,
    )

    if is_instrumentation(ctx):
        filtered_deploy_jar = ctx.actions.declare_file(ctx.label.name + "_migrated_filtered.jar")
        filter_jar = ctx.attr.instruments[AndroidPreDexJarInfo].pre_dex_jar
        common.filter_zip_exclude(
            ctx,
            output = filtered_deploy_jar,
            input = deploy_jar,
            filter_zips = [filter_jar],
            filter_types = [".class"],
            # These files are generated by databinding in both the target and the instrumentation
            # app with different contents. We want to keep the one from the target app.
            filters = ["/BR\\.class$", "/databinding/[^/]+Binding\\.class$"],
        )
        deploy_jar = filtered_deploy_jar

    one_version_enforcement_output = None
    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        # TODO(b/269498486): Switch this action to a validation action and add the output to validation_outputs.
        one_version_enforcement_output = java.check_one_version(
            ctx,
            inputs = runtime_jars,
            java_toolchain = java_toolchain,
            one_version_enforcement_level = ctx.fragments.java.one_version_enforcement_level,
            is_test_binary = _is_test_binary(ctx),
        )

    return ProviderInfo(
        name = "deploy_ctx",
        value = struct(
            binary_runtime_jars = binary_runtime_jars,
            transitive_runtime_jars_for_archive = transitive_runtime_jars_for_archive,
            deploy_jar = deploy_jar,
            desugar_dict = desugar_dict,
            filtered_deploy_jar = filtered_deploy_jar,
            one_version_enforcement_output = one_version_enforcement_output,
            providers = [],
        ),
    )

def use_legacy_manifest_merger(ctx):
    """Whether legacy manifest merging is enabled.

    Args:
      ctx: The context.

    Returns:
      Boolean indicating whether legacy manifest merging is enabled.
    """
    manifest_merger = ctx.attr.manifest_merger
    android_manifest_merger = ctx.fragments.android.manifest_merger

    if android_manifest_merger == "force_android":
        return False
    if manifest_merger == "auto":
        manifest_merger = android_manifest_merger

    return manifest_merger == "legacy"

def finalize(
        ctx,
        providers,
        validation_outputs,
        packaged_resources_ctx,
        apk_packaging_ctx,
        resource_shrinking_r8_ctx,
        **_unused_ctxs):
    """Final step of the android_binary_internal processor pipeline.

    Args:
      ctx: The context.
      providers: The list of providers for the android_binary_internal rule.
      validation_outputs: Validation outputs for the rule.
      packaged_resources_ctx: The packaged resources from the resource processing step.
      apk_packaging_ctx: The context from the APK packaging step.
      resource_shrinking_r8_ctx: The context from the R8 resource shrinking step.
      **_unused_ctxs: Other contexts.

    Returns:
      The list of providers the android_binary_internal rule should return.
    """
    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        files = []

        # TODO(zhaoqxu): Add other default outputs from proguard, resource shrinking, dex, etc.
        if apk_packaging_ctx.v4_signature_file:
            files.append(apk_packaging_ctx.v4_signature_file)

        providers.extend(
            [
                DefaultInfo(
                    files = depset(files),
                ),
                OutputGroupInfo(
                    android_deploy_info = [
                        apk_packaging_ctx.deploy_info,
                        packaged_resources_ctx.processed_manifest,
                    ],
                    _validation = depset(validation_outputs),
                ),
            ],
        )

        if is_instrumentation(ctx):
            providers.append(
                AndroidInstrumentationInfo(target = ctx.attr.instruments[ApkInfo]),
            )

    else:
        providers.append(
            OutputGroupInfo(
                _validation = depset(validation_outputs),
            ),
        )

    # Add the AndroidApplicationResourceInfo provider from resource shrinking if it was performed.
    # TODO(ahumesky): This can be cleaned up after the rules are fully migrated to Starlark.
    # Packaging will be the final step in the pipeline, and that step can be responsible for picking
    # between the two different contexts. Then this finalize can return back to its "simple" form.
    if resource_shrinking_r8_ctx.android_application_resource_info_with_shrunk_resource_apk:
        providers.append(
            resource_shrinking_r8_ctx.android_application_resource_info_with_shrunk_resource_apk,
        )
    else:
        providers.append(packaged_resources_ctx.android_application_resource)

    return providers

def _get_library_r_jars(deps):
    transitive_resource_jars = []
    for dep in utils.collect_providers(AndroidLibraryResourceClassJarProvider, deps):
        transitive_resource_jars += dep.jars.to_list()
    return transitive_resource_jars

def _is_test_binary(ctx):
    """Whether this android_binary target is a test binary.

    Args:
      ctx: The context.

    Returns:
      Boolean indicating whether the target is a test target.
    """
    return ctx.attr.testonly or is_instrumentation(ctx) or str(ctx.label).find("/javatests/") >= 0

def is_instrumentation(ctx):
    """Whether this android_binary target is an instrumentation binary.

    Args:
      ctx: The context.

    Returns:
      Boolean indicating whether the target is an instrumentation target.

    """
    return bool(ctx.attr.instruments)

def _process_baseline_profiles(ctx, validation_ctx, deploy_ctx, **_unused_ctxs):
    baseline_profile_output = None
    if ctx.attr.generate_art_profile and not validation_ctx.use_r8:
        enable_optimizer_integration = acls.in_baseline_profiles_optimizer_integration(str(ctx.label))
        has_proguard_specs = bool(ctx.files.proguard_specs)

        if ctx.files.startup_profiles and not enable_optimizer_integration:
            fail("Target %s is not allowed to set startup_profiles." % str(ctx.label))

        # Include startup profiles if the optimizer is disabled since profiles won't be merged
        # in the optimizer.
        transitive_profiles = depset(
            ctx.files.startup_profiles if enable_optimizer_integration and not has_proguard_specs else [],
            transitive = [
                profile_provider.files
                for profile_provider in utils.collect_providers(
                    BaselineProfileProvider,
                    ctx.attr.deps,
                )
            ],
        )
        baseline_profile_output = _baseline_profiles.process(
            ctx,
            transitive_profiles = transitive_profiles,
            startup_profiles = ctx.files.startup_profiles,
            deploy_jar = deploy_ctx.deploy_jar,
            has_proguard_specs = has_proguard_specs,
            enable_optimizer_integration = enable_optimizer_integration,
            merge_tool = get_android_toolchain(ctx).merge_baseline_profiles_tool.files_to_run,
            profgen = get_android_toolchain(ctx).profgen.files_to_run,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )
    return ProviderInfo(
        name = "bp_ctx",
        value = struct(
            baseline_profile_output = baseline_profile_output,
        ),
    )

def _process_art_profile(ctx, validation_ctx, bp_ctx, dex_ctx, optimize_ctx, **_unused_ctxs):
    providers = []
    art_profile_zip = None
    if ctx.attr.generate_art_profile and not validation_ctx.use_r8:
        merged_baseline_profile = bp_ctx.baseline_profile_output.baseline_profile
        merged_baseline_profile_rewritten = \
            optimize_ctx.proguard_output.baseline_profile_rewritten if optimize_ctx.proguard_output else None
        proguard_output_map = None
        if dex_ctx.dex_info:
            proguard_output_map = dex_ctx.dex_info.final_proguard_output_map

        if acls.in_baseline_profiles_optimizer_integration(str(ctx.label)):
            # Minified symbols are emitted when rewriting, so only use map for symbols which
            # weren't passed to bytecode optimizer (if it exists).
            proguard_output_map = dex_ctx.java8_legacy_dex_map

            # At this point, either baseline profile here also contains startup-profiles, if any.
            if merged_baseline_profile_rewritten:
                merged_baseline_profile = merged_baseline_profile_rewritten
        if merged_baseline_profile:
            art_profile_zip = _baseline_profiles.process_art_profile(
                ctx,
                final_classes_dex = dex_ctx.dex_info.final_classes_dex_zip,
                merged_profile = merged_baseline_profile,
                proguard_output_map = proguard_output_map,
                profgen = get_android_toolchain(ctx).profgen.files_to_run,
                zipper = get_android_toolchain(ctx).zipper.files_to_run,
                toolchain_type = ANDROID_TOOLCHAIN_TYPE,
            )
            providers.append(
                BaselineProfileProvider(
                    # Unnecessary to pass the transitive profiles to native rule
                    depset(),
                    art_profile_zip,
                ),
            )
    return ProviderInfo(
        name = "ap_ctx",
        value = struct(
            art_profile_zip = art_profile_zip,
            providers = providers,
        ),
    )

def _process_optimize(ctx, validation_ctx, deploy_ctx, packaged_resources_ctx, bp_ctx, **_unused_ctxs):
    if validation_ctx.use_r8:
        proguard_output_jar = ctx.actions.declare_file(ctx.label.name + "_migrated_proguard.jar")
        return ProviderInfo(
            name = "optimize_ctx",
            value = struct(
                proguard_output = proguard.create_empty_proguard_output(ctx, proguard_output_jar),
                shrunk_resource_output = None,
                providers = [],
            ),
        )

    # Validate attributes and lockdown lists
    if ctx.file.proguard_apply_mapping and not acls.in_allow_proguard_apply_mapping(str(ctx.label)):
        fail("proguard_apply_mapping is not supported")
    if ctx.file.proguard_apply_mapping and not ctx.files.proguard_specs:
        fail("proguard_apply_mapping can only be used when proguard_specs is set")

    proguard_specs = proguard.get_proguard_specs(
        ctx,
        packaged_resources_ctx.resource_proguard_config,
        proguard_specs_for_manifest = [packaged_resources_ctx.resource_minsdk_proguard_config] if packaged_resources_ctx.resource_minsdk_proguard_config else [],
    )
    has_proguard_specs = bool(proguard_specs)

    enable_resource_shrinking = _resources.is_resource_shrinking_enabled(
        ctx.attr.shrink_resources,
        ctx.fragments.android.use_android_resource_shrinking,
        has_proguard_specs,
    )
    proguard_output_map = None
    generate_proguard_map = (
        ctx.attr.proguard_generate_mapping or enable_resource_shrinking
    )
    desugar_java8_libs_generates_map = ctx.fragments.android.desugar_java8
    optimizing_dexing = bool(ctx.attr._optimizing_dexer) and not acls.in_disable_optimizing_dexer(str(ctx.label))
    enable_postprocess_dexing = _dex.enable_postprocess_dexing(ctx)

    if generate_proguard_map:
        # Determine the output of the Proguard map from shrinking the app. This depends on the
        # additional steps which can process the map before the final Proguard map artifact is
        # generated.
        if not has_proguard_specs and not enable_postprocess_dexing:
            # When no shrinking happens a generating rule for the output map artifact is still needed.
            proguard_output_map = proguard.get_proguard_output_map(ctx)
        elif optimizing_dexing:
            proguard_output_map = proguard.get_proguard_temp_artifact(ctx, "pre_dexing.map")
        elif enable_postprocess_dexing:
            proguard_output_map = proguard.get_proguard_temp_artifact(ctx, "proguard_output_for_rex.map")
        elif desugar_java8_libs_generates_map:
            # Proguard map from shrinking will be merged with desugared library proguard map.
            proguard_output_map = _dex.get_dx_artifact(ctx, "_proguard_output_for_desugared_library.map")
        else:
            # Proguard map from shrinking is the final output.
            proguard_output_map = proguard.get_proguard_output_map(ctx)

    proguard_output_jar = ctx.actions.declare_file(ctx.label.name + "_migrated_proguard.jar")
    proguard_output_config = ctx.actions.declare_file(ctx.label.name + "_migrated_proguard.config")
    proguard_seeds = ctx.actions.declare_file(ctx.label.name + "_migrated_proguard.seeds")
    proguard_usage = ctx.actions.declare_file(ctx.label.name + "_migrated_proguard.usage")

    startup_profile = None
    baseline_profile = None
    if acls.in_baseline_profiles_optimizer_integration(str(ctx.label)) and bp_ctx.baseline_profile_output:
        startup_profile = bp_ctx.baseline_profile_output.startup_profile
        baseline_profile = bp_ctx.baseline_profile_output.baseline_profile

    enable_rewrite_resources_through_optimizer = enable_resource_shrinking and ctx.attr._rewrite_resources_through_optimizer

    proguard_output = proguard.apply_proguard(
        ctx,
        input_jar = deploy_ctx.deploy_jar,
        proguard_specs = proguard_specs,
        proguard_optimization_passes = getattr(ctx.attr, "proguard_optimization_passes", None),
        proguard_output_jar = proguard_output_jar,
        proguard_output_config = proguard_output_config,
        proguard_mapping = ctx.file.proguard_apply_mapping,
        proguard_output_map = proguard_output_map,
        proguard_seeds = proguard_seeds,
        proguard_usage = proguard_usage,
        startup_profile = startup_profile,
        baseline_profile = baseline_profile,
        resource_files = packaged_resources_ctx.validation_result if enable_rewrite_resources_through_optimizer else None,
        proguard_tool = get_android_sdk(ctx).proguard,
    )

    shrunk_resource_output = None
    if enable_resource_shrinking:
        shrunk_resource_output = _resources.shrink(
            ctx,
            resources_zip = proguard_output.resource_files_rewritten if enable_rewrite_resources_through_optimizer else packaged_resources_ctx.validation_result,
            aapt = get_android_toolchain(ctx).aapt2.files_to_run,
            android_jar = get_android_sdk(ctx).android_jar,
            r_txt = packaged_resources_ctx.r_txt,
            shrunk_jar = proguard_output_jar,
            proguard_mapping = proguard_output_map,
            busybox = get_android_toolchain(ctx).android_resources_busybox.files_to_run,
            host_javabase = common.get_host_javabase(ctx),
        )

    optimized_resource_output = _resources.optimize(
        ctx,
        resources_apk = shrunk_resource_output.resources_apk if enable_resource_shrinking else packaged_resources_ctx.resources_apk,
        resource_optimization_config = shrunk_resource_output.optimization_config if enable_resource_shrinking else None,
        is_resource_shrunk = enable_resource_shrinking,
        aapt = get_android_toolchain(ctx).aapt2.files_to_run,
        busybox = get_android_toolchain(ctx).android_resources_busybox.files_to_run,
        host_javabase = common.get_host_javabase(ctx),
    )

    providers = []
    providers.append(
        AndroidOptimizationInfo(
            optimized_jar = proguard_output.output_jar,
            mapping = proguard_output.mapping,
            seeds = proguard_output.seeds,
            library_jar = proguard_output.library_jar,
            config = proguard_output.config,
            usage = proguard_output.usage,
            proto_mapping = proguard_output.proto_mapping,
            rewritten_startup_profile = proguard_output.startup_profile_rewritten,
            rewriten_merged_baseline_profile = proguard_output.baseline_profile_rewritten,
            optimized_resource_apk = optimized_resource_output.resources_apk,
            shrunk_resource_apk = shrunk_resource_output.resources_apk if shrunk_resource_output else None,
            shrunk_resource_zip = shrunk_resource_output.resources_zip if shrunk_resource_output else None,
            resource_shrinker_log = shrunk_resource_output.shrinker_log if shrunk_resource_output else None,
            resource_optimization_config = shrunk_resource_output.optimization_config if shrunk_resource_output else None,
            resource_path_shortening_map = optimized_resource_output.path_shortening_map,
        ),
    )

    return ProviderInfo(
        name = "optimize_ctx",
        value = struct(
            proguard_output = proguard_output,
            shrunk_resource_output = shrunk_resource_output,
            providers = providers,
        ),
    )

def _process_apk_packaging(ctx, packaged_resources_ctx, native_libs_ctx, dex_ctx, ap_ctx, optimize_ctx, r8_ctx, resource_shrinking_r8_ctx, **_unused_ctxs):
    apk_packaging_ctx = struct()
    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        signing_keys = []
        if ctx.files.debug_signing_keys:
            signing_keys.extend(ctx.files.debug_signing_keys)
        elif ctx.file.debug_key:
            signing_keys.append(ctx.file.debug_key)

        use_r8 = acls.use_r8(str(ctx.label)) and ctx.files.proguard_specs
        if getattr(r8_ctx, "dex_info", None) and getattr(dex_ctx, "dex_info", None):
            fail("Either R8 or Dex should be used, but not both!")
        dex_info = r8_ctx.dex_info if use_r8 else dex_ctx.dex_info

        r8_shrunk_resources_output = None
        if use_r8:
            r8_shrunk_resources_output = resource_shrinking_r8_ctx.android_application_resource_info_with_shrunk_resource_apk
        if optimize_ctx.shrunk_resource_output and r8_shrunk_resources_output:
            fail("Either R8 Resource Shrinking or Proguard Resource Shrinking should be used, but not both!")

        if optimize_ctx.shrunk_resource_output:
            resources_apk = optimize_ctx.shrunk_resource_output.resources_apk
            merged_manifest = packaged_resources_ctx.processed_manifest
        elif r8_shrunk_resources_output:
            resources_apk = r8_shrunk_resources_output.resource_apk
            merged_manifest = r8_shrunk_resources_output.manifest
        else:
            resources_apk = packaged_resources_ctx.resources_apk
            merged_manifest = packaged_resources_ctx.processed_manifest

        unsigned_apk = ctx.actions.declare_file(ctx.label.name + "_unsigned.apk")
        signed_apk = ctx.actions.declare_file(ctx.label.name + ".apk")

        apk_packaging_ctx = _apk_packaging.process(
            ctx,
            unsigned_apk = unsigned_apk,
            signed_apk = signed_apk,
            resources_apk = resources_apk,
            final_classes_dex_zip = dex_info.final_classes_dex_zip,
            deploy_jar = dex_info.deploy_jar,
            native_libs = native_libs_ctx.native_libs_info.native_libs,
            native_libs_aars = native_libs_ctx.native_libs_info.transitive_native_libs,
            native_libs_name = native_libs_ctx.native_libs_info.native_libs_name,
            coverage_metadata = dex_info.deploy_jar if ctx.configuration.coverage_enabled else None,
            merged_manifest = merged_manifest,
            art_profile_zip = ap_ctx.art_profile_zip,
            java_resources_zip = dex_info.java_resource_jar,
            compress_java_resources = ctx.fragments.android.compress_java_resources,
            nocompress_extensions = ctx.attr.nocompress_extensions,
            output_jar_creator = "bazel",
            signing_keys = signing_keys,
            signing_lineage = ctx.file.debug_signing_lineage_file,
            signing_key_rotation_min_sdk = ctx.attr.key_rotation_min_sdk,
            deterministic_signing = False,
            java_toolchain = common.get_java_toolchain(ctx),
            resource_extractor = get_android_toolchain(ctx).resource_extractor.files_to_run,
            deploy_info_writer = get_android_toolchain(ctx).deploy_info_writer.files_to_run,
            zip_aligner = get_android_sdk(ctx).zip_align,
            apk_signer = get_android_sdk(ctx).apk_signer,
            toolchain_type = ANDROID_TOOLCHAIN_TYPE,
        )
    return ProviderInfo(
        name = "apk_packaging_ctx",
        value = apk_packaging_ctx,
    )

def _process_idl(ctx, **_unused_ctxs):
    if not acls.in_android_binary_starlark_rollout(str(ctx.label)):
        return ProviderInfo(name = "idl_ctx", value = struct())

    deps = utils.collect_providers(AndroidIdlInfo, ctx.attr.deps)

    android_idl_info = AndroidIdlInfo(
        depset(
            transitive = [dep.transitive_idl_import_roots for dep in deps],
            order = "preorder",
        ),
        depset(
            transitive = [dep.transitive_idl_imports for dep in deps],
            order = "preorder",
        ),
        # TODO(b/146216105): Delete this field once AndroidIdlInfo is Starlarkified.
        depset(),
        depset(
            transitive = [dep.transitive_idl_preprocessed for dep in deps],
            order = "preorder",
        ),
    )

    return ProviderInfo(
        name = "idl_ctx",
        value = struct(
            android_idl_info = android_idl_info,
            providers = [android_idl_info],
        ),
    )

def _process_intellij(
        ctx,
        java_package,
        manifest_ctx,
        packaged_resources_ctx,
        jvm_ctx,
        native_libs_ctx,
        apk_packaging_ctx,
        **_unused_ctxs):
    if not acls.in_android_binary_starlark_rollout(str(ctx.label)):
        return ProviderInfo(name = "intellij_ctx", value = struct())

    android_ide_info = _intellij.make_android_ide_info(
        ctx,
        java_package = java_package,
        manifest = manifest_ctx.processed_manifest,
        defines_resources = True,
        merged_manifest = packaged_resources_ctx.processed_manifest,
        resources_apk = packaged_resources_ctx.resources_apk,
        r_jar = utils.only(packaged_resources_ctx.r_java.outputs.jars) if packaged_resources_ctx.r_java else None,
        java_info = jvm_ctx.java_info,
        signed_apk = apk_packaging_ctx.signed_apk,
        native_libs = native_libs_ctx.native_libs_info.native_libs,
    )
    return ProviderInfo(
        name = "intellij_ctx",
        value = struct(
            android_ide_info = android_ide_info,
            providers = [android_ide_info],
        ),
    )

def _process_coverage(ctx, **_unused_ctxs):
    providers = []
    if acls.in_android_binary_starlark_rollout(str(ctx.label)):
        providers.append(coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["assets", "deps", "instruments"],
        ))

    return ProviderInfo(
        name = "coverage_ctx",
        value = struct(
            providers = providers,
        ),
    )

# Order dependent, as providers will not be available to downstream processors
# that may depend on the provider. Iteration order for a dictionary is based on
# insertion.
# buildifier: leave-alone
PROCESSORS = dict(
    BaseValidationsProcessor = _base_validations_processor,
    ManifestProcessor = _process_manifest,
    StampProcessor = _process_build_stamp,
    ResourceProcessor = _process_resources,
    ValidateManifestProcessor = _validate_manifest,
    NativeLibsProcessor = _process_native_libs,
    DataBindingProcessor = _process_data_binding,
    ProtoProcessor = _process_proto,
    JvmProcessor = _process_jvm,
    BuildInfoProcessor = _process_build_info,
    DeployJarProcessor = _process_deploy_jar,
    BaselineProfilesProcessor = _process_baseline_profiles,
    OptimizeProcessor = _process_optimize,
    DexProcessor = _process_dex,
    ArtProfileProcessor = _process_art_profile,
    R8Processor = process_r8,
    ResourecShrinkerR8Processor = process_resource_shrinking_r8,
    IdlProcessor = _process_idl,
    ApkPackagingProcessor = _process_apk_packaging,
    IntellijProcessor = _process_intellij,
    CoverageProcessor = _process_coverage,
)

_PROCESSING_PIPELINE = processing_pipeline.make_processing_pipeline(
    processors = PROCESSORS,
    finalize = finalize,
)

def impl(ctx):
    """The rule implementation.

    Args:
      ctx: The context.

    Returns:
      A list of providers.
    """
    java_package = ctx.attr.custom_package if ctx.attr.custom_package else None
    return processing_pipeline.run(ctx, java_package, _PROCESSING_PIPELINE)
