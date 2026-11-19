# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isp-tester
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Matt <matt400@users.noreply.github.com>

LUCI_TITLE:=ISP / IPTV / port fault logger
LUCI_DESCRIPTION:=Logs WAN, IPTV and switch-port faults as a timeline \
	with a probable-cause analysis. Ping data comes from collectd \
	(luci-app-statistics), session state from netifd, plus IGMP state, \
	interface counters and the system log.
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-uloop \
	+ucode-mod-uci +ucode-mod-ubus +ucode-mod-socket
LUCI_PKGARCH:=all

define Package/luci-app-isp-tester/conffiles
/etc/config/isp_tester
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
