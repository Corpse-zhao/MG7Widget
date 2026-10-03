TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mghelper

mghelper_FILES          = main.m
mghelper_CFLAGS         = -fobjc-arc
mghelper_INSTALL_PATH    = /usr/bin
mghelper_CODESIGN_FLAGS  = -Smghelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
