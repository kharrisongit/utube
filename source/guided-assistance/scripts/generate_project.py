#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project with Python's standard library."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "GuidedAssistance.xcodeproj"
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(object_key, isa, **fields):
    key = ident(object_key)
    objects[key] = dict(isa=isa, **fields)
    return key

def ref(path, kind):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind,
               path=path, sourceTree="<group>")

def configurations(name, settings):
    configs = []
    for mode in ["Debug", "Release"]:
        config = dict(settings)
        config["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        config["DEBUG_INFORMATION_FORMAT"] = "dwarf" if mode == "Debug" else "dwarf-with-dsym"
        if mode == "Debug":
            config["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
        configs.append(add(name + mode, "XCBuildConfiguration", name=mode, buildSettings=config))
    return add(name + "configs", "XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

sources = sorted(str(p.relative_to(ROOT)) for folder in ["App", "Core"] for p in (ROOT / folder).glob("*.swift"))
files = {path: ref(path, "sourcecode.swift") for path in sources}
resources = {"Assets.xcassets": ref("Assets.xcassets", "folder.assetcatalog")}
support = [ref("App/Info.plist", "text.plist.xml"), ref("App/Mac.entitlements", "text.plist.entitlements")]
packages = {}
for name, url, version in [
    ("mlx", "https://github.com/ml-explore/mlx-swift-lm", "3.32.3"),
    ("transformers", "https://github.com/huggingface/swift-transformers", "1.3.0")
]:
    packages[name] = add(name, "XCRemoteSwiftPackageReference", repositoryURL=url,
                         requirement={"kind": "exactVersion", "version": version})

targets, products = [], []
for platform in ["iOS", "Mac"]:
    name = "GuidedAssistance-" + platform
    sourceBuilds = [add(name + path, "PBXBuildFile", fileRef=file) for path, file in files.items()]
    resourceBuilds = [add(name + path, "PBXBuildFile", fileRef=file) for path, file in resources.items()]
    dependencies, frameworks = [], []
    for product, package in [("MLXLLM", "mlx"), ("MLXVLM", "mlx"), ("MLXLMCommon", "mlx"), ("Tokenizers", "transformers")]:
        dependency = add(name + product, "XCSwiftPackageProductDependency", package=packages[package], productName=product)
        dependencies.append(dependency)
        frameworks.append(add(name + product + "build", "PBXBuildFile", productRef=dependency))
    phases = [
        add(name + "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sourceBuilds, runOnlyForDeploymentPostprocessing=0),
        add(name + "frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=frameworks, runOnlyForDeploymentPostprocessing=0),
        add(name + "resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resourceBuilds, runOnlyForDeploymentPostprocessing=0)
    ]
    productRef = add(name + "app", "PBXFileReference", explicitFileType="wrapper.application",
                     includeInIndex=0, path="Guided Assistance.app", sourceTree="BUILT_PRODUCTS_DIR")
    products.append(productRef)
    settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.kharrison.guidedassistance" + (".mac" if platform == "Mac" else ""),
        "PRODUCT_NAME": "Guided Assistance", "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete", "CODE_SIGN_STYLE": "Automatic",
        "INFOPLIST_FILE": "App/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0.0",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES"
    }
    if platform == "iOS":
        settings.update(SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
                        IPHONEOS_DEPLOYMENT_TARGET="18.0", TARGETED_DEVICE_FAMILY="1,2",
                        SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO")
    else:
        settings.update(SDKROOT="macosx", SUPPORTED_PLATFORMS="macosx", MACOSX_DEPLOYMENT_TARGET="15.0",
                        ARCHS="arm64", CODE_SIGN_ENTITLEMENTS="App/Mac.entitlements",
                        ENABLE_HARDENED_RUNTIME="YES", COMBINE_HIDPI_IMAGES="YES",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"])
    target = add(name, "PBXNativeTarget", name=name, productName="Guided Assistance",
                 productType="com.apple.product-type.application", buildConfigurationList=configurations(name, settings),
                 buildPhases=phases, buildRules=[], dependencies=[], productReference=productRef,
                 packageProductDependencies=dependencies)
    targets.append(target)
    schemes = PROJECT / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Guided Assistance.app" BlueprintName="{name}" ReferencedContainer="container:GuidedAssistance.xcodeproj"/>'
    (schemes / (name + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

productGroup = add("products", "PBXGroup", name="Products", sourceTree="<group>", children=products)
group = add("mainGroup", "PBXGroup", children=list(files.values()) + list(resources.values()) + support + [productGroup], sourceTree="<group>")
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600"},
              buildConfigurationList=configurations("project", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SDKROOT": "auto", "SWIFT_EMIT_LOC_STRINGS": "YES"}),
              compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
              knownRegions=["en", "Base"], mainGroup=group, productRefGroup=productGroup,
              projectDirPath="", projectRoot="", packageReferences=list(packages.values()), targets=targets)

def encode(value, depth=0):
    pad = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "\n".join(pad + "\t" + json.dumps(str(k)) + " = " + encode(v, depth + 1) + ";" for k, v in value.items()) + "\n" + pad + "}"
    if isinstance(value, list):
        return "(\n" + "\n".join(pad + "\t" + encode(v, depth + 1) + "," for v in value) + "\n" + pad + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)

(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n")
print(f"Generated project: {len(sources)} Swift sources, {len(targets)} app targets.")
