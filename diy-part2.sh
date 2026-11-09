#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)
set -e

# 1. 卸载 feeds 中可能存在的 dae / daed 冲突包
./scripts/feeds uninstall dae daed luci-app-dae luci-app-daed luci-app-daede 2>/dev/null || true

# 2. 注入安全内核配置 + Netkit 物理点火 + Honk 所需的 NFT_QUEUE 支持
KERNEL_CONFIG_PATH="target/linux/mediatek/filogic/config-*"

for config in $KERNEL_CONFIG_PATH; do
    [ -f "$config" ] || continue
    echo "正在修补内核配置文件: $config"
    
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

    # Netkit 与 nftables 队列支持（Honk 必备）
    echo "CONFIG_NETKIT=y" >> "$config"
    echo "CONFIG_NETFILTER_NETLINK_QUEUE=y" >> "$config"
    echo "CONFIG_NFT_QUEUE=y" >> "$config"
done

# 3. 修复 Aurora 主题的构建冲突
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# 4. 使用 GitHub 官方 CLI 鉴权下载最新 kenzok8/openwrt-honk 软件包（防 403 限流）
echo "=== 正在从 kenzok8/openwrt-honk 下载最新 Release 安装包 ==="
rm -rf honk_apks
mkdir -p honk_apks files

gh release download -R kenzok8/openwrt-honk \
    --pattern "*aarch64_cortex-a53.apk" \
    --pattern "*luci-app-honk*.apk" \
    --dir honk_apks --clobber

echo "=== 已下载的 Honk 软件包列表 ==="
ls -lh honk_apks/*.apk

# 在 package/Makefile 的 rootfs-prepare 阶段挂载 OpenWrt 原生 APKv3 解包钩子并强校验
cat << 'EOF' > honk_apks/extract_honk.sh
#!/bin/sh
set -e
TOPDIR="$1"
APK_BIN="$2"
mkdir -p "$TOPDIR/files"
cd "$TOPDIR/files"
for pkg in "$TOPDIR"/honk_apks/*.apk; do
    echo ">>> 正在使用原生 apk 工具解包: $pkg"
    "$APK_BIN" extract --allow-untrusted "$pkg" || tar -xzf "$pkg" -C "$TOPDIR/files"
done
rm -f "$TOPDIR/files/.PKGINFO" "$TOPDIR/files"/.SIGN.* "$TOPDIR/files"/.pre-* "$TOPDIR/files"/.post-* "$TOPDIR/files"/.trigger* 2>/dev/null || true
chmod -R 755 "$TOPDIR/files/etc/init.d/honk" "$TOPDIR/files/usr/bin/honk"* "$TOPDIR/files/usr/share/honk" "$TOPDIR/files/usr/libexec/rpcd" 2>/dev/null || true

# 强制校验核心文件是否真正写入 files/，防止打出空壳固件
if [ ! -f "$TOPDIR/files/etc/init.d/honk" ] && [ ! -f "$TOPDIR/files/usr/bin/honk-core" ]; then
    echo "❌ 错误：Honk 核心文件未成功解包到 files/ 目录，终止构建！"
    exit 1
fi
echo "✅ Honk 与 Doona 资产已成功注入 rootfs！"
EOF
chmod +x honk_apks/extract_honk.sh

sed -i '/\$(call prepare_rootfs,\$(TARGET_DIR),\$(TOPDIR)\/files)/i \\t\$(TOPDIR)/honk_apks/extract_honk.sh "\$(TOPDIR)" "\$(STAGING_DIR_HOST)/bin/apk"' package/Makefile

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

# 确保 Honk 维护脚本与核心具备可执行权限，并清理 LuCI 缓存
chmod 755 /etc/init.d/honk /usr/bin/honk* /usr/share/honk/*.sh /usr/libexec/rpcd/* 2>/dev/null || true
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
