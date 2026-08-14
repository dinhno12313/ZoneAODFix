THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZoneAODFix

ZoneAODFix_FILES = Tweak.xm
ZoneAODFix_CFLAGS = -fobjc-arc
ZoneAODFix_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
