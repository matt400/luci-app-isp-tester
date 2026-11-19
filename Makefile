# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isp-tester
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Matt <matt400@users.noreply.github.com>

LUCI_TITLE:=ISP / IPTV / port fault logger
LUCI_DESCRIPTION:=Monitors WAN ping loss and latency, IPTV bitrate and \
	switch-port link/error counters, and logs every fault as a timeline \
	with CSV export.
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-uloop \
	+ucode-mod-uci +ucode-mod-ubus
LUCI_PKGARCH:=all

define Package/luci-app-isp-tester/conffiles
/etc/config/isp_tester
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
