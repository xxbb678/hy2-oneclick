# Hysteria2 一键管理脚本 (UUID 版)

通用版 Hysteria2 服务端一键部署脚本，支持 Debian / Ubuntu / Alpine，自动识别网络环境（原生 IPv4 / 纯 IPv6 / WARP），使用 UUID 认证，自签证书并提取 pinSHA256 指纹。

## 一行安装

    bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xxbb678/hy2-oneclick@latest/hy2.sh)

> 注意：不要用 `@main` 地址，jsDelivr 对它的缓存会滞留旧版本。用 `@latest` 或固定 commit 版本号。

或下载后执行：

    curl -fsSL https://cdn.jsdelivr.net/gh/xxbb678/hy2-oneclick@latest/hy2.sh -o hy2.sh
    chmod +x hy2.sh && ./hy2.sh

## 功能

- UUID 认证：auth.type: userpass，配置写入 UUID: UUID，自动生成 UUID
- 网络环境自动识别：按网卡排除 WARP 与 docker/br-/veth 等虚拟网卡，正确判定原生 IPv4 / 纯 IPv6
- pinSHA256 证书指纹：多源提取（日志 + 证书实算），格式校验（64 位 base64/hex），原子写盘 + 600 权限
- 自签证书：hysteria cert 自动生成，SNI 伪装 www.bing.com
- 伪装站点：masquerade 反代到 https://www.bing.com
- 防火墙：自动放行 UDP 端口（ufw / firewalld）
- 交互菜单：安装 / 查看链接 / 改端口 / 重启 / 卸载

## 菜单

    [1] 安装 Hysteria2
    [2] 查看配置节点链接
    [3] 更改监听端口
    [4] 重启服务
    [5] 卸载 Hysteria2
    [0] 退出脚本

## 使用

    ./hy2.sh

安装时端口可直接回车，自动随机 10000-65535。

## 文件位置

- /etc/hysteria/config.yaml — 服务端配置
- /etc/hysteria/uuid.txt — 认证 UUID
- /etc/hysteria/pinsha256.txt — 证书指纹（600 权限）
- /etc/hysteria/server.crt / server.key — 自签证书
- /usr/local/bin/hysteria — 服务端二进制
- /etc/systemd/system/hysteria.service — systemd 服务（Debian/Ubuntu）
- /etc/init.d/hysteria — OpenRC 服务（Alpine）

## 环境要求

- root 权限
- Debian / Ubuntu（apt）或 Alpine（apk）
- 架构：x86_64 / aarch64

## 已验证

- Debian 11 x86_64，纯 IPv6 + docker0 + WARP 干扰网卡环境：网络识别正确排除干扰网卡、UUID 认证生效、pinSHA256 与证书实算指纹一致、安装/查看/卸载全链路正常
- Alpine 分支逻辑同源，未实机验证

## 注意事项

- 纯 IPv6 服务器的节点链接为 [IPv6] 形式，客户端需有 IPv6 出口才能连接
- 链接同时带 insecure=1 与 pinSHA256，部分客户端只认其中之一

## License

MIT