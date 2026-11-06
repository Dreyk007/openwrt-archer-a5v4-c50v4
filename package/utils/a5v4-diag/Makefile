#
# Diagnostic tools of the Archer A5 v4 / C50 v4 debug image (build.sh --dev), built from
# tests/router: in the flash they cost no RAM until they run, unlike copies in /tmp.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=a5v4-diag
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

PKG_FILE_DEPENDS:=$(TOPDIR)/tests/router

include $(INCLUDE_DIR)/package.mk

define Package/a5v4-diag
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Diagnostic tools of the Archer A5 v4 / C50 v4 debug image
endef

define Package/a5v4-diag/description
  kprof, a small system-wide CPU profiler, udpblast, a UDP load generator, and the
  test scripts of tests/router.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(TOPDIR)/tests/router/kprof.c $(TOPDIR)/tests/router/udpblast.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall -o $(PKG_BUILD_DIR)/kprof $(PKG_BUILD_DIR)/kprof.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall -o $(PKG_BUILD_DIR)/udpblast $(PKG_BUILD_DIR)/udpblast.c
endef

define Package/a5v4-diag/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/share/a5v4-diag
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/kprof $(PKG_BUILD_DIR)/udpblast $(1)/usr/sbin/
	$(INSTALL_BIN) $(TOPDIR)/tests/router/*.sh $(1)/usr/share/a5v4-diag/
endef

$(eval $(call BuildPackage,a5v4-diag))
