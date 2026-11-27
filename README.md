# netdata-manager

Netdata 父/子节点一键部署与管理脚本。

- 自动安装 Netdata 和 Tailscale
- 子节点通过 Tailscale 私有网络把数据推送到父节点，不对公网开放任何端口
- 父节点只监听 `127.0.0.1`（给 Cloudflare Tunnel 等反向代理用）和 Tailscale IP
- 部署后自动安装 `netdata-manager` 命令，方便日常管理

## 1. 部署父节点（只需一次）

```bash
curl -fsSL https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh | sudo bash -s -- parent
```

执行完会打印一条子节点加入命令。忘了的话，在父节点上执行：

```bash
sudo netdata-manager join-cmd
```

## 2. 添加新服务器（子节点）

在新服务器上粘贴父节点打印的命令，格式如下：

```bash
curl -fsSL https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh | sudo bash -s -- child --parent <父节点Tailscale IP> --key <API_KEY>
```

在末尾加上 `--ts-authkey tskey-auth-xxx`，就不用手动点链接登录 Tailscale 了。

## 日常管理

```bash
sudo netdata-manager status      # 状态 / 已连接的节点
sudo netdata-manager logs        # 推送(streaming)相关日志
sudo netdata-manager restart     # 重启 Netdata
sudo netdata-manager update      # 更新本脚本
sudo netdata-manager uninstall   # 卸载 Netdata
```

## 可选参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `--no-tailscale` | 不用 Tailscale，改用内网 IP（父节点需配合 `--bind-ip`） | 使用 Tailscale |
| `--bind-ip IP` | 父节点额外监听的 IP | 自动取 Tailscale IP |
| `--allow PATTERN` | 父节点允许接入的来源 | `100.*` |
| `--retention SIZE` | 父节点最详细数据层磁盘上限 | `1GiB` |
| `--ml on\|off` | 机器学习异常检测 | `off` |
| `--interval N` | 子节点采集间隔（秒） | `2` |
| `--ts-authkey KEY` | Tailscale 认证密钥 | 无 |

## 注意

- 脚本会覆盖 `netdata.conf` 和 `stream.conf`，覆盖前自动备份为 `*.bak.时间戳`。
- **API Key 和 Tailscale auth key 相当于密码，不要提交到本仓库，也不要公开发布。**
- 每台服务器加入 Tailscale 后，在 Tailscale 后台 Machines 页面点 **Disable key expiry**，否则 180 天后会断线。
