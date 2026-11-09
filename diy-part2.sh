#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 卸载 feeds 中可能存在的 dae / daed 冲突包
./scripts/feeds uninstall dae daed luci-app-dae luci-app-daed luci-app-daede 2>/dev/null || true

# 2. 注入安全内核配置 + Netkit 物理点火 + Honk 所需的 NFT_QUEUE 支持
KERNEL_CONFIG_PATH="target/linux/mediatek/filogic/config-*"

for config in $KERNEL_CONFIG_PATH; do
    [ -f "$config" ] || continue
    echo "正在修补内核配置文件: $config"
    
    # 稳定 eBPF/BTF 基础
    echo "CONFIG_BPF=y" >> "$config"
    echo "CONFIG_BPF_SYSCALL=y" >> "$config"
    echo "CONFIG_BPF_JIT=y" >> "$config"
    echo "CONFIG_CGROUP_BPF=y" >> "$config"
    echo "CONFIG_XDP_SOCKETS=y" >> "$config"
    echo "CONFIG_NET_CLS_BPF=y" >> "$config"
    echo "CONFIG_NET_ACT_BPF=y" >> "$config"
    echo "CONFIG_BPF_EVENTS=y" >> "$config"
    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    echo "CONFIG_MODULE_SIG=n" >> "$config"

    # 核心：Netkit 虚拟网络设备驱动与 nftables 队列支持（Honk 必备）
    echo "CONFIG_NETKIT=y" >> "$config"
    echo "CONFIG_NETFILTER_NETLINK_QUEUE=y" >> "$config"
    echo "CONFIG_NFT_QUEUE=y" >> "$config"
done

# 3. 修复 Aurora 主题的构建冲突
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# 4. 自动获取 kenzok8/openwrt-honk 最新 Release (aarch64_cortex-a53) 并预置进固件 files/
echo "=== 正在拉取最新 kenzok8/openwrt-honk (aarch64_cortex-a53) 软件包 ==="
mkdir -p /tmp/honk_extract files
HONK_URLS=$(curl -sL https://api.github.com/repos/kenzok8/openwrt-honk/releases/latest | grep browser_download_url | grep 'aarch64_cortex-a53\.apk"' | cut -d '"' -f 4)

for url in $HONK_URLS; do
    pkg_name=$(basename "$url")
    echo "下载并解包: $pkg_name"
    curl -fL "$url" -o "/tmp/honk_extract/$pkg_name"
    # 解压 APK 数据层到 files/ 目录，并清理 APK 元数据头
    tar -xzf "/tmp/honk_extract/$pkg_name" -C files/ 2>/dev/null || true
    rm -f files/.PKGINFO files/.SIGN.* files/.pre-* files/.post-* files/.trigger* 2>/dev/null || true
done
rm -rf /tmp/honk_extract

# 赋予 Honk 核心、服务脚本、RPCD 接口与维护脚本完整可执行权限
chmod -R 755 files/etc/init.d/honk files/usr/bin/honk* files/usr/share/honk files/usr/libexec/rpcd 2>/dev/null || true

# 5. 系统初始化定制 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF
#!/bin/sh

# 内存 ZRAM 压缩配置 (256MB lz4 满血低延迟方案)
uci set system.@system[0].zram_size_mb='256'
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_priority='100'
uci commit system

# 彻底关闭流量分载 (确保 Honk 的 eBPF hook 不被硬件 NAT 旁路绕过)
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# Aurora 默认主题配置
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap 2>/dev/null || true
uci commit luci

# 再次确保 Honk 维护脚本与核心具备可执行权限，并清理 LuCI 缓存
chmod 755 /etc/init.d/honk /usr/bin/honk-core /usr/share/honk/*.sh /usr/libexec/rpcd/* 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

# 写入 sysctl.conf，确保每次重启 BBR 与网络调优永久生效
cat >> /etc/sysctl.conf <<SYSCTL_EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 16384 4194304
SYSCTL_EOF

sysctl -p

exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-settings
