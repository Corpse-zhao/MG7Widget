TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mghelper

mghelper_FILES          = main.m
mghelper_CFLAGS         = -fobjc-arc
mghelper_INSTALL_PATH    = /usr/bin
mghelper_CODESIGN_FLAGS  = -Smghelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# 确保 postinst 有执行位（git/Windows 不保留权限）
after-stage::
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst 2>/dev/null || true
