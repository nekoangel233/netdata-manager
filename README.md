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

想同时设置节点名称，在父节点上执行 `sudo netdata-manager join-cmd 名字`，打印出的命令会带上 `--name 名字`。

已经部署过的子节点再运行这条命令时，**不会重复安装**，只更新 API Key、父节点地址（以及 `--name` 指定的节点名称），然后重启 Netdata。想完整重新配置的话，在末尾加 `--full`。

## 更换 API Key

在父节点上执行：

```bash
sudo netdata-manager rotate-key
```

旧 Key 立即作废，所有子节点会断开。把打印出来的新加入命令在每台子节点上运行一次即可重新连上（只会更新 Key，不会重装）。

## 交互式菜单

部署完成后，直接运行（不带任何参数）就会打开菜单，父节点和子节点显示不同的选项：

```bash
sudo netdata-manager
```

还没部署的机器也可以直接用菜单部署：

```bash
curl -fsSL https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh | sudo bash
```

## 保存 Tailscale auth key（父节点）

```bash
sudo netdata-manager set-ts-key
```

粘贴 key（输入时不显示）后，会保存在父节点的 `/etc/netdata-manager.conf`（仅 root 可读）。之后 `join-cmd` 打印的加入命令会自动带上它，新服务器不用再手动登录 Tailscale。子节点不会保存这个 key。

Tailscale auth key 最长 90 天有效，过期后在 Tailscale 后台重新生成，再执行一次 `set-ts-key`。不想保存了就执行 `sudo netdata-manager clear-ts-key`。

## 隐私：禁用 Netdata Cloud

新部署的父节点和子节点会自动：

- 删除登录 Netdata Cloud 时留下的凭据（`claim.conf`、`cloud.d/`）
- 在 `cloud.d/cloud.conf` 里设置 `enabled = no`，以后误点 Sign in 也连不上
- 不使用 Netdata 的公共 registry（`registry.my-netdata.io`）

已经部署好的机器，在每台上执行一次：

```bash
sudo netdata-manager disable-cloud
```

Netdata Cloud 网站上之前的节点记录不会自动消失，需要登录 app.netdata.cloud 手动删除。

## 日常管理

```bash
sudo netdata-manager status      # 状态 / 已连接的节点
sudo netdata-manager join-cmd    # 父节点：打印子节点加入命令
sudo netdata-manager rotate-key  # 父节点：更换 API Key
sudo netdata-manager set-ts-key  # 父节点：保存 Tailscale auth key
sudo netdata-manager clear-ts-key # 父节点：删除保存的 Tailscale auth key
sudo netdata-manager disable-cloud # 断开并禁用 Netdata Cloud
sudo netdata-manager rename 新名字  # 修改节点在面板里显示的名称
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
| `--name NAME` | 部署时设置节点显示名称 | 系统主机名 |
| `--full` | 子节点已部署时也强制完整重新配置 | 只更新 Key |

## 注意

- 脚本会覆盖 `netdata.conf` 和 `stream.conf`，覆盖前自动备份为 `*.bak.时间戳`。
- **API Key 和 Tailscale auth key 相当于密码，不要提交到本仓库，也不要公开发布。** 保存了 Tailscale auth key 后，`join-cmd` 打印的命令里包含它，复制时注意别发到公开的地方。
- 每台服务器加入 Tailscale 后，在 Tailscale 后台 Machines 页面点 **Disable key expiry**，否则 180 天后会断线。
