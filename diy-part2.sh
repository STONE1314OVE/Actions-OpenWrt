#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 升级 Go 编译器至 1.26+ 分支 (dae 核心编译必备，解决 simd 报错)
rm -rf feeds/packages/lang/golang
git clone --depth 1 https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
./scripts/feeds install -f -p packages golang

# 2. 注入经过开机实测验证的安全内核配置（坚决不碰 KPROBES / TRACING）
KERNEL_CONFIG_PATH="target/linux/mediatek/filogic/config-*"

for config in $KERNEL_CONFIG_PATH; do
    [ -f "$config" ] || continue
    echo "正在修补内核配置文件: $config"
    
    # --- 原有验证通过的 eBPF/BTF 基础 ---
    echo "CONFIG_BPF=y" >> "$config"
    echo "CONFIG_BPF_SYSCALL=y" >> "$config"
    echo "CONFIG_BPF_JIT=y" >> "$config"
    echo "CONFIG_CGROUP_BPF=y" >> "$config"
    echo "CONFIG_XDP_SOCKETS=y" >> "$config"
    echo "CONFIG_NET_CLS_BPF=y" >> "$config"
    echo "CONFIG_NET_ACT_BPF=y" >> "$config"
    echo "CONFIG_BPF_EVENTS=y" >> "$config"
    echo "CONFIG_IKHEADERS=y" >> "$config"
    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    echo "CONFIG_MODULE_SIG=n" >> "$config"

    # --- 新增：Netkit 轻量虚拟网络驱动与套接字诊断支持 ---
    echo "CONFIG_NETKIT=y" >> "$config"
    echo "CONFIG_INET_DIAG=y" >> "$config"
    echo "CONFIG_INET_TCP_DIAG=y" >> "$config"
    echo "CONFIG_INET_UDP_DIAG=y" >> "$config"
    echo "CONFIG_XDP_SOCKETS_DIAG=y" >> "$config"

    # --- 新增：启用 TCP BBR 拥塞控制 ---
    echo "CONFIG_TCP_CONG_BBR=y" >> "$config"
    echo "CONFIG_DEFAULT_BBR=y" >> "$config"
    echo "CONFIG_DEFAULT_TCP_CONG=\"bbr\"" >> "$config"
done

# 3. 修复 Aurora 主题的构建冲突
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# 4. 系统初始化定制 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF

# 内存 ZRAM 压缩配置 (96MB zstd)
uci set system.@system.zram_size_mb='96'
uci set system.@system.zram_comp_algo='zstd'
uci set system.@system.zram_priority='100'
uci commit system

# Aurora 默认主题生效与清理 Bootstrap
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap
uci commit luci

# 网络缓冲区优化与 BBR 双重保险
sysctl -w net.ipv4.tcp_rmem='4096 87380 4194304'
sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304'
sysctl -w net.ipv4.tcp_congestion_control=bbr

exit 0
EOF

chmod +x files/etc/uci-defaults/99-custom-settings
