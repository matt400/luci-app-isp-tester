# SPDX-License-Identifier: Apache-2.0
#
# Helper of luci-app-isp-tester: counts lost MPEG-TS packets (picture
# errors) of the IPTV stream continuously and reads the channel names.
# Built per architecture; luci-app-isp-tester itself stays architecture-
# independent and works without it (picture quality and names then off).

include $(TOPDIR)/rules.mk

PKG_NAME:=isp-tester-tsmon
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Matt <matt400@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/isp-tester-tsmon
  SECTION:=net
  CATEGORY:=Network
  TITLE:=IPTV picture quality counter for luci-app-isp-tester
endef

define Package/isp-tester-tsmon/description
  Listens on the IPTV port with a kernel filter (only the IPTV multicast)
  and counts MPEG-TS continuity errors, transport errors, RTP gaps and
  pauses of every multicast group, continuously and without storing
  packets. Also reads the channel names (DVB SDT). Used by
  luci-app-isp-tester.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -Wall -Wextra \
		-o $(PKG_BUILD_DIR)/isp-tester-tsmon $(PKG_BUILD_DIR)/tsmon.c $(TARGET_LDFLAGS)
endef

define Package/isp-tester-tsmon/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/isp-tester-tsmon $(1)/usr/sbin/
endef

$(eval $(call BuildPackage,isp-tester-tsmon))
