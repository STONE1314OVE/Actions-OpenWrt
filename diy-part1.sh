#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 抛弃旧版 hello 源，注入全新 openwrt-daede 双核心仓库
rm -rf package/openwrt-daede package/dae package/daed package/luci-app-daede
git clone --depth 1 https://github.com/kenzok8/openwrt-daede.git package/openwrt-daede

# 2. 注入最新版 Aurora 主题与配置插件（不锁定版本）
rm -rf package/luci-theme-aurora package/luci-app-aurora-config
git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
git clone --depth 1 https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config
