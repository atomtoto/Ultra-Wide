#!/usr/bin/env python3
"""Generate the dependency-free Xcode project deterministically."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, value):
    key = uid(name)
    objects[key] = value
    return key
def q(s): return json.dumps(str(s))
def arr(values): return '(' + ', '.join(values) + (',' if values else '') + ')'

products = []
targets = []
groups = []
for name, folder, kind in [('UltraWide', 'UltraWide', 'application'), ('UltraWideTests', 'UltraWideTests', 'bundle.unit-test'), ('UltraWideUITests', 'UltraWideUITests', 'bundle.ui-testing')]:
    children, sources, resources = [], [], []
    paths = sorted((ROOT / folder).rglob('*.swift'))
    if name == 'UltraWide': paths += [ROOT / folder / 'Resources/Assets.xcassets', ROOT / folder / 'Resources/PrivacyInfo.xcprivacy', ROOT / folder / 'Resources/Info.plist']
    for path in paths:
        rel = str(path.relative_to(ROOT))
        filetype = {'swift': 'sourcecode.swift', 'xcassets': 'folder.assetcatalog', 'xcprivacy': 'text.xml', 'plist': 'text.plist.xml'}[path.suffix[1:]]
        ref = add(rel, f'{{isa = PBXFileReference; lastKnownFileType = {q(filetype)}; path = {q(rel)}; sourceTree = SOURCE_ROOT; }}')
        children.append(ref)
        if path.suffix != '.plist':
            build = add('build' + rel, f'{{isa = PBXBuildFile; fileRef = {ref}; }}')
            (sources if path.suffix == '.swift' else resources).append(build)
    groups.append(add(name+'group', f'{{isa = PBXGroup; children = {arr(children)}; name = {q(name)}; sourceTree = "<group>"; }}'))
    source_phase = add(name+'sources', f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(sources)}; runOnlyForDeploymentPostprocessing = 0; }}')
    resource_phase = add(name+'resources', f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr(resources)}; runOnlyForDeploymentPostprocessing = 0; }}')
    framework_phase = add(name+'frameworks', '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    ext = 'app' if kind == 'application' else 'xctest'
    product = add(name+'product', f'{{isa = PBXFileReference; explicitFileType = {q("wrapper.application" if ext == "app" else "wrapper.cfbundle")}; path = {q(name+"."+ext)}; sourceTree = BUILT_PRODUCTS_DIR; }}')
    products.append(product)
    configs = []
    for config in ['Debug', 'Release']:
        settings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.ultrawide.'+('camera' if name == 'UltraWide' else name.lower()), 'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'TARGETED_DEVICE_FAMILY': '1', 'CODE_SIGN_STYLE': 'Automatic', 'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'targeted', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks'}
        if name == 'UltraWide':
            settings.update({'INFOPLIST_FILE': 'UltraWide/Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor', 'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1', 'SUPPORTS_MACCATALYST': 'NO', 'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD': 'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD': 'NO'})
        elif name == 'UltraWideTests': settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/UltraWide.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/UltraWide', 'BUNDLE_LOADER':'$(TEST_HOST)'})
        else: settings['TEST_TARGET_NAME'] = 'UltraWide'
        if config == 'Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        configs.append(add(name+config, '{isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+config+'; }'))
    config_list = add(name+'configs', f'{{isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
    deps = []
    if name != 'UltraWide':
        proxy = add(name+'proxy', f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("UltraWidetarget")}; remoteInfo = UltraWide; }}')
        deps.append(add(name+'dep', f'{{isa = PBXTargetDependency; target = {uid("UltraWidetarget")}; targetProxy = {proxy}; }}'))
    targets.append(add(name+'target', f'{{isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = {arr([source_phase,framework_phase,resource_phase])}; buildRules = (); dependencies = {arr(deps)}; name = {q(name)}; productName = {q(name)}; productReference = {product}; productType = {q("com.apple.product-type."+kind)}; }}'))
product_group = add('products', f'{{isa = PBXGroup; children = {arr(products)}; name = Products; sourceTree = "<group>"; }}')
main_group = add('main', f'{{isa = PBXGroup; children = {arr(groups+[product_group])}; sourceTree = "<group>"; }}')
configs = []
for config in ['Debug','Release']:
    settings = {'SDKROOT':'iphoneos','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym'}
    configs.append(add('project'+config, '{isa = XCBuildConfiguration; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'}; name = '+config+'; }'))
config_list = add('projectconfigs', f'{{isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
add('project', f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = fr; knownRegions = (fr, en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; targets = {arr(targets)}; }}')
(ROOT/'UltraWide.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {v};' for k,v in objects.items()) + '\n}; rootObject = '+uid('project')+'; }\n')
def buildref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name+"target")}" BuildableName="{name}.{ "app" if name == "UltraWide" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:UltraWide.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref('UltraWide')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildref('UltraWideTests')}</TestableReference><TestableReference skipped="NO">{buildref('UltraWideUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('UltraWide')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('UltraWide')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(ROOT/'UltraWide.xcodeproj/xcshareddata/xcschemes/UltraWide.xcscheme').write_text(scheme)
for name, rgb in [('AccentColor', ['0.73','0.94','0.77']),('LaunchBackground',['0.035','0.065','0.068'])]:
    folder = ROOT/'UltraWide/Resources/Assets.xcassets'/f'{name}.colorset'; folder.mkdir(exist_ok=True)
    (folder/'Contents.json').write_text(json.dumps({'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':dict(zip(['red','green','blue','alpha'],rgb+['1.000']))}}],'info':{'author':'xcode','version':1}},indent=2))
(ROOT/'UltraWide/Resources/Assets.xcassets/Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
(ROOT/'UltraWide/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json').write_text('{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}')
