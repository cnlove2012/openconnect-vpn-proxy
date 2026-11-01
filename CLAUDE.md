# CLAUDE.md — openconnect-vpn-proxy

OpenConnect（Cisco AnyConnect 兼容）VPN 容器 + Tinyproxy HTTP 正向代理。业务背景、架构、用法见 `README.md`；Docker Hub 页面文案见 `DOCKERHUB-Repository-overview.md`。改 Dockerfile / openconnect.exp / entrypoint.sh 前先读 README 第 2 节（客户环境实测结论）。

## 仓库与分支

- 远程：`https://cnb.cool/cnlove2012/openconnect-vpn-proxy`（腾讯 CNB 平台，CI 也在这上面跑）
- `main`：稳定线，已推送远程；`feature/cnb-cicd`：CI/CD 工作流开发分支（原 `dev`，2026-11-01 改名），CNB 构建配置在此迭代
- 镜像发布目标：CNB 制品库 `docker.cnb.cool/cnlove2012/openconnect-vpn-proxy`（路径 = 仓库路径的同名制品）
- 凭据全部走 `.env`（已 ignore），仓库内不得出现真实网关域名、组名、账号密码

## CNB 云原生构建（feature/cnb-cicd 分支工作区）

### 配置文件清单（2026-11-01 重构后）

| 文件 | 职责 |
|---|---|
| `.cnb.yml` | 三条流水线：`main: auto_tag`（Tag 列表页按钮→打 CalVer tag）、`main: web_trigger_release`（main 详情页按钮→同前，stages 用 YAML 锚点与 auto_tag 共用）、`"v*": tag_push`（v 开头 tag 推送→多平台构建推镜像，**唯一构建入口**，runner 钉 `cnb:arch:amd64`，`docker.image` 钉 `docker:28-cli`——缺省镜像不保证带 buildx） |
| `.cnb/web_trigger.yml` | main 详情页「发布新版本」按钮：event=`web_trigger_release`、开关 `SKIP_IMAGE`/`NO_LATEST`（与 git-tag.sh 读的环境变量严格同名）、权限 owner/master |
| `.cnb/settings.yml` | 「push 到 main 自动打 Tag」开关（settings-tag.md，版本格式平台定）。**保留**（2026-11-01 用户裁决：避免平台侧麻烦、后续云原生开发用得上）；平台打的 tag 若 v 开头会经 `"v*"` 触发构建 |
| `.cnb/scripts/calver.sh` | CalVer 版本计算：`年.周.build`（ISO 周 `%G.%V`，UTC；`%G` 是 ISO 周基年，跨年周不能用 `%Y`），版本来源 git tag |
| `.cnb/scripts/docker-build.sh` | `resolve-tag \| from-tag \| build \| push \| release` 五段式；上下文 `docker/`；release 用 buildx 多平台（默认 `linux/amd64,linux/arm64`，`--provenance=false`，qemu 交叉构建）一次构建直接推 manifest；状态经 `${CNB_BUILD_WORKSPACE}/.cnb-image.env` 落盘跨 stage 共享 |
| `.cnb/scripts/git-tag.sh` | 把 CalVer 版本打成附注 tag 推送；附注末尾机器可读标记 `cnb-image:`/`cnb-latest:`（开关随 tag 传递）；已有 tag / 提交已被打 tag 时跳过；push 失败重查远端做并发兜底（绝不 force） |

### 版本与发布机制（2026-11-01 裁决，取代旧「已知不一致」段）

- **CalVer 唯一版本源**：git tag `v年.周.build`，镜像 tag 同号去 `v`；旧 git-auto-tag 插件（SemVer）方案已废弃移除
- **打标签与构建解耦**：auto_tag / web_trigger_release 只打 tag；镜像构建收敛在 `"v*": tag_push` 单一入口。**挂 `"v*"` glob 而非 `main`/`$` 的原因**（trigger-rule.md）：tag_push 按 tag 名匹配顶层 glob，`v2026.44.1` 匹配不到 `main`（挂 main 下永不触发）；`v*` 比 `$` 兜底更收敛——杂牌 tag 不跑构建，端到端演练也要用 v 开头的 tag
- **镜像为多平台 manifest**（linux/amd64 + linux/arm64）：先试平台自带的多架构能力（官方文档：`services: [docker]` 后直接 `docker buildx` 即可，无需额外配置），失败才自建 docker-container builder，全部失败才尝试注册 binfmt/qemu；多平台无法先 load 再 push，故 release 子命令构建推送一体；服务器是 Ubuntu x86_64，amd64 为主要消费方
- **「不打镜像/不打 latest」经 tag 附注传递**（推 tag 必触发 tag_push，意愿只能随 tag 走）：`cnb-image: skip` / `cnb-latest: skip`；轻量 tag（无附注）按默认 build+latest；非 CalVer tag 构建 `:tag名` 但不碰 latest
- **`.cnb/settings.yml` 保留**（2026-11-01 用户最终裁决）：它是「push 到 main 自动打 Tag」开关（settings-tag.md），版本格式平台定、与 CalVer 手动流程并存；后续云原生开发配置也用得上
- `web_trigger.yml` 的 `reg` 是**正则**；`.cnb.yml` 顶层分支键是 **glob**。两者语义不同，别混用
- 私有仓库下对 origin 的网络 git 操作（fetch/ls-remote/push）都要带 `-c http.extraHeader="Authorization: Bearer ${CNB_TOKEN}"` 内联凭据（不落盘）；裸调会以「Repository Not Found」形式失败

### CNB 平台要点（浓缩自官方文档，写配置时的硬规则）

- `.cnb.yml` 结构：顶层键 = 分支 glob（`main`、`"dev/*"`、`"**"`、`$` 兜底），二级键 = 事件（`push` / `tag_push` / `auto_tag` / `web_trigger_*`）。**分支的事件只看该分支自己的 `.cnb.yml`**；先 glob 后 `$`，多条 glob 命中则并行。
- `auto_tag` **必须挂在默认分支名下**（如 `main:`），配在 `$` 下会被忽略；仅 Tag 列表页「自动生成 Tag」按钮触发；自定义 stages 会取代默认 git-auto-tag 插件行为。
- `tag_push` / `push` 是**可信事件**：`CNB_TOKEN` 含 `registry-package:rw` + `repo-code:rw`，可推镜像、可推 tag。PR/评论类是不可信事件，制品库只读——推镜像只能放可信事件里。
- YAML 锚点 `&`/`*`/`<<:` 在**单个** .cnb.yml 内合法可用（include 跨文件不支持）；`runner: tags: cnb:arch:amd64` 可钉构建节点架构（见 docs build-node.md）。
- 制品库登录：`docker login ${CNB_DOCKER_REGISTRY} -u ${CNB_TOKEN_USER_NAME} -p ${CNB_TOKEN}`（用户名固定 `cnb`）；同名制品路径 = `${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}`。限制：单层 ≤64GB、≤64 层、需 Docker 20.10+。
- `web_trigger_*` 仅页面按钮触发；按钮 `description` 会成为流水线 title；`inputs` 可分组（`[{name, collapsed, inputs}]`），类型 `input/textarea/select/switch/radio`。
- 常用内置变量（全部只读）：`CNB_BRANCH`（分支或 Tag 名）、`CNB_COMMIT(_SHORT)`、`CNB_EVENT`、`CNB_DEFAULT_BRANCH`、`CNB_REPO_SLUG_LOWERCASE`、`CNB_REPO_URL_HTTPS`、`CNB_DOCKER_REGISTRY`、`CNB_TOKEN`、`CNB_TOKEN_USER_NAME`、`CNB_BUILD_WEB_URL`、`CNB_PIPELINE_KEY/STATUS`。
- `services: [docker]` 的 dind 已自动 `docker login` 到 `${CNB_DOCKER_REGISTRY}`，`.cnb.yml` 里的显式 `docker login` 是幂等兜底，不要删（手工在云原生开发里跑同一脚本要靠它）。
- tag 附注解析（`from-tag`）用 `sed` 而非 `grep | awk`：管道里的外部程序会把 `$` 再展开一次，而附注里就写着 `- 提交：${CNB_COMMIT}`——`CNB_COMMIT` 在 fork 出来的仓库里可控，提交内容带换行 + 标记样的一行就能伪造 `cnb-image: skip` 静默跳过发布。
- stage 间传值：`exports:` 从 stage 的 `exports`/`result` 对象取（脚本内用 `##[set-output k=v]` 输出）；CNB 环境变量无法从子进程回传，跨 stage 大块数据用落盘文件（见 docker-build.sh 的 `.cnb-image.env`）。

### 参考文档（markdown 直链，可整篇抓取）

- 语法手册：https://docs.cnb.cool/zh/build/grammar.md
- 触发规则（含 auto_tag）：https://docs.cnb.cool/zh/build/trigger-rule.md
- 手动触发按钮：https://docs.cnb.cool/zh/build/web-trigger.md
- Docker 制品库：https://docs.cnb.cool/zh/artifact/docker.md
- 内置环境变量：https://docs.cnb.cool/zh/build/build-in-env.md

## 本地开发

- 本地跑容器：`docker compose up -d vpn-proxy` → `docker attach vpn-proxy` 输入短信验证码 → `Ctrl+P`/`Ctrl+Q` 退出（`Ctrl+C` 会杀隧道）
- `calver.sh` 本地可直接执行（`CNB_BRANCH` 为空时自动跳过 fetch tags）：`bash .cnb/scripts/calver.sh next`
- 本地验多平台构建：起 `registry:2` 容器 + `docker buildx create --driver docker-container --config`（registry 配 http=true），再 `CNB_DOCKER_REGISTRY=host.docker.internal:5000 IMAGE_REPO=x IMAGE_TAG=y bash .cnb/scripts/docker-build.sh release`，`docker manifest inspect --insecure` 验双架构
- `.env.example` 是占位模板；真实 `.env` 永不入库
