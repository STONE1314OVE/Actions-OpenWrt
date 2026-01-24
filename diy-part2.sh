#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# Description: OpenWrt DIY script part 2 (After Update feeds)
# 脚本功能：源码修改、内核配置、系统默认设置
#

# --- 1. 网络配置修正 ---
# 将默认 IP 修改为 192.168.8.1，避免与光猫（通常是 1.1）冲突
sed -i 's/192.168.1.1/192.168.8.1/g' package/base-files/files/bin/config_generate

# --- 2. 内核配置 (Kernel Config) - 核心修正 ---
# 目标：MediaTek Filogic (MT7981)
# 关键点：ImmortalWrt 24.10 使用 Linux Kernel 6.6。原脚本指向 config-5.15 是错误的。
# 我们使用通配符 'config-*' 来匹配当前架构下的所有内核配置文件，确保万无一失。

KERNEL_CONFIG_PATH="target/linux/mediatek/filogic/config-*"

for config in $KERNEL_CONFIG_PATH; do
    echo "正在修补内核配置文件: $config"
    
    # 启用 BPF 子系统基础支持
    echo "CONFIG_BPF=y" >> "$config"
    echo "CONFIG_BPF_SYSCALL=y" >> "$config"
    
    # 启用 JIT 编译器 (性能关键)
    echo "CONFIG_BPF_JIT=y" >> "$config"
    
    # 启用 cgroup BPF 支持 (DAED 进程分流需要)
    echo "CONFIG_CGROUP_BPF=y" >> "$config"
    
    # 启用 XDP (极速数据包处理)
    echo "CONFIG_XDP_SOCKETS=y" >> "$config"
    
    # 启用流量控制分类器和动作 (TC BPF)
    echo "CONFIG_NET_CLS_BPF=y" >> "$config"
    echo "CONFIG_NET_ACT_BPF=y" >> "$config"
    
    # 启用 BPF 事件和头部信息 (调试与运行依赖)
    echo "CONFIG_BPF_EVENTS=y" >> "$config"
    echo "CONFIG_IKHEADERS=y" >> "$config"
    
    # 启用 BTF 调试信息 (CO-RE 关键依赖)
    # 没有这个，DAED 无法加载跨内核版本的 BPF 程序
    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    
    # 关闭模块签名强制检查 (允许加载非官方签名的内核模块)
    echo "CONFIG_MODULE_SIG=n" >> "$config"
done

# --- 3. 修复 Aurora 主题的构建问题 ---
# Cudy TR3000 构建环境中 npm install 可能会因 peer 依赖冲突报错
# 强制使用旧版依赖解析策略
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# --- 4. 系统初始化定制 (UCI Defaults) ---
# 创建一个在首次启动时运行的脚本，用于配置 ZRAM 和 主题。
# 这种方法比直接修改文件更安全，且能覆盖默认值。

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF

uci set system.@system.zram_size_mb='96'
uci set system.@system.zram_comp_algo='zstd'
uci set system.@system.zram_priority='100'
uci commit system
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap
uci commit luci

sysctl -w net.ipv4.tcp_rmem='4096 87380 4194304'
sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304'

exit 0
EOF

# 赋予脚本执行权限
chmod +x files/etc/uci-defaults/99-custom-settings
