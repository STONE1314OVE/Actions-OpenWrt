#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# Description: OpenWrt DIY script part 1 (Before Update feeds)
# 脚本功能：配置额外的软件源（Feeds）
#

# 1. 添加 'sbwml' 软件源
# 原因：这是 ImmortalWrt 社区公认的高质量“科学上网”软件源，包含最新的 DAED、luci-app-daed 以及关键的 BPF 依赖包。
# 官方默认源中的 DAED 版本可能滞后，且可能缺乏必要的内核依赖处理。
# 引用证据：[15, 16] 确认 sbwml 仓库包含 daed 和 luci-app-daed。
echo 'src-git sbwml https://github.com/sbwml/openwrt_helloworld.git;v5' >> feeds.conf.default

# 2. 添加 Aurora 主题和配置插件
# 原因：用户明确要求使用 Aurora 主题。将仓库直接 clone 到 package/ 目录下，
# 这样构建系统会将其视为本地包，优先级高于 feeds 中的同名包（如果有）。
# 引用证据：[1, 10] 确认仓库地址。
git clone https://github.com/eamonxg/luci-theme-aurora package/luci-theme-aurora
git clone https://github.com/eamonxg/luci-app-aurora-config package/luci-app-aurora-config

# 3. 添加 MosDNS 和 V2Ray-Geodata (可选，但建议)
# 原因：DAED 运行时通常依赖 GeoIP 和 GeoSite 数据库来进行路由判断。
# 虽然 sbwml 源可能包含这些，但显式添加相关源可以防止编译时的依赖缺失错误。
# (此处不做操作，假设 sbwml 源已处理好依赖，保持脚本精简符合用户"无其他插件"的倾向)
