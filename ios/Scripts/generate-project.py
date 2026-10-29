#!/usr/bin/env python3
"""Generates StreamSetu.xcodeproj.

The iOS app compiles two sets of Swift files:
  * the platform-neutral part of the Mac app, referenced in place from ../macos/Sources/REDDY (listed in SharedSources.txt), and
  * the iOS-only app in ios/StreamSetu.

Run after adding or removing files:   python3 Scripts/generate-project.py
"""
import hashlib, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SHARED_ROOT = "../macos/Sources/REDDY"
APP_DIR = "StreamSetu"
PROJECT = "StreamSetu"
BUNDLE_ID = "app.streamsetu.ios"
DEPLOYMENT = "18.0"
VERSION = "1.1"
BUILD = "1"


def oid(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


# The signing team is chosen once in Xcode (Signing & Capabilities). Keep it across regenerations: take it from the environment,
# from ios/.signing-team, or from the project file that is about to be replaced.
def find_team():
    if os.environ.get("STREAMSETU_TEAM"):
        return os.environ["STREAMSETU_TEAM"]
    for path, rx in ((os.path.join(ROOT, ".signing-team"), None), (os.path.join(ROOT, f"{PROJECT}.xcodeproj", "project.pbxproj"), r"DEVELOPMENT_TEAM = (\w+);")):
        if os.path.exists(path):
            text = open(path).read()
            m = re.search(rx, text) if rx else re.match(r"\s*(\w+)", text)
            if m:
                return m.group(1)
    return None


TEAM = find_team()
if TEAM:
    open(os.path.join(ROOT, ".signing-team"), "w").write(TEAM + "\n")

shared = [l.strip() for l in open(os.path.join(ROOT, "SharedSources.txt")) if l.strip()]
for f in shared:
    if not os.path.exists(os.path.join(ROOT, SHARED_ROOT, f)):
        sys.exit("missing shared file: " + f)

app_swift, resources = [], []
for dp, dn, fn in os.walk(os.path.join(ROOT, APP_DIR)):
    dn[:] = sorted(d for d in dn if not d.endswith(".xcassets") and not d.startswith("."))
    for f in sorted(fn):
        rel = os.path.relpath(os.path.join(dp, f), os.path.join(ROOT, APP_DIR))
        if f.endswith(".swift"):
            app_swift.append(rel)
if os.path.isdir(os.path.join(ROOT, APP_DIR, "Assets.xcassets")):
    resources.append("Assets.xcassets")
if os.path.exists(os.path.join(ROOT, APP_DIR, "PrivacyInfo.xcprivacy")):
    resources.append("PrivacyInfo.xcprivacy")

objs = []          # (id, comment, body)


def add(i, comment, body):
    objs.append((i, comment, body))


def file_ref(path, name=None, kind=None, tree="<group>"):
    i = oid("fileref", path, tree)
    n = os.path.basename(path)
    ext = n.rsplit(".", 1)[-1] if "." in n else ""
    t = kind or {"swift": "sourcecode.swift", "plist": "text.plist.xml", "xcassets": "folder.assetcatalog"}.get(ext, "text")
    nm = f'name = "{name}"; ' if name else ""
    add(i, n, f'isa = PBXFileReference; lastKnownFileType = {t}; {nm}path = "{path}"; sourceTree = "{tree}";')
    return i


def build_file(ref, label, phase):
    i = oid("buildfile", ref, phase)
    add(i, f"{label} in {phase}", f"isa = PBXBuildFile; fileRef = {ref};")
    return i


def group(name, children, path=None, comment=None):
    i = oid("group", name, path or "", str(len(children)), "".join(children)[:40])
    p = f'path = "{path}"; ' if path else ""
    add(i, comment or name, f'isa = PBXGroup; children = ({", ".join(children)}); {p}name = "{name}"; sourceTree = "<group>";')
    return i


# --- tree builder for a list of relative file paths -------------------------------------------------
def tree_group(name, files, base_path, phase_files, phase):
    tree = {}
    for f in files:
        parts = f.split("/")
        node = tree
        for d in parts[:-1]:
            node = node.setdefault(d, {})
        node[parts[-1]] = None

    def make(nm, node, path, prefix):
        kids = []
        for k in sorted(node, key=lambda s: (node[s] is None, s.lower())):
            if node[k] is None:
                ref = file_ref(k)
                kids.append(ref)
                if k.endswith(".swift"):
                    phase_files.append(build_file(ref, k, phase))
            else:
                kids.append(make(k, node[k], k, prefix + k + "/"))
        return group(nm, kids, path=path)

    return make(name, tree, base_path, "")


sources_phase_files = []
shared_group = tree_group("Shared (macOS sources)", shared, SHARED_ROOT, sources_phase_files, "Sources")
app_group = tree_group("StreamSetu", app_swift, APP_DIR, sources_phase_files, "Sources")

# --- the widget extension: Continue Watching widget and the download Live Activity ----------------------------------------------------
WIDGET_DIR = "StreamSetuWidgets"
WIDGET_NAME = "StreamSetuWidgets"
WIDGET_BUNDLE = BUNDLE_ID + ".widgets"
widget_swift = sorted(f for f in os.listdir(os.path.join(ROOT, WIDGET_DIR)) if f.endswith(".swift"))
shared_ref = file_ref("Shared/WidgetShared.swift", tree="SOURCE_ROOT")
app_shared_build = build_file(shared_ref, "WidgetShared.swift", "Sources")
sources_phase_files.append(app_shared_build)
widget_build_files, widget_refs = [], []
for f in widget_swift:
    r = file_ref(f"{WIDGET_DIR}/{f}", tree="SOURCE_ROOT")
    widget_refs.append(r)
    widget_build_files.append(build_file(r, f, "WidgetSources"))
widget_build_files.append(build_file(shared_ref, "WidgetShared.swift", "WidgetSources"))
widget_plist = file_ref(f"{WIDGET_DIR}/Info.plist", kind="text.plist.xml", tree="SOURCE_ROOT")
widget_ent = file_ref(f"{WIDGET_DIR}/{WIDGET_NAME}.entitlements", kind="text.plist.entitlements", tree="SOURCE_ROOT")
widget_product = oid("product", "widget")
add(widget_product, f"{WIDGET_NAME}.appex", f'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = "{WIDGET_NAME}.appex"; sourceTree = BUILT_PRODUCTS_DIR;')
widget_group = group(WIDGET_NAME, widget_refs + [widget_plist, widget_ent], comment=WIDGET_NAME)
shared_group2 = group("Shared", [shared_ref])

res_files = []
res_refs = []
for r in resources:
    ref = file_ref(f"{APP_DIR}/{r}", kind=("folder.assetcatalog" if r.endswith(".xcassets") else "text.xml"), tree="SOURCE_ROOT")
    res_refs.append(ref)
    res_files.append(build_file(ref, r, "Resources"))
# The Hindi and Telugu text (Localizable.strings in hi.lproj and te.lproj) is shared with the Mac app and copied into the app as folders.
for code in ("en", "hi", "te"):
    ref = file_ref(f"../macos/Resources/Localization/{code}.lproj", kind="folder", tree="SOURCE_ROOT")
    res_refs.append(ref)
    res_files.append(build_file(ref, f"{code}.lproj", "Resources"))
plist_ref = file_ref(f"{APP_DIR}/Info.plist", kind="text.plist.xml", tree="SOURCE_ROOT")
products_ref = oid("product")
add(products_ref, f"{PROJECT}.app", f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{PROJECT}.app"; sourceTree = BUILT_PRODUCTS_DIR;')
# --- tests: unit tests that run inside the app (StreamSetuTests) and UI tests that drive it (StreamSetuUITests) -------------------------------------------
TEST_SPECS = [("StreamSetuTests", "unit"), ("StreamSetuUITests", "ui")]
tests = {}
for tname, kind in TEST_SPECS:
    tdir = os.path.join(ROOT, tname)
    tfiles = sorted(f for f in os.listdir(tdir) if f.endswith(".swift")) if os.path.isdir(tdir) else []
    trefs, tbuild = [], []
    for f in tfiles:
        r = file_ref(f"{tname}/{f}", tree="SOURCE_ROOT")
        trefs.append(r)
        tbuild.append(build_file(r, f, f"{tname}Sources"))
    tprod = oid("product", tname)
    add(tprod, f"{tname}.xctest", f'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{tname}.xctest"; sourceTree = BUILT_PRODUCTS_DIR;')
    tests[tname] = dict(kind=kind, build=tbuild, product=tprod, group=group(tname, trefs, comment=tname))
products_group = group("Products", [products_ref, widget_product] + [t["product"] for t in tests.values()])
main_group = group("Root", [shared_group, app_group, widget_group, shared_group2] + [t["group"] for t in tests.values()] + res_refs + [plist_ref, products_group])

sources_phase = oid("phase", "sources")
add(sources_phase, "Sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(sources_phase_files)}); runOnlyForDeploymentPostprocessing = 0;')
res_phase = oid("phase", "resources")
add(res_phase, "Resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(res_files)}); runOnlyForDeploymentPostprocessing = 0;')
MPVKIT_URL, MPVKIT_VERSION = "https://github.com/mpvkit/MPVKit", "1.1.0-n9.0.2"
pkg_ref = oid("package", "mpvkit")
pkg_dep = oid("packagedep", "MPVKit")
add(pkg_ref, 'XCRemoteSwiftPackageReference "MPVKit"', f'isa = XCRemoteSwiftPackageReference; repositoryURL = "{MPVKIT_URL}"; requirement = {{kind = exactVersion; version = "{MPVKIT_VERSION}";}};')
add(pkg_dep, "MPVKit", f'isa = XCSwiftPackageProductDependency; package = {pkg_ref}; productName = MPVKit;')
pkg_build = oid("buildfile", "MPVKit", "Frameworks")
add(pkg_build, "MPVKit in Frameworks", f'isa = PBXBuildFile; productRef = {pkg_dep};')
fw_phase = oid("phase", "frameworks")
add(fw_phase, "Frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({pkg_build}); runOnlyForDeploymentPostprocessing = 0;')

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "6.0",
    "TARGETED_DEVICE_FAMILY": '"1,2"',
    "SUPPORTS_MACCATALYST": "NO",
    "COPY_PHASE_STRIP": "NO",
}
proj_debug = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES",
                             "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG STREAMSETU_MPV $(inherited)"', "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"', "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"})
proj_release = dict(common, **{"DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "ENABLE_NS_ASSERTIONS": "NO", "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"STREAMSETU_MPV STREAMSETU_APPSTORE $(inherited)"', "SWIFT_OPTIMIZATION_LEVEL": '"-O"', "VALIDATE_PRODUCT": "YES"})
target_common = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": f"{APP_DIR}/StreamSetu.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{APP_DIR}/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}
if TEAM:
    target_common["DEVELOPMENT_TEAM"] = TEAM


def settings(d):
    return "{" + " ".join(f"{k} = {v};" for k, v in sorted(d.items())) + "}"



widget_sources = oid("phase", "widget-sources")
add(widget_sources, "Sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(widget_build_files)}); runOnlyForDeploymentPostprocessing = 0;')
widget_fw = oid("phase", "widget-frameworks")
add(widget_fw, "Frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
widget_common = {
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "CODE_SIGN_ENTITLEMENTS": f"{WIDGET_DIR}/{WIDGET_NAME}.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{WIDGET_DIR}/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"',
    "MARKETING_VERSION": VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": WIDGET_BUNDLE,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}
if TEAM:
    widget_common["DEVELOPMENT_TEAM"] = TEAM
wd, wr = oid("cfg", "widget", "Debug"), oid("cfg", "widget", "Release")
add(wd, "Debug", f'isa = XCBuildConfiguration; buildSettings = {settings(widget_common)}; name = Debug;')
add(wr, "Release", f'isa = XCBuildConfiguration; buildSettings = {settings(widget_common)}; name = Release;')
wl = oid("cfglist", "widget")
add(wl, f'Build configuration list for PBXNativeTarget "{WIDGET_NAME}"', f'isa = XCConfigurationList; buildConfigurations = ({wd}, {wr}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
widget_target = oid("target", "widget")
add(widget_target, WIDGET_NAME, f'isa = PBXNativeTarget; buildConfigurationList = {wl}; buildPhases = ({widget_sources}, {widget_fw}); buildRules = (); dependencies = (); name = "{WIDGET_NAME}"; productName = "{WIDGET_NAME}"; productReference = {widget_product}; productType = "com.apple.product-type.app-extension";')


pd, pr = oid("cfg", "proj", "Debug"), oid("cfg", "proj", "Release")
td, tr = oid("cfg", "target", "Debug"), oid("cfg", "target", "Release")
add(pd, "Debug", f'isa = XCBuildConfiguration; buildSettings = {settings(proj_debug)}; name = Debug;')
add(pr, "Release", f'isa = XCBuildConfiguration; buildSettings = {settings(proj_release)}; name = Release;')
add(td, "Debug", f'isa = XCBuildConfiguration; buildSettings = {settings(target_common)}; name = Debug;')
add(tr, "Release", f'isa = XCBuildConfiguration; buildSettings = {settings(target_common)}; name = Release;')
pl, tl = oid("cfglist", "proj"), oid("cfglist", "target")
add(pl, f'Build configuration list for PBXProject "{PROJECT}"', f'isa = XCConfigurationList; buildConfigurations = ({pd}, {pr}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add(tl, f'Build configuration list for PBXNativeTarget "{PROJECT}"', f'isa = XCConfigurationList; buildConfigurations = ({td}, {tr}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

target = oid("target")
proxy = oid("proxy", "widget")
add(proxy, "PBXContainerItemProxy", f'isa = PBXContainerItemProxy; containerPortal = {oid("project")}; proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = "{WIDGET_NAME}";')
dep = oid("dependency", "widget")
add(dep, "PBXTargetDependency", f'isa = PBXTargetDependency; target = {widget_target}; targetProxy = {proxy};')
embed_file = oid("buildfile", "embed", "widget")
add(embed_file, f"{WIDGET_NAME}.appex in Embed Foundation Extensions", f'isa = PBXBuildFile; fileRef = {widget_product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
embed_phase = oid("phase", "embed")
add(embed_phase, "Embed Foundation Extensions", f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({embed_file}); name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0;')
add(target, PROJECT, f'isa = PBXNativeTarget; buildConfigurationList = {tl}; buildPhases = ({sources_phase}, {fw_phase}, {res_phase}, {embed_phase}); buildRules = (); dependencies = ({dep});  packageProductDependencies = ({pkg_dep}); name = "{PROJECT}"; productName = "{PROJECT}"; productReference = {products_ref}; productType = "com.apple.product-type.application";')
test_targets = []
for tname, kind in TEST_SPECS:
    t = tests[tname]
    sp, fp = oid("phase", tname, "sources"), oid("phase", tname, "frameworks")
    add(sp, "Sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(t["build"])}); runOnlyForDeploymentPostprocessing = 0;')
    add(fp, "Frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    cfg = {
        "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": BUILD, "GENERATE_INFOPLIST_FILE": "YES", "MARKETING_VERSION": VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.{tname.lower()}", "PRODUCT_NAME": '"$(TARGET_NAME)"', "SWIFT_EMIT_LOC_STRINGS": "NO",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"',
    }
    if kind == "unit":
        cfg.update({"BUNDLE_LOADER": '"$(TEST_HOST)"', "TEST_HOST": f'"$(BUILT_PRODUCTS_DIR)/{PROJECT}.app/{PROJECT}"'})
    else:
        cfg.update({"TEST_TARGET_NAME": PROJECT})
    if TEAM:
        cfg["DEVELOPMENT_TEAM"] = TEAM
    cd_, cr_ = oid("cfg", tname, "Debug"), oid("cfg", tname, "Release")
    add(cd_, "Debug", f'isa = XCBuildConfiguration; buildSettings = {settings(cfg)}; name = Debug;')
    add(cr_, "Release", f'isa = XCBuildConfiguration; buildSettings = {settings(cfg)}; name = Release;')
    cl_ = oid("cfglist", tname)
    add(cl_, f'Build configuration list for PBXNativeTarget "{tname}"', f'isa = XCConfigurationList; buildConfigurations = ({cd_}, {cr_}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    tproxy = oid("proxy", tname)
    add(tproxy, "PBXContainerItemProxy", f'isa = PBXContainerItemProxy; containerPortal = {oid("project")}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = "{PROJECT}";')
    tdep = oid("dependency", tname)
    add(tdep, "PBXTargetDependency", f'isa = PBXTargetDependency; target = {target}; targetProxy = {tproxy};')
    tt = oid("target", tname)
    ptype = "com.apple.product-type.bundle.unit-test" if kind == "unit" else "com.apple.product-type.bundle.ui-testing"
    add(tt, tname, f'isa = PBXNativeTarget; buildConfigurationList = {cl_}; buildPhases = ({sp}, {fp}); buildRules = (); dependencies = ({tdep}); name = "{tname}"; productName = "{tname}"; productReference = {t["product"]}; productType = "{ptype}";')
    test_targets.append((tname, tt, kind))
ui_target_id = next(tt for n, tt, k in test_targets if k == "ui")
project = oid("project")
add(project, "Project object", f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; TargetAttributes = {{{ui_target_id} = {{TestTargetID = {target};}};}};}}; buildConfigurationList = {pl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; packageReferences = ({pkg_ref}); productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target}, {widget_target}, {", ".join(tt for _, tt, _ in test_targets)});')

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
sections = ["XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency", "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList"]
for s in sections:
    rows = [(i, c, b) for i, c, b in objs if f"isa = {s};" in b]
    if not rows:
        continue
    out.append(f"\n/* Begin {s} section */")
    for i, c, b in sorted(rows):
        out.append(f"\t\t{i} /* {c} */ = {{{b}}};")
    out.append(f"/* End {s} section */")
out += ["\t};", f"\trootObject = {project} /* Project object */;", "}", ""]

proj_dir = os.path.join(ROOT, f"{PROJECT}.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
open(os.path.join(proj_dir, "project.pbxproj"), "w").write("\n".join(out))
scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
def buildable(tid, name, prod, ext):
    return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{tid}" BuildableName = "{prod}.{ext}" BlueprintName = "{name}" ReferencedContainer = "container:{PROJECT}.xcodeproj"></BuildableReference>')
app_ref = buildable(target, PROJECT, PROJECT, "app")
entries = f'<BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">{app_ref}</BuildActionEntry>'
testables = "".join(f'<TestableReference skipped = "NO">{buildable(tt, n, n, "xctest")}</TestableReference>' for n, tt, k in test_targets)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
  <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction>
  <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES"><Testables>{testables}</Testables></TestAction>
  <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES"><BuildableProductRunnable runnableDebuggingMode = "0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"><BuildableProductRunnable runnableDebuggingMode = "0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
  <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
open(os.path.join(scheme_dir, f"{PROJECT}.xcscheme"), "w").write(scheme)
print(f"wrote {proj_dir}  ({len(shared)} shared files, {len(app_swift)} iOS files)")
