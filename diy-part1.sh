#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 清理旧版 dae / daed / daede 残留包
rm -rf package/openwrt-daede package/dae package/daed package/luci-app-daede

# 2. 注入最新版 Aurora 主题与配置插件
rm -rf package/luci-theme-aurora package/luci-app-aurora-config
git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
git clone --depth 1 https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
