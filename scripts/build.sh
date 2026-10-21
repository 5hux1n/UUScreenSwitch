#!/bin/bash
set -euo pipefail
export LC_ALL=C
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-16.4.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE_VERSION="${PACKAGE_VERSION:-$(sed -n 's/^Version: //p' control)}"
BUILD_ARGS=("PACKAGE_VERSION=$RELEASE_VERSION")

rm -rf dist packages
mkdir -p dist
BUILD_TMP="$(mktemp -d /tmp/uuscreenswitch-build.XXXXXX)"
trap 'rm -rf "$BUILD_TMP" "$ROOT/packages"' EXIT

# 1. Rootless (iphoneos-arm64, /var/jb)
make clean THEOS=/Users/manjunhong/theos THEOS_PACKAGE_SCHEME=rootless >/dev/null
make package THEOS=/Users/manjunhong/theos THEOS_PACKAGE_SCHEME=rootless \
    "${BUILD_ARGS[@]}" SYSROOT=/Users/manjunhong/theos/sdks/iPhoneOS16.5.sdk \
    THEOS_PACKAGE_DIR="$BUILD_TMP/rootless"
RL_DEB="$(find "$BUILD_TMP/rootless" -maxdepth 1 -name '*.deb' -print -quit)"
VER="$(/opt/homebrew/bin/dpkg-deb -f "$RL_DEB" Version)"
cp "$RL_DEB" "dist/uuhelper_${VER}_arm64.deb"

# 2. RootHide (iphoneos-arm64e, native roothide)
make clean THEOS=/Users/manjunhong/theos-roothide THEOS_PACKAGE_SCHEME=roothide >/dev/null
make package THEOS=/Users/manjunhong/theos-roothide THEOS_PACKAGE_SCHEME=roothide \
    "${BUILD_ARGS[@]}" SYSROOT=/Users/manjunhong/theos-roothide/sdks/iPhoneOS16.5.sdk \
    THEOS_PACKAGE_DIR="$BUILD_TMP/roothide"
RH_DEB="$(find "$BUILD_TMP/roothide" -maxdepth 1 -name '*.deb' -print -quit)"
VER_RH="$(/opt/homebrew/bin/dpkg-deb -f "$RH_DEB" Version)"
cp "$RH_DEB" "dist/uuhelper_${VER_RH}_arm64e.deb"

# 3. Verification checklist (package skill §5)
python3 - "$ROOT/dist/uuhelper_${VER}_arm64.deb" "$ROOT/dist/uuhelper_${VER_RH}_arm64e.deb" <<'PY'
import subprocess, sys, tempfile, pathlib

rl_deb, rh_deb = [pathlib.Path(p) for p in sys.argv[1:3]]

def check_deb(deb, expect_pkg, expect_arch, expect_prefix, expect_rpath):
    meta = subprocess.check_output(['/opt/homebrew/bin/dpkg-deb', '-f', str(deb)], text=True)
    fields = dict(line.split(': ', 1) for line in meta.strip().splitlines() if ': ' in line and not line.startswith(' '))
    assert fields['Package'] == expect_pkg, fields
    assert fields['Architecture'] == expect_arch, fields
    if expect_arch == 'iphoneos-arm64e':
        assert fields['Name'].endswith(' (Roothide)'), fields
    assert fields['Author'] == 'junhong', fields
    assert fields['Maintainer'] == 'junhong', fields
    assert fields['Depends'] == 'firmware (>= 15.0)', fields

    with tempfile.TemporaryDirectory() as td:
        subprocess.check_call(['/opt/homebrew/bin/dpkg-deb', '-x', str(deb), td])
        dylib = pathlib.Path(td) / expect_prefix.lstrip('/') / 'Library/MobileSubstrate/DynamicLibraries/UUScreenSwitch.dylib'
        plist = pathlib.Path(td) / expect_prefix.lstrip('/') / 'Library/MobileSubstrate/DynamicLibraries/UUScreenSwitch.plist'
        assert dylib.is_file(), f"Missing {dylib}"
        assert plist.is_file(), f"Missing {plist}"
        archs = subprocess.check_output(['lipo', '-archs', str(dylib)], text=True).split()
        assert 'arm64' in archs and 'arm64e' in archs, archs
        if expect_rpath:
            otool_l = subprocess.check_output(['otool', '-l', str(dylib)], text=True)
            assert otool_l.count('cmd LC_RPATH') >= 2, "Missing LC_RPATH in roothide dylib"
        assert b'com.netease.uuremote' in plist.read_bytes()
        data = dylib.read_bytes()
        for s in ['_TtC14nrd_ios_client13RemoteToolBar', '_TtC14nrd_ios_client21ControlPanelViewModel', '显示器']:
            assert s.encode('utf-8') in data or s.encode('utf-16-le') in data, f"Missing string {s}"
    print(f"[OK] {deb.name}: Package={fields['Package']} Arch={fields['Architecture']} Version={fields['Version']}")

check_deb(rl_deb, 'uuhelper', 'iphoneos-arm64', '/var/jb', False)
check_deb(rh_deb, 'uuhelper.roothide', 'iphoneos-arm64e', '/', True)
PY
