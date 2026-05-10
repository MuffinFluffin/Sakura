# Setting it to a range tells it that it supports the features on the newer
# versions as well, avoiding setting policies.
cmake_minimum_required(VERSION 3.16...4.2)

# Enabling this cmake policy gets rid of warnings regarding LTO.
cmake_policy(SET CMP0069 NEW)
set(CMAKE_POLICY_DEFAULT_CMP0069 NEW)

if(${CMAKE_SOURCE_DIR} STREQUAL ${CMAKE_BINARY_DIR})
	message(FATAL_ERROR "Sakura: use a separate build directory (e.g. cmake -B build -G Xcode -DCMAKE_SYSTEM_NAME=iOS).")
endif()

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
	message(FATAL_ERROR "Sakura is iOS-only. Pass -DCMAKE_SYSTEM_NAME=iOS with the Xcode generator.")
endif()

# Skip compiler checks to avoid freeze on Simulator environment
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_CXX_COMPILER_WORKS 1)

# Real device vs Simulator build
option(Sakura_REAL_DEVICE "Build for real iOS device (iphoneos SDK)" OFF)
if(Sakura_REAL_DEVICE)
    set(CMAKE_OSX_SYSROOT "iphoneos")
else()
    set(CMAKE_OSX_SYSROOT "iphonesimulator")
endif()
set(CMAKE_OSX_ARCHITECTURES "arm64")

# Version (single source of truth)
set(SAKURA_VERSION_MAJOR 0)
set(SAKURA_VERSION_MINOR 0)
set(SAKURA_VERSION_PATCH 1)
set(SAKURA_VERSION "${SAKURA_VERSION_MAJOR}.${SAKURA_VERSION_MINOR}.${SAKURA_VERSION_PATCH}")
set(SAKURA_BUILD_NUMBER 1)
# Xcode General → Minimum Deployments (single place; scripts/rebuild_sakura.sh should match)
set(SAKURA_IOS_MIN_VERSION "17.0" CACHE STRING "Minimum iOS version for Sakura target")

# Pin your Team ID here or pass -DIOS_DEVELOPMENT_TEAM=... so CMake-generated .xcodeproj keeps Signing.
# UI-only Team edits are lost whenever CMake regenerates the project unless this is set (see scripts/rebuild_sakura.sh + ios-development-team.local.example).
set(IOS_DEVELOPMENT_TEAM "" CACHE STRING "Apple Developer Team ID (10 chars); empty = no team in generated project")

if(IOS_DEVELOPMENT_TEAM STREQUAL "" AND CMAKE_HOST_APPLE)
	set(_sakura_team_local "${CMAKE_SOURCE_DIR}/../../ios-development-team.local")
	if(EXISTS "${_sakura_team_local}")
		file(READ "${_sakura_team_local}" _sakura_team_raw)
		if(_sakura_team_raw MATCHES "(IOS_DEVELOPMENT_TEAM|DEVELOPMENT_TEAM)[ \t]*=[ \t]*[\"']?([A-Za-z0-9]+)")
			set(IOS_DEVELOPMENT_TEAM "${CMAKE_MATCH_2}" CACHE STRING "Apple Developer Team ID (10 chars); empty = no team in generated project" FORCE)
		endif()
	endif()
endif()
if(IOS_DEVELOPMENT_TEAM STREQUAL "" AND CMAKE_HOST_APPLE)
	execute_process(
		COMMAND defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID
		OUTPUT_VARIABLE _sakura_xcode_team
		OUTPUT_STRIP_TRAILING_WHITESPACE
		ERROR_QUIET
		RESULT_VARIABLE _sakura_defaults_rc
	)
	if(_sakura_defaults_rc EQUAL 0 AND _sakura_xcode_team MATCHES "^[A-Za-z0-9]+$")
		set(IOS_DEVELOPMENT_TEAM "${_sakura_xcode_team}" CACHE STRING "Apple Developer Team ID (10 chars); empty = no team in generated project" FORCE)
	endif()
endif()

# ON = no embedded signature (e.g. Sideloadly re-sign). OFF = normal device signing via Xcode or IOS_DEVELOPMENT_TEAM.
option(IOS_FORCE_UNSIGNED "Strip CMake signing overrides for unsigned/IPA re-sign workflows" OFF)

# Project Name
project(Sakura VERSION ${SAKURA_VERSION} LANGUAGES C CXX)

# kill xcode target clutter: no zero_check, no install/package/uninstall,
# and only sakura gets a scheme in the picker (3rdparty libs still build).
set(CMAKE_SUPPRESS_REGENERATION TRUE)
set(CMAKE_SKIP_INSTALL_RULES TRUE)
set(CMAKE_XCODE_GENERATE_SCHEME FALSE)

# Code signing setup
if(CMAKE_GENERATOR STREQUAL "Xcode")
    if(NOT Sakura_REAL_DEVICE)
        # Simulator: ad-hoc signing
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "")
    elseif(IOS_FORCE_UNSIGNED)
        # Explicit unsigned build (re-sign outside Xcode)
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO")
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "")
    elseif(IOS_DEVELOPMENT_TEAM)
        set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES")
        set(CMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${IOS_DEVELOPMENT_TEAM}")
    endif()
    # real device default: do not set CODE_SIGNING_ALLOWED=NO, otherwise the
    # generated project overrides Xcode "Automatically manage signing" and the
    # app stays unsigned.
endif()

if(CMAKE_GENERATOR STREQUAL "Xcode" AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
    if(IOS_FORCE_UNSIGNED)
        message(STATUS "iOS: IOS_FORCE_UNSIGNED=ON, app not signed by Xcode (re-sign externally)")
    elseif(IOS_DEVELOPMENT_TEAM)
        message(STATUS "iOS: DEVELOPMENT_TEAM pinned in project (${IOS_DEVELOPMENT_TEAM})")
    elseif(Sakura_REAL_DEVICE)
        message(STATUS "iOS: use Xcode Signing & Capabilities (Team) or set IOS_DEVELOPMENT_TEAM")
    endif()
endif()

set(TOP_CMAKE_WAS_SOURCED TRUE)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
	add_compile_definitions(_M_ARM64=1)
    set(_M_ARM64 TRUE)
    set(_M_X86 FALSE)
    set(CMAKE_HOST_SYSTEM_PROCESSOR "arm64")
    enable_language(Swift)
    if(CMAKE_GENERATOR STREQUAL "Xcode")
        set(CMAKE_XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES "YES")
        set(CMAKE_XCODE_ATTRIBUTE_EMBEDDED_CONTENT_CONTAINS_SWIFT "YES")
    endif()


    # Swift source files (picked up recursively from src/swift/).
    set(_swift_root "${CMAKE_SOURCE_DIR}/../swift")
    file(GLOB_RECURSE SWIFT_SOURCES CONFIGURE_DEPENDS "${_swift_root}/*.swift")

    configure_file("${CMAKE_SOURCE_DIR}/Info.plist.in" "${CMAKE_BINARY_DIR}/SakuraBundleInfo.plist" @ONLY)

    add_executable(Sakura ios_main.mm SakuraBridge.mm SakuraPS1Core.mm SakuraNeuralUpscale.mm SakuraLogSink.mm SakuraGamepadIOS.mm IOSNativeFileIO.mm SakuraSMAA.mm ${SWIFT_SOURCES})
    target_compile_definitions(Sakura PRIVATE $<$<CONFIG:Debug>:DEBUG=1>)
    target_compile_features(Sakura PRIVATE cxx_std_17)
    # SakuraPS1Core uses __weak + ObjC objects in blocks; compile this unit with ARC (rest of target stays MRC).
    # Xcode generator here does not compile .metal into default.metallib; POST_BUILD emits SakuraPresentation.metallib next to the executable.
    add_custom_command(
        TARGET Sakura POST_BUILD
        COMMAND /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/compile_sakura_presentation_metallib.sh"
                "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Compile SakuraPresentation.metallib + copy SakuraL10n into app bundle"
        VERBATIM)
    set_source_files_properties(SakuraPS1Core.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    set_source_files_properties(SakuraSMAA.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    set_source_files_properties(SakuraNeuralUpscale.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    set_source_files_properties(IOSNativeFileIO.mm PROPERTIES COMPILE_FLAGS "-fno-objc-arc")
    set_target_properties(Sakura PROPERTIES
        XCODE_GENERATE_SCHEME TRUE
        XCODE_SCHEME_DISABLE_MAIN_THREAD_CHECKER YES)
    if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.23")
        set_target_properties(Sakura PROPERTIES XCODE_SCHEME_LAUNCH_CONFIGURATION "Release")
    endif()
    if(IOS_FORCE_UNSIGNED)
        set_target_properties(Sakura PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Manual"
            XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
            XCODE_ATTRIBUTE_DEVELOPMENT_TEAM ""
            XCODE_ATTRIBUTE_PROVISIONING_PROFILE_SPECIFIER ""
        )
    elseif(IOS_DEVELOPMENT_TEAM)
        set_target_properties(Sakura PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "YES"
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "YES"
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
            XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${IOS_DEVELOPMENT_TEAM}"
            XCODE_ATTRIBUTE_PROVISIONING_PROFILE_SPECIFIER ""
        )
    endif()
    # else: do not set CODE_SIGN_* / DEVELOPMENT_TEAM, Signing & Capabilities in Xcode applies.
    set_target_properties(Sakura PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.sakura.psx"
        MACOSX_BUNDLE_BUNDLE_NAME "Sakura"
        MACOSX_BUNDLE_BUNDLE_VERSION "${SAKURA_BUILD_NUMBER}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${SAKURA_VERSION}"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/SakuraBundleInfo.plist"
        MACOSX_BUNDLE_EXECUTABLE_NAME "Sakura"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.sakura.psx"
        # xcode General Version/Build + store metadata; info.plist uses $(MARKETING_VERSION) etc.
        XCODE_ATTRIBUTE_MARKETING_VERSION "${SAKURA_VERSION}"
        XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${SAKURA_BUILD_NUMBER}"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2" # 1=iPhone, 2=iPad
        XCODE_ATTRIBUTE_INFOPLIST_FILE "${CMAKE_BINARY_DIR}/SakuraBundleInfo.plist"
        XCODE_ATTRIBUTE_SUPPORTS_MAC_DESIGNED_FOR_IPAD "YES"
        XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "${SAKURA_IOS_MIN_VERSION}"
        XCODE_ATTRIBUTE_SDKROOT "${CMAKE_OSX_SYSROOT}"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS[variant=Debug] "${CMAKE_SOURCE_DIR}/Entitlements.plist"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS[variant=RelWithDebInfo] "${CMAKE_SOURCE_DIR}/Entitlements.plist"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS[variant=Release] "${CMAKE_SOURCE_DIR}/Entitlements.Release.plist"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS[variant=MinSizeRel] "${CMAKE_SOURCE_DIR}/Entitlements.Release.plist"
        XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_SOURCE_DIR}/Sakura-Bridging-Header.h"
        XCODE_ATTRIBUTE_SWIFT_VERSION "6.0"
        XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES "YES"
        XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES "YES"
        XCODE_ATTRIBUTE_EMBEDDED_CONTENT_CONTAINS_SWIFT "YES"
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
        # `xcodebuild archive` (and install), NOT `xcodebuild build`.
        XCODE_ATTRIBUTE_SKIP_INSTALL "NO"
        XCODE_ATTRIBUTE_INSTALL_PATH "$(LOCAL_APPS_DIR)"
        # Keep .app under SYMROOT (alongside Sakura.build intermediates). Absolute
        # CONFIGURATION_BUILD_DIR at build/atmos/Release-iphoneos confuses Xcode’s
        # new build system vs TARGET_TEMP_DIR under build/atmos/build/ (MkDir / internal inconsistency).
        XCODE_ATTRIBUTE_CONFIGURATION_BUILD_DIR "$(SYMROOT)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"
        # app category + landscape-only + hidden status bar on launch.
        XCODE_ATTRIBUTE_INFOPLIST_KEY_LSApplicationCategoryType "public.app-category.games"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_UIStatusBarStyle "UIStatusBarStyleDefault"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_UIStatusBarHidden "YES"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_UILaunchStoryboardName ""
        XCODE_ATTRIBUTE_INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        # Release configs used `-O1` / Swift `-O` while Debug used `-O0`; first GPU frame could SIGSEGV only in ship builds.
        XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=Release] "0"
        XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=MinSizeRel] "0"
        XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL[variant=RelWithDebInfo] "0"
        XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=Release] "-Onone"
        XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=MinSizeRel] "-Onone"
        XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=RelWithDebInfo] "-Onone"
    )
    # [P53] Asset catalog (app icon + splash image)
    set(ASSET_CATALOG "${CMAKE_SOURCE_DIR}/../assets/Assets.xcassets")
    target_sources(Sakura PRIVATE "${ASSET_CATALOG}")
    set_source_files_properties("${ASSET_CATALOG}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

    # App Store / ITMS: required-reason declarations for covered APIs (UserDefaults, file timestamps).
    set(SAKURA_PRIVACY_MANIFEST "${CMAKE_SOURCE_DIR}/PrivacyInfo.xcprivacy")
    target_sources(Sakura PRIVATE "${SAKURA_PRIVACY_MANIFEST}")
    set_source_files_properties("${SAKURA_PRIVACY_MANIFEST}" PROPERTIES MACOSX_PACKAGE_LOCATION "")
    # Swift runtime link paths for device builds
    set_target_properties(Sakura PROPERTIES
        XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks /usr/lib/swift"
        XCODE_ATTRIBUTE_LIBRARY_SEARCH_PATHS "$(inherited) /usr/lib/swift"
    )
    # Exclude -pipe and other C++ flags from Swift compilation
    set_target_properties(Sakura PROPERTIES
        XCODE_ATTRIBUTE_OTHER_SWIFT_FLAGS ""
    )
    # Remove -pipe from Swift by adding it only to C/CXX
    target_compile_options(Sakura PRIVATE $<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-pipe>)

    target_link_options(Sakura PRIVATE "-Wl,-no_warn_duplicate_libraries")

    target_link_libraries(Sakura PRIVATE
        "-framework UIKit"
        "-framework Metal"
        "-framework MetalFX"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework CoreText"
        "-framework CoreGraphics"
        "-framework CoreVideo"
        "-framework CoreMedia"
        "-framework VideoToolbox"
        "-framework GameController"
        "-framework StoreKit"
        "-framework AVFoundation"
        "-framework ReplayKit"
        "-framework CoreAudio"
        "-framework AudioToolbox"
    )

    # PS1: Mednafen/Beetle PSX libretro core (build e.g. `make platform=ios-arm64` in libretro/beetle-psx-libretro).
    # Vendor the dylib under src/cpp/vendor/ or set SAKURA_LIBRETRO_PSX_LIBRARY to a .a/.dylib path.
    option(SAKURA_ENABLE_LIBRETRO_PSX "Link the libretro PS1 core when a library is available" ON)
    set(SAKURA_LIBRETRO_PSX_LIBRARY "" CACHE FILEPATH "Optional path to mednafen_psx libretro library; empty = use bundled vendor dylib if present")
    set(_sakura_psx_lib "${SAKURA_LIBRETRO_PSX_LIBRARY}")
    if(NOT _sakura_psx_lib AND EXISTS "${CMAKE_SOURCE_DIR}/vendor/mednafen_psx_libretro_ios.dylib")
        set(_sakura_psx_lib "${CMAKE_SOURCE_DIR}/vendor/mednafen_psx_libretro_ios.dylib")
    endif()
    if(SAKURA_ENABLE_LIBRETRO_PSX AND _sakura_psx_lib AND EXISTS "${_sakura_psx_lib}")
        # never install_name_tool the source dylib. it invalidates nested signatures and breaks AMFI (esp. Mac runs).
        set(_sakura_psx_staged "${CMAKE_BINARY_DIR}/generated/mednafen_psx_libretro_ios.dylib")
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/generated")
        execute_process(COMMAND ${CMAKE_COMMAND} -E copy "${_sakura_psx_lib}" "${_sakura_psx_staged}")
        # install_name_tool strips any existing signature; Xcode "Code Sign on Copy" is skipped when the app
        # target is unsigned/manual, dyld then aborts ("no cdhash"). re-sign staged copy every build.
        add_custom_command(
            TARGET Sakura
            PRE_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy "${_sakura_psx_lib}" "${_sakura_psx_staged}"
            COMMAND install_name_tool -id @rpath/MednafenPSX.framework/MednafenPSX "${_sakura_psx_staged}"
            COMMAND codesign --force --sign - --timestamp=none "${_sakura_psx_staged}"
            COMMENT "Stage PS1 core for link; bundle copies into MednafenPSX.framework at POST_BUILD"
            VERBATIM
        )
        target_link_libraries(Sakura PRIVATE "${_sakura_psx_staged}")
        add_custom_command(
            TARGET Sakura
            POST_BUILD
            COMMAND /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/bundle_libretro_psx_framework.sh"
                    "${_sakura_psx_staged}"
                    "${SAKURA_IOS_MIN_VERSION}"
            WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            COMMENT "App Store: embed PS1 core as MednafenPSX.framework (bare .dylib in Frameworks breaks ITMS)"
            VERBATIM
        )
        target_compile_definitions(Sakura PRIVATE SAKURA_ENABLE_LIBRETRO_PSX=1)
        message(STATUS "Sakura: PS1 core linked/embed (${_sakura_psx_staged}; source ${_sakura_psx_lib})")
    else()
        target_compile_definitions(Sakura PRIVATE SAKURA_ENABLE_LIBRETRO_PSX=0)
        if(SAKURA_ENABLE_LIBRETRO_PSX)
            message(STATUS "Sakura: no PS1 core file. add vendor/mednafen_psx_libretro_ios.dylib or set SAKURA_LIBRETRO_PSX_LIBRARY")
        endif()
    endif()
	# Git short hash for BUILD_ID
	execute_process(
		COMMAND git rev-parse --short HEAD
		WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
		OUTPUT_VARIABLE Sakura_GIT_HASH
		OUTPUT_STRIP_TRAILING_WHITESPACE
		ERROR_QUIET
	)
	if(NOT Sakura_GIT_HASH)
		set(Sakura_GIT_HASH "unknown")
	endif()
	target_compile_definitions(Sakura PRIVATE Sakura_GIT_HASH="${Sakura_GIT_HASH}" SAKURA_VERSION_STR="${SAKURA_VERSION}")
    target_include_directories(Sakura PRIVATE
        ${CMAKE_SOURCE_DIR}
        ${CMAKE_BINARY_DIR}
    )

    file(GLOB FONTS "${CMAKE_SOURCE_DIR}/../assets/resources/fonts/*.ttf" "${CMAKE_SOURCE_DIR}/../assets/resources/fonts/*.otf")
    target_sources(Sakura PRIVATE ${FONTS})
    set_source_files_properties(${FONTS} PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources/fonts
    )

    set(_cherry_blossoms_backdrop "${CMAKE_SOURCE_DIR}/../assets/resources/background/CherryBlossomsBackdrop.mp4")
    if(EXISTS "${_cherry_blossoms_backdrop}")
        target_sources(Sakura PRIVATE "${_cherry_blossoms_backdrop}")
        set_source_files_properties("${_cherry_blossoms_backdrop}" PROPERTIES
            MACOSX_PACKAGE_LOCATION Resources
        )
    endif()

    set(_neural_dir "${CMAKE_SOURCE_DIR}/../swift/Resources/NeuralUpscale")
    file(GLOB _neural_bundle_assets CONFIGURE_DEPENDS
        "${_neural_dir}/*.mlmodel"
        "${_neural_dir}/*.mlpackage"
    )
    foreach(_neural_f IN LISTS _neural_bundle_assets)
        target_sources(Sakura PRIVATE "${_neural_f}")
        set_source_files_properties("${_neural_f}" PROPERTIES
            MACOSX_PACKAGE_LOCATION Resources/NeuralUpscale
            HEADER_FILE_ONLY TRUE
        )
    endforeach()

    # Localized InfoPlist.strings for iOS system permission dialogs.
    # Each <lang>.lproj/InfoPlist.strings becomes <Sakura.app>/<lang>.lproj/InfoPlist.strings.
    file(GLOB _lproj_dirs CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/../swift/Resources/*.lproj"
    )
    foreach(_lproj IN LISTS _lproj_dirs)
        get_filename_component(_lproj_name "${_lproj}" NAME)
        set(_strings_path "${_lproj}/InfoPlist.strings")
        if(EXISTS "${_strings_path}")
            target_sources(Sakura PRIVATE "${_strings_path}")
            set_source_files_properties("${_strings_path}" PROPERTIES
                MACOSX_PACKAGE_LOCATION "${_lproj_name}"
            )
        endif()
    endforeach()

    set_target_properties(Sakura PROPERTIES
        MACOSX_BUNDLE_EXECUTABLE_NAME "Sakura"
        OUTPUT_NAME "Sakura"
    )
endif()
