TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mghelper

mghelper_FILES          = main.m
mghelper_CFLAGS         = -fobjc-arc
mghelper_INSTALL_PATH    = /usr/bin
mghelper_CODESIGN_FLAGS  = -Smghelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# setuid 提权：iOS 上各 App 容器属于独立本地用户，mobile 身份读不了 MG Live 沙盒。
# 直接在 staging 阶段把二进制设为 4755(root, setuid)，打包进 data.tar 的 mode 会保留。
# （此 theos 分支不自动收录项目根的 postinst 脚本，故在 Makefile 里做）
after-stage::
	@chmod 6755 $(THEOS_STAGING_DIR)/usr/bin/mghelper && echo ">> setuid set: $$(ls -l $(THEOS_STAGING_DIR)/usr/bin/mghelper)"
