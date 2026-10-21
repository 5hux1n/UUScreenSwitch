export LC_ALL=C
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless
FINALPACKAGE = 1

BASE_PACKAGE = im.mjh.uuscreenswitch

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UUScreenSwitch
UUScreenSwitch_FILES = Tweak.m Trampoline.S
UUScreenSwitch_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -Wno-cast-function-type-mismatch -fmodules-cache-path=/tmp/uuscreenswitch-$(THEOS_PACKAGE_SCHEME)-modules
UUScreenSwitch_FRAMEWORKS = UIKit Foundation QuartzCore
UUScreenSwitch_USE_SUBSTRATE = 0

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
UUScreenSwitch_LDFLAGS += -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
                          -Wl,-rpath,@loader_path/.jbroot/usr/lib
endif

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	@sed -i '' 's/^Package: .*/Package: $(BASE_PACKAGE).roothide/; s/^Name: .*/Name: UU远控切屏 (Roothide)/' $(THEOS_STAGING_DIR)/DEBIAN/control
endif
