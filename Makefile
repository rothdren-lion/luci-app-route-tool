# by 数码罗记 · godsun.pro
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-route-tool
# Keep Makefile and CONTROL/control aligned for the 0.3.8 memory-pressure/uninstall-safety release.
PKG_VERSION:=0.3.8
PKG_RELEASE:=1
PKG_MAINTAINER:=godsun.pro
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

 define Package/luci-app-route-tool
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Route Tool - router partition backup/write tool
  PKGARCH:=all
  DEPENDS:=+luci-base
 endef

 define Package/luci-app-route-tool/description
  LuCI WebUI for backing up and writing router key partitions: Qualcomm eMMC GPT/cdt/art/appsbl/factory/mibib and MTK BL2/fip/factory. GPT is shown on eMMC devices only.
 endef

 define Build/Compile
 endef

 define Package/luci-app-route-tool/install
	$(CP) ./files/* $(1)/
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/route-tool $(1)/usr/libexec/route-tool
 endef

$(eval $(call BuildPackage,luci-app-route-tool))
