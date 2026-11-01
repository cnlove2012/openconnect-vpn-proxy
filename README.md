# OpenConnect 客户内网 VPN 代理

## 1. 项目背景与目标

客户测试环境的认证/业务服务部署在客户自己的内网中。我们的业务应用——PHP、Go、Java 或其他任意语言的 Docker 容器——需要访问客户内网 API，典型场景如刷新客户侧的 `auth_token`（以下统一称为客户 Token）。

客户员工通常通过 **Cisco Secure Client**（AnyConnect）连接内网；但业务容器里无法安装和管理客户指定的 VPN 客户端。因此，本项目使用 **OpenConnect + Docker** 建立 **Cisco AnyConnect** 兼容 VPN 连接，并在 VPN 容器内运行 **Tinyproxy**，向同网络的业务容器提供 HTTP/HTTPS 正向代理。

目标不是把整个测试服务器接入客户 VPN，而是让业务应用对指定客户内网 API 的 HTTP 请求显式使用代理：

```text
业务容器(PHP/Go/Java/...)  --HTTP proxy-->  Tinyproxy  --VPN/TUN-->  客户内网 API
```

这样可以把 VPN 接入能力作为独立基础设施容器运行。业务代码只需要在访问客户内网 API 时指定 `CUSTOMER_PROXY`，不需要在业务镜像内安装 OpenConnect，也不需要改变业务容器的默认路由。

> **范围说明**：本项目实现的是 HTTP/HTTPS 正向代理，不是通用 SOCKS 代理，也不会让测试服务器或所有容器的任意网络流量自动进入客户 VPN。它适合通过 HTTP/HTTPS API 刷新 Token 的场景。

## 2. 已验证的客户 VPN 参数与测试结论

以下信息来自当前客户环境的实际测试，其他 VPN 环境不能直接照搬：

| 项目 | 当前测试值 |
| --- | --- |
| VPN Gateway | `https://sslvpn.sankuai.com` |
| Group Alias | `duanxin` |
| Tunnel Group / Connection Profile 映射 | `DefaultWEBVPNGroup => duanxin` |
| 其他可选 Group | `common-vpn`、`dx-vpn`（客户提示不要选择 `dx-vpn`） |
| OpenConnect 认证方式 | 用户名 + 密码 + 手机短信 OTP |
| User-Agent | `AnyConnect Linux_64 5.1.2.42` |
| Version String | `5.1.2.42` |
| 数据通道 | 当前测试使用 SSL/CSTP；暂时关闭 DTLS |
| 已测试 OpenConnect 版本 | `OpenConnect version v9.12-3+deb13u2` |

### 2.1 为什么必须使用 `duanxin`

客户客户端可选列表中出现：

```text
GROUP: [common-vpn|duanxin|dx-vpn]:
```

另有映射信息：

```text
DefaultWEBVPNGroup => duanxin
```

`DefaultWEBVPNGroup` 是服务端 Connection Profile / Tunnel Group 的内部名称；`duanxin` 是客户端实际选择的 Group Alias。因此 OpenConnect 参数应使用：

```bash
--authgroup=duanxin
```

不要把 `DefaultWEBVPNGroup` 作为 `--authgroup` 值；客户端选择列表中并不存在这个值。也不要选择客户明确提示不要使用的 `dx-vpn`。

### 2.2 为什么需要设置 User-Agent 和版本号

在当前客户环境中，单独使用默认 OpenConnect 标识时，认证流程能够进入 SMS OTP 挑战，但最终未能登录。增加下面两个参数后，已经成功完成 OTP 认证并建立 CSTP/SSL 隧道：

```bash
--useragent="AnyConnect Linux_64 5.1.2.42"
--version-string="5.1.2.42"
```

这是当前环境实测有效的客户端兼容参数。它们设置客户端对网关报告的标识和版本，不等于实现 **Cisco Secure Client** 的设备合规检查或其他终端安全能力。使用前应符合客户 IT 的接入授权和安全要求。

### 2.3 OTP 的表单字段

本项目由 Expect 自动提交 `.env` 中的 VPN 密码，并把 OTP 提示交给操作者手动输入。

当前脚本 **不使用 `stty -echo`** 。在本项目的 Mac Docker Desktop、`docker attach` 和 Expect 组合中，关闭终端回显曾导致 OTP 输入/认证流程异常；因此保留已验证可用的终端输入方式。输入 OTP 时终端可能显示验证码，不要分享包含验证码的终端日志。

脚本按行读取输入，`string trim` 后原样提交，不强制六位数字格式（曾试过硬性 `[0-9]{6}` 匹配，同样因交互异常回退）。OTP 提示只匹配英文行 `Please input SMS Code:`——服务端会连发中英文两行，两行都匹配会把第二行误判为「验证码被再次要求」而直接退出。

### 2.4 初始 HTTP 404、DTLS 和 vhost-net 提示

测试中曾看到：

- 初始 `POST /` 返回 HTTP 404，随后 OpenConnect 继续请求 `/` 并收到 302，跳转到 `/+webvpn+/index.html`。单独的这个初始 404 不是 VPN 认证失败的判据，应继续看后续认证和 CSTP 结果。
- `Got CONNECT response: HTTP/1.1 200 OK`、`CSTP connected`、`Configured as <VPN-IP>` 是 VPN 隧道建立的重要成功标志。
- Mac Docker Desktop 下曾出现 `DTLS handshake failed`。本项目先使用 `--no-dtls`，走 SSL/CSTP 通道完成联调；这会放弃 DTLS/UDP 数据通道，性能可能低于 DTLS，但不影响当前 HTTP API POC 的目标。
- `Failed to open /dev/vhost-net` 与 `/dev/net/tun` 是不同设备。当前测试中它不是阻止 CSTP 隧道建立的错误，不要为了消除该提示而直接启用 `privileged: true`。

### 2.5 会话有效期

一次测试日志中，VPN 网关报告认证会话将在约 14 天后到期。该时间来自当次服务端响应，不应当作所有账号或所有会话固定不变的 SLA。会话到期或网关要求重新认证时，需要重新执行 VPN 登录并输入短信验证码。

## 3. 架构

### 3.1 单 Compose：业务容器与 VPN 代理在同一个 Docker 网络

> 本仓库的 `docker-compose.yaml` 只包含 `vpn-proxy` 服务；下图是目标形态——业务容器 `app`（任意语言）由业务侧项目提供，并加入同一个 Docker 网络。

```text
                         Docker Host (Linux test server)
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  app-net                 vpn-proxy-net                           │
│  ┌──────────────┐        ┌──────────────────────────────────┐     │
│  │              │        │                                  │     │
│  │     app      ├────────┤  vpn-proxy                        │     │
│  │              │  HTTP  │  ┌──────────────┐                  │     │
│  │ CUSTOMER_    │ proxy  │  │ Tinyproxy    │ :8888            │     │
│  │ PROXY         ├────────►  └──────┬───────┘                  │     │
│  └──────────────┘        │         │                          │     │
│                          │  ┌──────▼───────┐                  │     │
│                          │  │ OpenConnect  │                  │     │
│                          │  │ tun0         │                  │     │
│                          │  └──────┬───────┘                  │     │
│                          └─────────┼──────────────────────────┘     │
└────────────────────────────────────┼────────────────────────────────┘
                                     │ Cisco AnyConnect SSL/CSTP VPN
                                     ▼
                           客户 VPN Gateway
                                     │
                                     ▼
                           客户内网 API
```

关键原则：**业务容器与 VPN 代理必须加入同一个 Docker 用户自定义网络。业务容器通过 Docker DNS 和容器名访问代理，不走宿主机端口。**

容器内代理地址：

```text
http://vpn-proxy:8888
```

在 `vpn-proxy-net` 网络内，以下名字都能通过 Docker DNS 解析到代理容器，任选其一：

- `vpn-proxy`：容器名（`container_name`），同时是 Compose 服务名；
- `openconnect-vpn-proxy`：网络别名（`networks.vpn-proxy-net.aliases`）。

### 3.2 各组件职责

| 组件 | 职责 |
| --- | --- |
| `vpn-proxy` | 容器化运行 OpenConnect 与 Tinyproxy |
| OpenConnect | 连接客户 Cisco AnyConnect 兼容 VPN，创建 `tun0` 并配置路由 |
| Tinyproxy | 提供 HTTP/HTTPS 正向代理，监听容器内 `8888` |
| `app`（业务容器） | 任意语言的业务应用（PHP / Go / Java / …）：访问客户内网 API，并在请求级别指定代理 |
| `vpn-proxy-net` | 只连接需要访问 VPN 代理的业务容器 |
| `app-net` | 业务应用与其普通业务依赖使用的网络，可按现有项目扩展 |

## 4. 目录结构

```text
miaoti-vpn-proxy/
├── README.md
├── docker-compose.yaml
├── .env.example
├── .gitignore
├── docker-build-push.sh   # 本地构建并推送 Docker Hub（tag 与 CNB 一致）
└── docker/
    ├── Dockerfile
    ├── entrypoint.sh
    ├── openconnect.exp
    └── tinyproxy.conf
```

`docker/` 是 VPN 代理镜像的构建上下文。将 `vpn-proxy` 服务复制到其他 Compose 项目时，也需要把 `docker/` 目录复制过去，或者先构建并推送 `cnlove2012/openconnect-vpn-proxy` 镜像，再把 `build` 改为对应的 `image`。

## 5. 配置与启动

### 5.1 准备 `.env`

```bash
cp .env.example .env
chmod 600 .env
```

修改 `.env`：

```dotenv
VPN_GATEWAY=https://sslvpn.sankuai.com
VPN_USER=你的客户VPN用户名
VPN_PASSWORD='你的客户VPN密码'
VPN_AUTHGROUP=duanxin
VPN_USERAGENT=AnyConnect Linux_64 5.1.2.42
VPN_VERSION_STRING=5.1.2.42
VPN_RECONNECT_TIMEOUT=300
```

如果密码包含 `$`、`#` 等特殊字符，按 Docker Compose `.env` 文件规则处理；示例使用单引号包裹。不要把真实 `.env` 提交到 Git。

### 5.2 构建 VPN 代理镜像

```bash
docker compose build vpn-proxy
```

### 5.3 先启动 VPN 容器

建议先只启动 VPN，等人工认证成功后再启动业务应用：

```bash
docker compose up -d vpn-proxy
```

进入交互终端：

```bash
docker attach vpn-proxy
```

Expect 会自动提交 `.env` 中的 VPN 密码；看到短信验证码提示后，在终端输入手机上的六位验证码。

> **attach 后没有任何输出（黑屏）不代表启动失败**。`up -d` 是后台启动，密码提交、OTP 提示这些输出可能在执行 `docker attach` 之前就已经打印；attach 只显示之后的新输出，不会回放历史。此时容器大概率正在等你输入验证码——直接输入手机上的六位验证码回车即可。
>
> 不确定容器当前处于什么状态时，先看已产生的日志再操作：
>
> ```bash
> docker logs vpn-proxy
> ```
>
> 日志里出现 `Please input SMS Code:` 说明正在等验证码（attach 后直接输入即可）；日志里是报错才是真的启动失败。

认证成功时重点观察：

```text
Got CONNECT response: HTTP/1.1 200 OK
CSTP connected
Configured as <VPN-IP>
```

成功后使用 Docker detach 快捷键退出终端，不要终止容器：

```text
Ctrl + P，然后 Ctrl + Q
```

不要使用 `Ctrl+C` 作为 detach 操作。

### 5.4 验证 VPN 状态

```bash
# 容器状态
docker compose ps

# VPN TUN 地址
docker exec vpn-proxy ip -4 addr show tun0

# 路由表
docker exec vpn-proxy ip route

# 检查某个客户内网 IP 的路由出口
docker exec vpn-proxy ip route get <客户内网IP>

# 从 VPN 容器 ping 客户内网目标（镜像已安装 iputils-ping）
docker exec vpn-proxy ping -c 3 <客户内网IP>

# Tinyproxy 监听端口
docker exec vpn-proxy ss -lnt

# Tinyproxy 请求日志
docker exec vpn-proxy tail -f /tmp/tinyproxy.log
```

Compose healthcheck 只检查 `tun0` 是否获得 IPv4 地址，不代表客户 API、端口或 DNS 一定可达。

### 5.5 启动业务应用（业务侧项目）

VPN 认证成功后，在 **业务应用所在的 Compose 项目**中启动（本仓库的 compose 文件里没有业务服务，`docker compose up -d <业务服务名>` 在本仓库目录下执行会报「no such service」）：

```bash
# 在业务侧 Compose 项目目录执行
docker compose up -d <业务服务名>
```

业务容器需要注入：

```text
CUSTOMER_PROXY=http://vpn-proxy:8888
```

## 6. Compose 关键配置

项目根目录的 `docker-compose.yaml` **只包含 `vpn-proxy` 一个服务**；业务服务在业务侧项目中配置（见第 9、10 节）。关键配置如下：

```yaml
services:
  vpn-proxy:
    image: cnlove2012/openconnect-vpn-proxy:latest
    build:
      context: ./docker
      dockerfile: Dockerfile
    container_name: vpn-proxy
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    stdin_open: true
    tty: true
    init: true
    stop_grace_period: 15s
    restart: "no"
    environment:
      VPN_GATEWAY: ${VPN_GATEWAY:-https://sslvpn.sankuai.com}
      VPN_USER: ${VPN_USER:?Set VPN_USER in .env}
      VPN_PASSWORD: ${VPN_PASSWORD:?Set VPN_PASSWORD in .env}
      VPN_AUTHGROUP: ${VPN_AUTHGROUP:-duanxin}
      VPN_USERAGENT: ${VPN_USERAGENT:-AnyConnect Linux_64 5.1.2.42}
      VPN_VERSION_STRING: ${VPN_VERSION_STRING:-5.1.2.42}
      VPN_RECONNECT_TIMEOUT: ${VPN_RECONNECT_TIMEOUT:-300}
    # 本机 curl 测试时保留。
    ports:
      - "127.0.0.1:8888:8888"
    networks:
      vpn-proxy-net:
        aliases:
          - openconnect-vpn-proxy
    # 仅检查 tun0 是否获得 IPv4，不证明客户 API/DNS 可达。
    healthcheck:
      test:
        - CMD-SHELL
        - ip -4 -o addr show dev tun0 2>/dev/null | grep -q 'inet '
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 20s

networks:
  vpn-proxy-net:
    driver: bridge
    name: vpn-proxy-net
  # 如果要加入别的网络/别的docker compose 里的网络
  # vpn-proxy-net:
  #   external: true
  #   name: <替换成要加入的网络的名称>
```

> 实际运行请使用仓库中的完整 `docker-compose.yaml`。

### Mac 与 Linux 的 ports 差异

- **Mac Docker Desktop 本机手动 curl**：保留 `127.0.0.1:8888:8888`，在 Mac 上访问 `http://127.0.0.1:8888`。
- **Linux 测试服务器**：删除整个 `ports:` 块。业务容器通过 `vpn-proxy-net` 使用 `http://vpn-proxy:8888`，不需要开放宿主机端口。
- 不要使用 `0.0.0.0:8888:8888` 或 `8888:8888` 将无认证代理公开到服务器网卡或公网。

## 7. 业务应用如何通过代理访问客户内网 API

以下以「刷新客户 Token」为典型场景，示例覆盖 PHP / Go / Java；其他语言同理，找到 HTTP 客户端的代理设置项即可。

### 7.1 推荐：只对客户域名的请求设置代理

不要给整个业务容器设置全局 `HTTP_PROXY` / `HTTPS_PROXY`，否则业务应用访问其他内部服务时也可能被导向客户 VPN。

推荐在调用客户内网 API 时通过 `CUSTOMER_PROXY` 显式指定代理（示例统一用这个变量名，业务侧可自行命名）。

### 7.2 PHP cURL 示例

以下示例展示代理的设置方法。`CUSTOMER_TOKEN_URL`、请求字段和响应字段必须按客户真实 API 文档替换；项目没有假设客户 Token 刷新的具体协议。

```php
<?php

function refreshCustomerToken(string $refreshToken): array
{
    $url = getenv('CUSTOMER_TOKEN_URL');
    $proxy = getenv('CUSTOMER_PROXY');

    if (!$url || !$proxy) {
        throw new RuntimeException('CUSTOMER_TOKEN_URL / CUSTOMER_PROXY is not configured');
    }

    // 示例请求体：按客户接口要求替换字段和格式。
    $payload = [
        'refresh_token' => $refreshToken,
    ];

    $ch = curl_init($url);
    if ($ch === false) {
        throw new RuntimeException('curl_init failed');
    }

    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => json_encode(
            $payload,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        ),
        CURLOPT_HTTPHEADER => [
            'Content-Type: application/json',
            'Accept: application/json',
        ],
        CURLOPT_PROXY => $proxy,
        CURLOPT_PROXYTYPE => CURLPROXY_HTTP,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 20,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);

    $body = curl_exec($ch);
    if ($body === false) {
        $error = curl_error($ch);
        curl_close($ch);
        throw new RuntimeException('Customer API request failed: ' . $error);
    }

    $statusCode = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($statusCode < 200 || $statusCode >= 300) {
        throw new RuntimeException('Customer API returned HTTP ' . $statusCode);
    }

    $data = json_decode($body, true);
    if (!is_array($data)) {
        throw new RuntimeException('Customer API returned invalid JSON');
    }

    // 按客户响应结构取新 access token / refresh token，并安全写回数据库。
    // 不要把完整 Token 写入日志。
    return $data;
}
```

关键是：

```php
CURLOPT_PROXY => getenv('CUSTOMER_PROXY'),
CURLOPT_PROXYTYPE => CURLPROXY_HTTP,
```

对于 HTTPS 目标，cURL 会通过 HTTP `CONNECT` 隧道建立 TLS 连接。不要因为代理地址是 `http://...:8888` 就把客户 API 的 HTTPS URL 改成 HTTP。客户内网使用私有 CA 时，应将客户 CA 加入容器信任链，不要长期关闭证书校验。

### 7.3 Guzzle 示例

如果 PHP 项目使用 Guzzle：

```php
$client = new \GuzzleHttp\Client([
    'proxy' => getenv('CUSTOMER_PROXY'),
    'timeout' => 20,
    'connect_timeout' => 5,
    'verify' => true,
]);

$response = $client->post(getenv('CUSTOMER_TOKEN_URL'), [
    'json' => [
        'refresh_token' => $refreshToken,
    ],
]);
```

请求格式仍需按客户 API 契约调整。

### 7.4 Go 示例

`net/http` 在 `http.Transport` 上指定代理（按 client 实例生效，不污染全局）：

```go
proxyURL, err := url.Parse(os.Getenv("CUSTOMER_PROXY"))
if err != nil {
    log.Fatal(err)
}

client := &http.Client{
    Transport: &http.Transport{
        Proxy: http.ProxyURL(proxyURL),
    },
    Timeout: 20 * time.Second,
}

resp, err := client.Post(os.Getenv("CUSTOMER_TOKEN_URL"),
    "application/json",
    strings.NewReader(`{"refresh_token":"..."}`))
```

不要用 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量 + `http.ProxyFromEnvironment` 的组合给整个进程开全局代理，原因同 7.1。

### 7.5 Java 示例

Java 11+ 自带的 `java.net.http.HttpClient`：

```java
// 代理地址来自 CUSTOMER_PROXY（示例按 vpn-proxy:8888 解析 host/port）
var client = HttpClient.newBuilder()
        .proxy(ProxySelector.of(new InetSocketAddress("vpn-proxy", 8888)))
        .connectTimeout(Duration.ofSeconds(5))
        .build();

var request = HttpRequest.newBuilder(URI.create(tokenUrl))
        .timeout(Duration.ofSeconds(20))
        .header("Content-Type", "application/json")
        .POST(HttpRequest.BodyPublishers.ofString("{\"refresh_token\":\"...\"}"))
        .build();

HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
```

如果项目还在用 Apache HttpClient 4.x/5.x，等价做法是设置 `HttpHost proxy = new HttpHost("vpn-proxy", 8888)` 与 `RequestConfig.Builder.setProxy(proxy)`。

### 7.6 Swoole 协程 HTTP Client 注意事项（PHP）

不同 Swoole 版本和客户端类的代理配置能力并不完全相同。若使用 `Swoole\\Coroutine\\Http\\Client`，必须先按项目实际 Swoole 版本核对 `http_proxy_host` / `http_proxy_port` 是否受支持，并在容器中实测；不要仅因为设置了环境变量 `CUSTOMER_PROXY` 就假设协程客户端会自动使用代理。

对当前 Demo，建议先用显式 `CURLOPT_PROXY` 的 PHP cURL 或经过验证的 Guzzle 配置跑通链路。

## 8. 业务容器内验证代理

先确认业务容器与代理容器在同一网络：

```bash
docker exec <业务容器> getent hosts vpn-proxy
```

从业务容器测试客户 API：

```bash
docker exec <业务容器> \
  curl -v \
  -x http://vpn-proxy:8888 \
  https://客户内网域名/health
```

如果业务镜像没有 `curl`，可以临时使用带 curl 的诊断容器，并将它接入同一个 Docker 网络；也可以直接在业务应用里跑一段代理请求测试代码（见第 7 节各语言示例）。

同时在代理容器观察 Tinyproxy 日志：

```bash
docker exec vpn-proxy tail -f /tmp/tinyproxy.log
```

排查判断：

- **Tinyproxy 日志没有请求**：业务容器到代理的网络/DNS/地址有问题；检查两个容器是否在同一 `vpn-proxy-net`、代理地址是否写成 `vpn-proxy:8888`。
- **日志有请求，但返回 502/超时**：业务容器已经到达代理，继续检查 VPN 是否已认证、客户目标路由、内部 DNS、目标端口和客户防火墙。
- **通过 IP 成功，域名失败**：检查客户 VPN 下发的内部 DNS。通过 HTTP 代理访问域名时，通常由代理端解析目标域名；不要在业务代码里提前将客户内网域名解析成错误的公网 IP。
- **HTTP CONNECT 成功但 TLS 失败**：检查目标服务证书链和客户内部 CA。

## 9. 两个 Compose 项目分开部署

如果 VPN 代理和业务应用不在同一个 Compose 项目中，需要预先建立一个共享 Docker 网络。

### 9.1 只创建一次共享网络

```bash
docker network create vpn-proxy-net
```

### 9.2 VPN 代理 Compose

VPN 代理服务连接外部网络，并添加 DNS alias：

```yaml
services:
  vpn-proxy:
    # 其余 build、cap_add、devices、environment 等配置与主 compose 相同
    container_name: vpn-proxy
    networks:
      vpn-proxy-net:
        aliases:
          - openconnect-vpn-proxy

networks:
  vpn-proxy-net:
    driver: bridge
    name: vpn-proxy-net
```

### 9.3 业务应用 Compose（示例）

```yaml
services:
  app:
    image: ${APP_IMAGE}
    environment:
      CUSTOMER_PROXY: http://vpn-proxy:8888
    networks:
      - default
      - vpn-proxy-net

networks:
  vpn-proxy-net:
    external: true
    name: vpn-proxy-net
```

分开 Compose 时，不能通过 `depends_on` 引用另一个 Compose 项目中的服务。业务应用需要对 VPN 尚未连接/代理暂不可用的情况做重试或明确报错。

## 10. 将 `vpn-proxy` 复制到 Linux 测试环境

实际接入现有测试环境时：

1. 将主 `compose.yaml` 中的 `vpn-proxy` 服务段复制到测试环境的 Compose 文件。
2. 同时复制 `docker/` 构建目录，或使用已构建并推送到镜像仓库的 `cnlove2012/openconnect-vpn-proxy` 镜像。
3. 将业务服务加入同一个 `vpn-proxy-net`。
4. 为业务服务设置 `CUSTOMER_PROXY=http://vpn-proxy:8888`。
5. Linux 测试服务器上删除 VPN 服务的 `ports:` 块，不发布 `8888` 到宿主机。
6. 设置服务器本地 `.env` 或 Docker Secrets，完成 VPN 用户名和密码配置。
7. 先启动并人工完成 VPN OTP 认证，再启动/调用需要访问客户内网的业务流程。

Linux 环境的 VPN 服务至少需要：

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
```

不建议使用 `privileged: true` 代替最小权限配置。

## 11. 启动顺序、可用性与重连

- `depends_on` 只保证服务启动顺序，不代表人工输入 OTP 已完成，也不代表 VPN 内网路由或客户 API 已经可用。
- 本项目建议先执行 `docker compose up -d vpn-proxy`，然后 `docker attach vpn-proxy` 完成认证，确认 TUN 与路由正常后再启动业务应用。
- `docker stop` 停止容器时，Compose（`init: true` + `stop_grace_period: 15s`）先把 SIGTERM 发给 PID 1；Expect 脚本里的 trap 会把信号转发给 OpenConnect 子进程并等待其退出，从而优雅拆除隧道，而不是硬杀进程留下半开连接。
- `--reconnect-timeout=300`（可用 `VPN_RECONNECT_TIMEOUT` 覆盖）用于 OpenConnect 进程存活期间尝试恢复短暂网络中断；不代表容器被删除或进程退出后可以免 OTP 恢复。
- VPN 会话过期、服务端撤销会话、容器重建或宿主机重启后，通常需要重新启动容器并输入密码及短信验证码。
- 业务侧访问客户内网 API 的逻辑（如 Token 刷新）应设置连接超时、总超时、有限次数重试和退避策略。VPN 不可用时应返回可观测的依赖故障，不要无限重试客户接口。

## 12. 常用命令

```bash
# 构建 VPN 代理镜像
docker compose build vpn-proxy

# 只启动 VPN 代理
docker compose up -d vpn-proxy

# 进入 OTP 交互
docker attach vpn-proxy

# 查看状态
docker compose ps

# 查看 OpenConnect / Tinyproxy 容器日志
docker logs -f vpn-proxy

# 查看 Tinyproxy 访问日志
docker exec vpn-proxy tail -f /tmp/tinyproxy.log

# 查看 TUN 和路由
docker exec vpn-proxy ip addr show tun0
docker exec vpn-proxy ip route

# VPN 认证成功后启动业务应用（在业务侧 Compose 项目执行）
docker compose up -d <业务服务名>

# 停止并删除容器（下次启动需要重新认证）
docker compose down
```

### 12.1 本地同步镜像到 Docker Hub

CNB 流水线发布的 tag 是 CalVer `v年.周.build`，镜像 tag 去 `v`。根目录 `docker-build-push.sh` 复用同一套版本规则，让本地推上去的镜像与 CNB 的 tag 对得上：

```bash
# 比对：git 最新 tag 与 Docker Hub 最新版本 tag（只读，不构建）
./docker-build-push.sh --tag

# 发布：按 git 最新 tag 构建并推送「版本 tag + latest」（默认 amd64+arm64）
./docker-build-push.sh

# 只推版本 tag，不动 latest
./docker-build-push.sh --no-latest

# 手动指定版本发布（git 还没有该 tag 时的临时发版）；只比对该版本则加 --check
./docker-build-push.sh --tag v2026.45.2
./docker-build-push.sh --tag v2026.45.2 --check

# 按某周自增（仅当 git 无任何 CalVer tag 时生效，否则会提示被忽略）
./docker-build-push.sh --base-version 2026.45

# 本机单架构、换个仓库、跳过确认
./docker-build-push.sh --platform linux/amd64 --repo yourname/openconnect-vpn-proxy --yes
```

规则要点：

- 版本默认取 **git 最新 tag**（`v2026.44.1` → 镜像 `2026.44.1`），与 CNB 完全同号；`--tag VER` 手动指定优先；本地没有 tag 时才按 `年.周.build` 自增（`--base-version` 只在这一档生效）。
- 本地 tag 可能落后于远端：比对前先 `git fetch --tags --force`，否则「一致」可能只是旧结论。
- 脚本**不替你打 git tag**，只发布「git 已有的版本」（`--tag VER` 指定的版本除外）；也不在多平台间拼装 manifest，而是像 CI 一样用 buildx 一次构建推送。
- 重推已有版本 tag 会**覆盖** Docker Hub 上的同名 tag——与 CNB 侧「版本号不重复使用」的不可变语义不同，本地通道是宽松语义，补发/纠错靠自己判断。
- `--tag` 读 Docker Hub 的公开 API，仓库不存在或只有 `latest` 时会明确说「无正式版本 tag」；网络查询失败时也会明确说「查询失败」，不与「尚未发布」混淆。
- 凭据不归脚本管：本地 `docker login` 一次即可（凭据由 docker 存在 `~/.docker/config.json`），脚本只粗判有没有登录，没有就提示先 login。不读任何令牌环境变量——谁登录就推谁的仓库，换账号只需重新 login。

## 13. 常见问题

### 13.1 `/dev/net/tun: no such file or directory`

检查 Docker 主机/Linux VM 是否提供 TUN 设备，以及 Compose 是否配置：

```yaml
devices:
  - /dev/net/tun:/dev/net/tun
cap_add:
  - NET_ADMIN
```

Mac Docker Desktop 运行在 Linux VM 中；Mac 主机本身有无 TUN 设备，不等于 Docker VM 一定已提供该设备。

### 13.2 `Login failed` 或输入 OTP 后退出

检查 VPN 用户名/密码、最新短信 OTP、Group Alias、User-Agent/版本字符串，以及客户 IT 对 OpenConnect 第三方兼容客户端的授权策略。当前环境已实测的组是 `duanxin`，不是内部名称 `DefaultWEBVPNGroup`。

### 13.3 `tinyproxy: Could not open file /dev/stdout: Permission denied`

Tinyproxy 会降权到 `nobody` 用户。当前配置将日志写入 `/tmp/tinyproxy.log`，避免进程降权后无法打开 `/dev/stdout`。

### 13.4 出现 `DTLS handshake failed`

当前为了先保证 CSTP/SSL 通道可用，使用 `--no-dtls`。待确认 Linux 测试环境的 UDP/DTLS 路径后，再决定是否移除该参数。

### 13.5 业务容器请求失败，但 Mac 上 curl 成功

Mac 的 `127.0.0.1:8888` 是宿主机发布端口；业务容器不能把自己的 `127.0.0.1` 当作代理地址。业务容器必须使用 Docker 网络地址：

```text
http://vpn-proxy:8888
```

同时确认业务容器和 VPN 代理加入了同一个 `vpn-proxy-net`。

### 13.6 Tinyproxy 日志有请求，但客户 API 超时

代理已经收到请求，继续排查 `tun0`、`ip route get <客户内网IP>`、客户 DNS、目标端口和防火墙 ACL。代理层能接收请求不等于客户服务一定允许访问。

## 14. 安全注意事项

- 仅在客户明确授权范围内使用 VPN 和访问客户内网。
- 代理不配置用户名/密码认证；安全边界依赖 Docker 网络。因此只将授权业务容器连接到 `vpn-proxy-net`。
- Linux 测试服务器不要将 Tinyproxy 端口发布到公网或 `0.0.0.0`。业务容器通过内部 Docker 网络访问即可。
- Mac 本机调试时只绑定 `127.0.0.1:8888`，不要改成 `0.0.0.0:8888`。
- `.env` 包含 VPN 用户名和密码，必须加入 `.gitignore` 并限制文件权限。Docker 管理员仍可能通过容器配置查看环境变量；生产环境优先采用 Docker Secrets 或受控凭据注入。
- 不要记录或分享密码、OTP、客户 API Token、会话凭证、认证请求/响应中的敏感字段。
- 不要将 `curl -k`、关闭 TLS 验证或 `privileged: true` 当作常规解决方案。
- 客户 VPN 客户端标识参数必须符合客户的接入授权；它们不能替代客户要求的设备合规检查。

---

**项目定位**：用于 Linux + Docker 测试环境中，通过 OpenConnect 建立客户授权的 Cisco AnyConnect 兼容 VPN，再由 Tinyproxy 向任意语言的业务容器（PHP / Go / Java 等）提供受控 HTTP/HTTPS 代理，以便访问客户内网 API。当前已完成认证和 CSTP/SSL 隧道验证；实际 Token API 的请求字段、响应结构和完整业务联调，应以客户接口文档及业务代码为准。
