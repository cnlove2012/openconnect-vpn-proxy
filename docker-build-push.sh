#!/usr/bin/env bash
# 本地构建并推送镜像到 Docker Hub，tag 与 CNB 流水线（v年.周.build → 年.周.build）保持一致
#
# 用法：
#   ./docker-build-push.sh                 # 用 git 最新 tag 构建并推送版本 tag + latest
#   ./docker-build-push.sh --check         # 只比对 git tag / Docker Hub tag，不构建
#   ./docker-build-push.sh --tag           # 同上（--check 的别名）
#   ./docker-build-push.sh --no-latest     # 只推版本 tag，不动 latest
#   ./docker-build-push.sh --tag v2026.45.2        # 用指定版本发布（git 还没有该 tag 时手动发版）
#   ./docker-build-push.sh --tag v2026.45.2 --check # 只比对该版本，不构建
#   ./docker-build-push.sh --base-version 2026.45  # 按这周自增：已有 2026.45.2 → 2026.45.3
#                      #（仅当 git 无 CalVer tag 且未用 --tag VER 时生效，否则提示被忽略）
#   ./docker-build-push.sh --platform linux/amd64 --yes
#
# 选项：
#   --tag [VER]        带 VER：本次发布/比对都用它当版本（再配 --check 则只比对不构建）；
#                     不带值：等同 --check
#   --latest           同时推送/更新 latest（默认行为，保留参数是为了显式表达意图）
#   --no-latest        不推 latest
#   --base-version W   版本按 W.build 自增（W = 年.周，如 2026.45）
#   --platform P       构建平台，默认 linux/amd64,linux/arm64（与 CNB 发布一致；本机单架构可用 --platform linux/amd64）
#   --repo R           镜像仓库，默认 cnlove2012/openconnect-vpn-proxy
#   --yes / -y         不交互确认，直接构建推送
#   -h / --help        帮助
#
# 凭据：脚本不管。默认本地已经 `docker login` 过（凭据由 docker 自己存在 ~/.docker/config.json），
#       脚本只做一次「有没有登录」的粗判，没有就提示先 docker login。
#       不读 DOCKERHUB_TOKEN 之类的令牌——一套令牌摊给所有 repo，换账号/换仓库都得改环境
#
# 版本语义（与 .cnb/scripts/calver.sh、docker-build.sh from-tag 严格对齐）：
#   git tag v2026.44.1  ⇄  镜像 tag 2026.44.1（去 v）；git 侧无 tag 时才用 年.周.build 自增
#   本脚本不生成新版本，只发布「git 已有的版本」——本地绝不擅自打 tag
#
# 本地运行脚本，直接用 bash（本地开发机必有）；CI 侧 .cnb/scripts/ 才必须 POSIX sh
# ——那边跑在 docker:28-cli（Alpine，无 bash）里，两边约束不同，别互相照搬
set -euo pipefail

REPO_DEFAULT="cnlove2012/openconnect-vpn-proxy"
DOCKERFILE="docker/Dockerfile"
CONTEXT="docker"

REPO="${REPO:-$REPO_DEFAULT}"
PLATFORM="linux/amd64,linux/arm64"
MODE="build"       # build | check
WANT_LATEST="true"
TAG_ARG=""
BASE_VERSION=""
ASSUME_YES="false"

die() { echo "错误：$*" >&2; exit 1; }

# 镜像 tag 会拼进镜像引用，先收口字符集，防空格/斜杠把参数顶出去
valid_tag() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]
}

usage() { sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)
      # 可选的版本值：下一个参数不以 - 开头才当成版本。
      # 带 VER 只把它当指定版本（模式不变，可发布也可配 --check 只比对）；
      # 不带值才是 --check 的别名——否则发布模式下无法手动指定版本
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then TAG_ARG="$2"; shift; else MODE="check"; fi
      ;;
    --check)        MODE="check" ;;
    --latest)       WANT_LATEST="true" ;;
    --no-latest)    WANT_LATEST="false" ;;
    --base-version) [ $# -gt 1 ] || die "--base-version 需要一个 年.周 参数"; BASE_VERSION="$2"; shift ;;
    --platform)     [ $# -gt 1 ] || die "--platform 需要一个平台参数"; PLATFORM="$2"; shift ;;
    --repo)         [ $# -gt 1 ] || die "--repo 需要一个镜像仓库参数"; REPO="$2"; shift ;;
    -y|--yes)       ASSUME_YES="true" ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

[ -f "$DOCKERFILE" ] || die "找不到 $DOCKERFILE，请在仓库根目录执行"

# ---- 版本解析 ----

# 版本合法性：年.周.build（周 1~53），与 calver.sh 的产出对齐；
# 比 from-tag 的 CalVer 判定（周仅查 1~2 位数字）更严，此处只影响提示文案
valid_calver() {
  [[ "$1" =~ ^[0-9]{4}\.([1-9]|[1-4][0-9]|5[0-3])\.[0-9]+$ ]]
}

# git 侧最新 tag（按 CalVer 数值排序，不按字面量；不 fetch，本地看不到远端新 tag 时会提示）。
# 调用方必须 `$(git_latest_tag || true)`：管道里 grep 无匹配返回 1，pipefail 下会把
# 「查出来是空」误判成执行失败，再被 set -e 放大成整个脚本退出
git_latest_tag() {
  git tag -l 'v*' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' \
    | awk -F. '{printf "%04d%03d%06d %s\n", $1, $2, $3, $0}' \
    | sort -n | tail -1 | cut -d' ' -f2
}

# Docker Hub 侧：拉取与解析分开——拉取失败（网络/仓库不可达）置 HUB_API_FAILED，
# 与「真的没有版本 tag」区分开。
# 注意 hub_fetch_tags 必须直接调用（不能包在 $() 里）：命令替换是子 shell，
# 函数内的全局赋值回不到父 shell
hub_fetch_tags() {
  HUB_API_FAILED="false"
  HUB_JSON="$(curl -fsS -m 20 "https://hub.docker.com/v2/repositories/${REPO}/tags/?page_size=100&ordering=last_updated" 2>/dev/null || true)"
  [ -n "$HUB_JSON" ] || HUB_API_FAILED="true"
}

# 从 HUB_JSON 解析最新正式版本 tag（排除 latest / rc / 杂牌）；无则输出空
hub_latest_tag() {
  printf '%s\n' "$HUB_JSON" \
    | tr '{},' '\n\n\n' \
    | sed -n 's/.*"name" *: *"\([^"]*\)".*/\1/p' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | awk -F. '{printf "%04d%03d%06d %s\n", $1, $2, $3, $0}' \
    | sort -n | tail -1 | cut -d' ' -f2
}

# 版本决策：--tag VER > git 最新 tag > --base-version 自增 > 当天年.周自增
resolve_version() {
  VERSION_FROM_GIT="false"
  WEEK_FALLBACK=""
  if [ -n "$TAG_ARG" ]; then
    VERSION="${TAG_ARG#v}"
  else
    VERSION="$(git_latest_tag || true)"
    if [ -n "$VERSION" ]; then VERSION_FROM_GIT="true"; fi
  fi
  if [ -z "$VERSION" ]; then
    WEEK="${BASE_VERSION:-$(date -u +%G.%V)}"
    [[ "$WEEK" =~ ^[0-9]{4}\.([1-9]|[1-4][0-9]|5[0-3])$ ]] \
      || die "--base-version=\"${WEEK}\" 不是 年.周 格式（如 2026.45）"
    # 与 calver.sh next 同算法：该「年.周」已有 git tag 的最大 build + 1
    LAST="$(git tag -l "v${WEEK}.*" | sed -n "s/^v${WEEK}\.\([0-9][0-9]*\)\$/\1/p" | sort -n | tail -1)"
    VERSION="${WEEK}.$(( ${LAST:-0} + 1 ))"
    WEEK_FALLBACK="${WEEK}"
  elif [ -n "$BASE_VERSION" ]; then
    # 显式传了 --base-version 却没轮到它：静默忽略会让用户以为发的是 W.x，实际是 git tag
    if [ -n "$TAG_ARG" ]; then
      echo "提示：--base-version=${BASE_VERSION} 被忽略——版本取手动指定的 --tag ${TAG_ARG}" >&2
    else
      echo "提示：--base-version=${BASE_VERSION} 被忽略——版本取 git 最新 tag v${VERSION}（与 CNB 同号优先）" >&2
    fi
    echo "      （--base-version 仅在 git 无 CalVer tag 且未用 --tag VER 指定时生效）" >&2
  fi
  valid_tag "$VERSION" || die "解析出的版本 \"${VERSION}\" 含非法字符（只允许字母数字 . _ -）"
  # 版本格式只提示不拦截：手推临时 tag 是本脚本的合理用法，只有比对时才在意 CalVer
  valid_calver "$VERSION" || echo "提示：${VERSION} 不是 年.周.build 的 CalVer 版本，CNB 侧不会有同名 tag" >&2
  GIT_TAG="v${VERSION}"
}

# ---- 一致性比对（--tag / --check 的唯一职责）----
# 参数 quiet：只打印结论（构建前复用，避免刷一屏）
check_tags() {
  echo "仓库：${REPO}"
  hub_fetch_tags
  # || true 同 git_latest_tag：grep 无匹配≠失败（pipefail 会误判）
  HUB_TAG="$(hub_latest_tag || true)"

  if [ -n "$WEEK_FALLBACK" ]; then
    echo "git 最新 tag： 本地无 tag  ⇒ 按 ${WEEK_FALLBACK} 自增为 ${VERSION}"
  else
    echo "git 最新 tag： ${VERSION:+v}${VERSION}  ⇒ 待发布镜像 tag ${VERSION}"
  fi
  if [ "$HUB_API_FAILED" = "true" ]; then
    # 查询失败不是「尚未发布」：照旧走发布没问题（比对只是信息），但不能给出误导性结论
    echo "Docker Hub：   查询失败（网络或仓库不可达）"
    echo "结论：跳过比对，不影响发布"
    return 0
  fi
  echo "Docker Hub：   ${HUB_TAG:-（无正式版本 tag，仅 latest 或仓库为空）}"
  if [ -z "$HUB_TAG" ]; then
    echo "结论：Docker Hub 上没有可比对的正式版本 tag，本地 ${VERSION} 尚未发布"
    echo "      → 运行 ./docker-build-push.sh 发布 ${VERSION}"
  elif [ "$VERSION" = "$HUB_TAG" ]; then
    echo "结论：一致 ✅ git 与 Docker Hub 都是 ${HUB_TAG}"
    # 本地 tag 可能落后于远端：「一致」有可能是没 fetch 到 CI 新打的 tag 的假一致。
    # 只在这里提示——「不一致」分支反正都要求先 fetch 看远端
    echo "提示：先 git fetch --tags --force 再比对一次，排除本地 tag 落后的假一致"
  else
    echo "结论：不一致 ⚠️  git=${VERSION} / Docker Hub=${HUB_TAG}"
    echo "      → 运行 ./docker-build-push.sh 补发 ${VERSION}（本地落后于 Hub），或先 git fetch --tags 看远端是否已有更新版本"
  fi
  return 0
}

# ---- 登录检查 / 构建 / 推送 ----

check_login() {
  case "$REPO" in
    */*) USER_NS="${REPO%%/*}" ;;
    *)   die "--repo 需形如 <用户名>/<镜像名>，当前为 ${REPO}" ;;
  esac
  CFG="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  # 只做「有没有凭据」的粗判：registry 段、credHelpers / credsStore 任一命中即放行，
  # 登的是不是这个 namespace 交给 push 的 401 兜底（config.json 里存的是 base64，比不可靠）
  if [ -f "$CFG" ] && grep -qE "index\.docker\.io|credHelpers|credsStore" "$CFG" 2>/dev/null; then
    return 0
  fi
  die "看起来还没有登录 Docker Hub。请先执行 \`docker login\`（或用 credential helper），再跑本脚本"
}

# 多平台产出 manifest list，本地镜像存储只装得下单平台，只能构建推送一体；
# 单平台时走经典 load + push，能顺便在本地留一份镜像
MULTI_PLATFORM="false"
case "$PLATFORM" in *,*) MULTI_PLATFORM="true" ;; esac

# 多平台需要 docker-container 驱动的 builder（默认 docker 驱动导不出 manifest）
ensure_builder() {
  if docker buildx create --name vpn-builder --driver docker-container --use >/dev/null 2>&1; then
    echo "已创建 buildx builder：vpn-builder"
  else
    docker buildx use vpn-builder 2>/dev/null || die "buildx builder vpn-builder 不可用，请检查 docker buildx ls"
  fi
}

# amd64 上交叉构建 arm64 层需要 qemu 模拟，缺了会报 exec format error
setup_qemu() {
  [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && return 0
  echo "注册 qemu-aarch64 binfmt 模拟器（构建 arm64 层需要）"
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null \
    || echo "警告：binfmt 注册失败，arm64 层可能报 exec format error" >&2
}

# 构建推送本体：tag 参数经数组传入（-t 后跟镜像引用，不含空格）
build_and_push() {
  docker buildx build --platform "$PLATFORM" "$@" "$CONTEXT"
}

build_image() {
  VERSION_REF="${REPO}:${VERSION}"
  LATEST_REF="${REPO}:latest"
  if [ "$WANT_LATEST" = "true" ]; then
    echo "构建并推送：${PLATFORM} → ${VERSION_REF} + ${LATEST_REF}"
  else
    echo "构建并推送：${PLATFORM} → ${VERSION_REF}（--no-latest，不动 latest）"
  fi
  # --provenance=false 与 CI 对齐：不导出 attestation，兼容老 registry/客户端拉取
  local tags=(--provenance=false -f "$DOCKERFILE" -t "$VERSION_REF")
  if [ "$WANT_LATEST" = "true" ]; then tags+=(-t "$LATEST_REF"); fi

  if [ "$MULTI_PLATFORM" = "true" ]; then
    docker buildx version >/dev/null 2>&1 || die "多平台构建需要 docker buildx（Docker Desktop 自带）"
    ensure_builder
    setup_qemu
    build_and_push "${tags[@]}" --push
    return 0
  fi
  # 单平台：load 到本地再 push，本地留一份镜像便于验证
  if docker buildx version >/dev/null 2>&1; then
    build_and_push "${tags[@]}" --load
  else
    docker build --platform "$PLATFORM" -f "$DOCKERFILE" -t "$VERSION_REF" "$CONTEXT"
    [ "$WANT_LATEST" = "true" ] && docker tag "$VERSION_REF" "$LATEST_REF"
  fi
  docker push "$VERSION_REF"
  if [ "$WANT_LATEST" = "true" ]; then docker push "$LATEST_REF"; fi
  if [ "$WANT_LATEST" = "true" ]; then
    echo "完成：${VERSION_REF} 与 ${LATEST_REF}"
  else
    echo "完成：${VERSION_REF}"
  fi
}

main() {
  command -v git >/dev/null 2>&1 || die "缺少 git"
  resolve_version
  if [ "$MODE" = "check" ]; then check_tags; return 0; fi

  command -v docker >/dev/null 2>&1 || die "缺少 docker"
  check_tags | sed -n "/^结论/p"
  check_login
  echo "即将构建并推送；分支=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?') 提交=$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  if [ "$ASSUME_YES" != "true" ]; then
    printf '继续？[y/N] '
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
  fi
  build_image
}

main
