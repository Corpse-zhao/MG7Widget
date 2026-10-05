TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mghelper

mghelper_FILES          = main.m bridge.m
mghelper_CFLAGS         = -fobjc-arc
mghelper_INSTALL_PATH    = /usr/bin
mghelper_CODESIGN_FLAGS  = -Smghelper.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

# setuid 提权：iOS 上各 App 容器属于独立本地用户，mobile 身份读不了 MG Live 沙盒。
# 直接在 staging 阶段把二进制设为 6755(root, setgid+setuid)，打包进 data.tar 的 mode 会保留。
# （此 theos 分支不自动收录项目根的 postinst 脚本 → postinst 放 layout/DEBIAN/）
#
# v0.2.0：新增 bridge 模式；layout/Library/LaunchDaemons/ 里的守护进程 plist 由 Theos
#   自动并入包内。注意 roothide 下 LaunchDaemon 必须由 postinst 主动 launchctl load 才会起来。
#
# 用 find 定位 staging 里的二进制/plist，兼容 rootful / rootless(/var/jb) / roothide 三种前缀。
after-stage::
	@BIN=$$(find $(THEOS_STAGING_DIR) -type f -name mghelper -path '*/usr/bin/*' 2>/dev/null | head -1); \
	if [ -n "$$BIN" ]; then chmod 6755 "$$BIN"; echo ">> setuid set: $$(ls -l "$$BIN")"; \
	else echo ">> !! mghelper 未出现在 staging"; fi
	@PL=$$(find $(THEOS_STAGING_DIR) -type f -name 'com.banliren.mghelper.bridge.plist' 2>/dev/null | head -1); \
	if [ -n "$$PL" ]; then chmod 0644 "$$PL"; echo ">> daemon plist: $$PL"; \
	else echo ">> !! daemon plist 未出现在 staging"; fi
	@echo ">> staging tree:"; find $(THEOS_STAGING_DIR) -type f 2>/dev/null | sed 's|$(THEOS_STAGING_DIR)||' | sort
