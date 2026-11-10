#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)
set -e

# 1. 卸载 feeds 中可能存在的 dae / daed 冲突包
./scripts/feeds uninstall dae daed luci-app-dae luci-app-daed luci-app-daede 2>/dev/null || true

# 2. 对齐 daeuniverse/honk 官方文档内核要求（保留 cls_bpf/nft_queue 为独立 .ko 模块）
KERNEL_CONFIG_PATH="target/linux/mediatek/filogic/config-*"

for config in $KERNEL_CONFIG_PATH; do
    [ -f "$config" ] || continue
    echo "正在修补内核配置文件: $config"
    
    sed -i '/CONFIG_NET_CLS_BPF=/d; /CONFIG_NET_ACT_BPF=/d; /CONFIG_NFT_QUEUE=/d; /CONFIG_NETFILTER_NETLINK_QUEUE=/d' "$config"

    echo "CONFIG_BPF=y" >> "$config"
    echo "CONFIG_BPF_SYSCALL=y" >> "$config"
    echo "CONFIG_BPF_JIT=y" >> "$config"
    echo "CONFIG_CGROUP_BPF=y" >> "$config"
    echo "CONFIG_NET_SCHED=y" >> "$config"
    echo "CONFIG_NET_CLS_ACT=y" >> "$config"
    echo "CONFIG_NET_XGRESS=y" >> "$config"
    echo "CONFIG_NET_NS=y" >> "$config"
    echo "CONFIG_NETKIT=y" >> "$config"
    echo "CONFIG_XDP_SOCKETS=y" >> "$config"

    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    echo "CONFIG_BPF_EVENTS=y" >> "$config"
    echo "CONFIG_FTRACE=y" >> "$config"
    echo "CONFIG_FUNCTION_TRACER=y" >> "$config"
    echo "CONFIG_DYNAMIC_FTRACE=y" >> "$config"
    echo "CONFIG_MODULE_SIG=n" >> "$config"
done

# 3. 强制锁定 Honk 依赖的四大 kmod 模块到 .config
cat >> .config << 'EOF'
CONFIG_KERNEL_NET_NS=y
CONFIG_KERNEL_FUNCTION_TRACER=y
CONFIG_KERNEL_DYNAMIC_FTRACE=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_cgi-io=y
CONFIG_PACKAGE_kmod-sched-core=y
CONFIG_PACKAGE_kmod-sched-bpf=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_kmod-nft-queue=y
EOF

# 4. 修复 Aurora 主题的构建冲突
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# 5. 下载 aarch64_cortex-a53 架构的 honk 与 luci-app-honk，并拉取官方软件源脚本
echo "=== 正在从 kenzok8/openwrt-honk 下载最新 Release 安装包与软件源脚本 ==="
rm -rf honk_apks
mkdir -p honk_apks files/usr/share/honk

gh release download -R kenzok8/openwrt-honk \
    --pattern "*aarch64_cortex-a53.apk" \
    --dir honk_apks --clobber

curl -fsSL https://down.dllkids.xyz/openwrt-feed/openwrt-feed-setup.sh -o files/usr/share/honk/openwrt-feed-setup.sh
chmod 755 files/usr/share/honk/openwrt-feed-setup.sh

echo "=== 已下载的 Honk 软件包列表 ==="
ls -lh honk_apks/*.apk

# 6. 在 rootfs 阶段构建本地 APKv3 索引并通过原生 apk add 正式安装
cat << 'EOF' > honk_apks/install_honk.sh
#!/bin/sh
set -e
TOPDIR="$1"
TARGET_DIR="$2"
APK_BIN="$3"

echo ">>> 正在生成 Honk 本地 APKv3 索引并执行原生安装..."
mkdir -p "$TARGET_DIR/etc/apk"
echo "aarch64_cortex-a53" > "$TARGET_DIR/etc/apk/arch"

# 为 honk_apks 生成标准 packages.adb 索引
"$APK_BIN" mkndx --allow-untrusted --output "$TOPDIR/honk_apks/packages.adb" "$TOPDIR"/honk_apks/*.apk

# 收集所有本地已编译包的 packages.adb 路径（严禁带 file:// 前缀）
REPO_ARGS="--repository $TOPDIR/honk_apks/packages.adb"
for adb in $(find "$TOPDIR/staging_dir/packages" "$TOPDIR/bin" -name "packages.adb" 2>/dev/null); do
    REPO_ARGS="$REPO_ARGS --repository $adb"
done

# 执行原生 apk add 写入完整的 C: 校验头与 installed 数据库
"$APK_BIN" --root "$TARGET_DIR" --arch aarch64_cortex-a53 \
    --repositories-file /dev/null $REPO_ARGS \
    --no-cache --no-logfile --preserve-env --allow-untrusted \
    add --no-scripts --force-overwrite honk luci-app-honk

echo ">>> 正在向 rootfs 注入 Honk 在线更新 APK 软件源与 ECDSA 验签公钥..."
mkdir -p "$TARGET_DIR/etc/apk/keys" "$TARGET_DIR/etc/apk/repositories.d"
curl -fsSL https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem \
    -o "$TARGET_DIR/etc/apk/keys/dllkids-feed.pub.pem"
echo "https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_cortex-a53/packages.adb" \
    > "$TARGET_DIR/etc/apk/repositories.d/dllkids.list"

chmod -R 755 "$TARGET_DIR/etc/init.d/honk" "$TARGET_DIR/usr/bin/honk"* "$TARGET_DIR/usr/share/honk" "$TARGET_DIR/usr/libexec/rpcd" 2>/dev/null || true

# 使用 apk info -e 真实校验包管理器识别状态
if ! "$APK_BIN" --root "$TARGET_DIR" info -e honk >/dev/null 2>&1 || \
   ! "$APK_BIN" --root "$TARGET_DIR" info -e luci-app-honk >/dev/null 2>&1; then
    echo "❌ 错误：APK 包管理器未能识别 honk 或 luci-app-honk 安装状态，终止构建！"
    exit 1
fi
echo "✅ APK 包管理器已正式识别: $("$APK_BIN" --root "$TARGET_DIR" list -I honk luci-app-honk)"
EOF
chmod +x honk_apks/install_honk.sh

sed -i '/\$(call prepare_rootfs,\$(TARGET_DIR),\$(TOPDIR)\/files)/i \\t\$(TOPDIR)/honk_apks/install_honk.sh "\$(TOPDIR)" "\$(TARGET_DIR)" "\$(STAGING_DIR_HOST)/bin/apk"' package/Makefile

# 7. 系统初始化定制 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF
#!/bin/sh

uci set system.@system[0].zram_size_mb='256'
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_priority='100'
uci commit system

uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap 2>/dev/null || true
uci commit luci

mkdir -p /sys/fs/bpf
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
for mod in cls_bpf act_bpf veth nfnetlink_queue nft_queue; do
    modprobe "\$mod" 2>/dev/null || true
done

mkdir -p /etc/honk /var/lib/honk
chmod 700 /etc/honk /var/lib/honk
chmod 755 /etc/init.d/honk /usr/bin/honk* /usr/share/honk/*.sh /usr/libexec/rpcd/* 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

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
