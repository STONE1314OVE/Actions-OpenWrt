#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 升级 Go 编译器并彻底解除 GOTOOLCHAIN=local 限制
rm -rf feeds/packages/lang/golang
git clone --depth 1 https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
./scripts/feeds install -f -p packages golang

# 核心修复：将 golang 目录下所有配置中的 GOTOOLCHAIN=local 替换为 auto，允许自动拉取 go 1.27+
grep -rl "GOTOOLCHAIN=local" feeds/packages/lang/golang/ | xargs sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g'

# 2. 注入经过开机实测验证的安全内核配置 + Netkit 物理点火
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
    echo "CONFIG_IKHEADERS=y" >> "$config"
    echo "CONFIG_DEBUG_INFO_BTF=y" >> "$config"
    echo "CONFIG_MODULE_SIG=n" >> "$config"

    # 核心：Netkit 虚拟网络设备驱动 (BPF-programmable network device)
    echo "CONFIG_NETKIT=y" >> "$config"
done

# 3. 修复 Aurora 主题的构建冲突
sed -i 's/npm install/npm install --legacy-peer-deps/g' package/luci-theme-aurora/Makefile

# 4. 预置 luci-app-daede 的 rpcd 读写权限白名单（解决网页保存配置提示无权限）
mkdir -p files/usr/share/rpcd/acl.d
cat > files/usr/share/rpcd/acl.d/luci-app-daede-fix.json <<EOF
{
  "luci-app-daede": {
    "description": "Grant file access to dae config",
    "read": {
      "file": {
        "/etc/dae/*": [ "read" ]
      }
    },
    "write": {
      "file": {
        "/etc/dae/*": [ "write" ]
      }
    }
  }
}
EOF

# 5. 系统初始化定制 (UCI Defaults)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-settings <<EOF

# 内存 ZRAM 压缩配置 (256MB lz4 满血低延迟方案)
uci set system.@system[0].zram_size_mb='256'
uci set system.@system[0].zram_comp_algo='lz4'
uci set system.@system[0].zram_priority='100'
uci commit system

# 彻底关闭流量分载 (确保 dae 的 eBPF hook 不被硬件 NAT 旁路绕过)
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# Aurora 默认主题配置
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci set luci.main.resourcebase='/luci-static/resources'
uci set luci.themes.Aurora='/luci-static/aurora'
uci delete luci.themes.Bootstrap
uci commit luci

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
