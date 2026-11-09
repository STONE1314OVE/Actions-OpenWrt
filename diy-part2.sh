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
    
    # 清除会导致 kmod 模块被静态合并进内核而缺失 .ko 文件的旧配置
    sed -i '/CONFIG_NET_CLS_BPF=/d; /CONFIG_NET_ACT_BPF=/d; /CONFIG_NFT_QUEUE=/d; /CONFIG_NETFILTER_NETLINK_QUEUE=/d' "$config"

    # 1) 真实数据路径必需的 eBPF / TCX / Namespace 基础
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

    # 2) 原生 BTF 与 UDP 接收追踪 fentry/fexit 必需的 Dynamic Ftrace 支持
    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    echo "CONFIG_BPF_EVENTS=y" >> "$config"
    echo "CONFIG_FTRACE=y" >> "$config"
    echo "CONFIG_FUNCTION_TRACER=y" >> "$config"
    echo "CONFIG_DYNAMIC_FTRACE=y" >> "$config"
    echo "CONFIG_MODULE_SIG=n" >> "$config"
done

# 3. 强制锁定 Honk 依赖的四大 kmod 模块到 .config，确保生成 cls_bpf.ko 等模块文件
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

# 5. 使用 GitHub CLI 仅下载 aarch64_cortex-a53 架构的 honk 与 luci-app-honk，并拉取官方软件源脚本
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

# 6. 在 rootfs 阶段通过原生 apk + 数据库双保险机制安装 Honk 并注入软件源
cat << 'EOF' > honk_apks/install_honk.sh
#!/bin/sh
set -e
TOPDIR="$1"
TARGET_DIR="$2"
APK_BIN="$3"

echo ">>> 正在通过 APK 包管理器将 Honk 正式安装至 rootfs 数据库..."
mkdir -p "$TARGET_DIR/etc/apk"
echo "aarch64_cortex-a53" > "$TARGET_DIR/etc/apk/arch"

# 方式 A：显式指定目标架构 aarch64_cortex-a53 与本地 packages.adb 仓库进行安装（禁用 --force-broken-world 防止静默丢包）
LOCAL_ADB=$(find "$TOPDIR/staging_dir/packages" -name "packages.adb" | head -n 1)
REPO_ARG=""
[ -n "$LOCAL_ADB" ] && REPO_ARG="--repository file://$LOCAL_ADB"

"$APK_BIN" --root "$TARGET_DIR" --arch aarch64_cortex-a53 \
    --repositories-file /dev/null $REPO_ARG \
    --no-cache --no-logfile --preserve-env \
    add --no-scripts --allow-untrusted --force-overwrite \
    "$TOPDIR"/honk_apks/*.apk 2>&1 || true

# 方式 B（双保险兜底）：若因跨 SDK 依赖元数据差异导致离线 apk add 未写入，则直接解包并注册进 /lib/apk/db/installed
if ! grep -q "^P:honk$" "$TARGET_DIR/lib/apk/db/installed" 2>/dev/null; then
    echo ">>> 触发跨 SDK 兼容安装模式：正在解包并直接写入 /lib/apk/db/installed 数据库..."
    for pkg in "$TOPDIR"/honk_apks/*.apk; do
        TMP_DIR=$(mktemp -d)
        "$APK_BIN" extract --allow-untrusted --overwrite --destination "$TMP_DIR" "$pkg" 2>/dev/null || \
            (cd "$TMP_DIR" && "$APK_BIN" extract --allow-untrusted "$pkg")
        rm -f "$TMP_DIR/.PKGINFO" "$TMP_DIR"/.SIGN.* "$TMP_DIR"/.pre-* "$TMP_DIR"/.post-* "$TMP_DIR"/.trigger* 2>/dev/null || true
        cp -rf "$TMP_DIR"/. "$TARGET_DIR/"
        rm -rf "$TMP_DIR"
    done

    # 从文件名提取真实版本号（如 2026.11.08.4-r1）
    HONK_FILE=$(basename $(ls "$TOPDIR"/honk_apks/honk-[0-9]*.apk | head -n 1))
    HONK_VER=$(echo "$HONK_FILE" | sed -E 's/^honk-(.*)-aarch64_cortex-a53\.apk$/\1/')
    LUCI_FILE=$(basename $(ls "$TOPDIR"/honk_apks/luci-app-honk-*.apk | head -n 1))
    LUCI_VER=$(echo "$LUCI_FILE" | sed -E 's/^luci-app-honk-(.*)-aarch64_cortex-a53\.apk$/\1/')

    cat >> "$TARGET_DIR/lib/apk/db/installed" << DB_EOF

P:honk
V:${HONK_VER}
A:aarch64_cortex-a53
S:12250000
I:28500000
T:eBPF transparent proxy core (Honk)
U:https://github.com/kenzok8/openwrt-honk
L:GPL-3.0-only

P:luci-app-honk
V:${LUCI_VER}
A:aarch64_cortex-a53
S:1450000
I:3600000
T:LuCI management UI and Doona web assets for Honk
U:https://github.com/kenzok8/openwrt-honk
L:GPL-3.0-only

DB_EOF

    echo "honk" >> "$TARGET_DIR/lib/apk/db/world"
    echo "luci-app-honk" >> "$TARGET_DIR/lib/apk/db/world"
fi

echo ">>> 正在向 rootfs 注入 Honk 在线更新 APK 软件源与 ECDSA 验签公钥..."
mkdir -p "$TARGET_DIR/etc/apk/keys" "$TARGET_DIR/etc/apk/repositories.d"
if [ -f "$TOPDIR/files/usr/share/honk/openwrt-feed-setup.sh" ]; then
    SANDBOX_BIN=$(mktemp -d)
    cat << 'MOCK_UNAME' > "$SANDBOX_BIN/uname"
#!/bin/sh
if [ "$1" = "-r" ]; then echo "6.12.112"; elif [ "$1" = "-m" ]; then echo "aarch64"; else /bin/uname "$@"; fi
MOCK_UNAME
    cat << 'MOCK_APK' > "$SANDBOX_BIN/apk"
#!/bin/sh
exit 0
MOCK_APK
    chmod +x "$SANDBOX_BIN/uname" "$SANDBOX_BIN/apk"

    sed "s|/etc/|$TARGET_DIR/etc/|g" "$TOPDIR/files/usr/share/honk/openwrt-feed-setup.sh" > "$SANDBOX_BIN/setup_rootfs.sh"
    PATH="$SANDBOX_BIN:$PATH" sh "$SANDBOX_BIN/setup_rootfs.sh" 2>/dev/null || true
    rm -rf "$SANDBOX_BIN"
fi

chmod -R 755 "$TARGET_DIR/etc/init.d/honk" "$TARGET_DIR/usr/bin/honk"* "$TARGET_DIR/usr/share/honk" "$TARGET_DIR/usr/libexec/rpcd" 2>/dev/null || true

# 最终校验核心二进制与 APK 数据库记录
if ! grep -q "^P:honk$" "$TARGET_DIR/lib/apk/db/installed" || [ ! -f "$TARGET_DIR/usr/bin/honk-core" ]; then
    echo "❌ 错误：Honk 核心或数据库记录缺失，终止构建！"
    exit 1
fi
echo "✅ Honk (版本: $(grep -A1 '^P:honk$' "$TARGET_DIR/lib/apk/db/installed" | tail -n1 | cut -d: -f2)) 与在线更新源已成功写入 rootfs！"
EOF
chmod +x honk_apks/install_honk.sh

sed -i '/\$(call prepare_rootfs,\$(TARGET_DIR),\$(TOPDIR)\/files)/i \\t\$(TOPDIR)/honk_apks/install_honk.sh "\$(TOPDIR)" "\$(TARGET_DIR)" "\$(STAGING_DIR_HOST)/bin/apk"' package/Makefile

# 7. 系统初始化定制 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF
#!/bin/sh

# 1) 内存 ZRAM 压缩配置 (256MB lz4 满血低延迟方案)
uci set system.@system[0].zram_size_mb='256'
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_priority='100'
uci commit system

# 2) 彻底关闭流量分载 (确保 Honk 的 eBPF / TCX hook 不被硬件 NAT 旁路绕过)
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# 3) Aurora 默认主题配置
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap 2>/dev/null || true
uci commit luci

# 4) 确保 bpffs 挂载并主动加载 Honk 所需的内核模块 (cls_bpf / act_bpf / veth / nft_queue)
mkdir -p /sys/fs/bpf
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
for mod in cls_bpf act_bpf veth nfnetlink_queue nft_queue; do
    modprobe "\$mod" 2>/dev/null || true
done

# 5) 首次开机联网后后台自动同步一次 APK 软件源索引
if [ -x /usr/share/honk/openwrt-feed-setup.sh ]; then
    (sleep 20 && sh /usr/share/honk/openwrt-feed-setup.sh >/dev/null 2>&1) &
fi

# 6) 确保 Honk 权限与默认运行目录就绪，并清理 LuCI 缓存
mkdir -p /etc/honk /var/lib/honk
chmod 700 /etc/honk /var/lib/honk
chmod 755 /etc/init.d/honk /usr/bin/honk* /usr/share/honk/*.sh /usr/libexec/rpcd/* 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

# 7) 写入 sysctl.conf，确保每次重启 BBR 与网络调优永久生效
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
