#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI firmware update check for the Archer A5 v4 / C50 v4 build
LUCI_DESCRIPTION:=Checks the GitHub releases of this build, shows a notice on the Overview page \
	and installs a new release from LuCI (System -> Archer A5 v4 / C50 v4 build updates).
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle
LUCI_URL:=https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4
LUCI_MAINTAINER:=Dreyk007

PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
