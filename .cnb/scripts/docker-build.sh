#!/usr/bin/env bash
# CNB 流水线用的镜像构建脚本
#
# 用法：docker-build.sh <resolve-tag | from-tag | build | push | release>
# 由 .cnb.yml 调用，也可在云原生开发环境里手动执行同一条命令。
#   resolve-tag  auto_tag / web_trigger_release 管线：按 CalVer 算下一版本，写状态文件
#   from-tag     tag_push 管线：以被推送的 tag（CNB_BRANCH）为唯一事实源，解析附注标记
#   build/push   本地单平台调试：build 构建、push 在 docker login 后推送
#   release      tag_push 管线：buildx 多平台一次构建并直接推送 manifest
#                （多平台镜像无法先 load 进本地再 push，只能构建推送一体）
#
# 可覆盖的环境变量：
#   IMAGE_REPO   制品路径，默认当前仓库路径（CNB_REPO_SLUG_LOWERCASE）
#   IMAGE_TAG    镜像 tag（resolve-tag 默认按 CalVer 算出；from-tag 从 CNB_BRANCH 解析）
#   BASE_VERSION 手动指定基准版本（如 2026.39），取该「年.周」里下一个 build 号
#   CONTEXT      构建上下文目录，默认 docker
#   DOCKERFILE   Dockerfile 路径，默认 docker/Dockerfile
#   PLATFORMS    构建平台，逗号分隔，默认 linux/amd64,linux/arm64（release 用；build 仅单平台）
#   SKIP_BUILD   "true" 时 build/push/release 跳过（from-tag 按 tag 附注 cnb-image: skip 设置）
#   PUSH_LATEST  "false" 时不推 latest（from-tag 按附注 cnb-latest: skip 或非 CalVer tag 设置）
#   PUSH_IMAGE   "false" 时 push 只验证不推送（本地手动用；release 必须推送）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_REPO="${IMAGE_REPO:-${CNB_REPO_SLUG_LOWERCASE:?缺少 IMAGE_REPO 或 CNB_REPO_SLUG_LOWERCASE}}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
CONTEXT="${CONTEXT:-docker}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
PUSH_LATEST="${PUSH_LATEST:-true}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PLATFORMS="${PLATFORMS//[[:space:]]/}"  # 容错：剥掉平台列表里的空格
# 落盘共享：CNB 环境变量无法从子进程回传，后续 stage 靠这个文件拿到同一组值
STATE_FILE="${CNB_BUILD_WORKSPACE:-.}/.cnb-image.env"

# 由 IMAGE_TAG/IMAGE_REPO 推导其余引用（幂等，可重复调用）
derive_refs() {
  GIT_TAG="${GIT_TAG:-v${IMAGE_TAG}}"
  IMAGE="${CNB_DOCKER_REGISTRY:?缺少 CNB_DOCKER_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
  LATEST="${CNB_DOCKER_REGISTRY}/${IMAGE_REPO}:latest"
}

resolve_tag() {
  # 版本计算只发生在这里（打 tag 管线）；tag_push 场景走 from-tag，绝不重算 next
  IMAGE_TAG="${IMAGE_TAG:-$(bash "${SCRIPT_DIR}/calver.sh" next)}"
  derive_refs

  # 工作区必须干净：镜像打的是构建时的文件快照，而 tag 只记录提交。
  # 有未提交改动时两者内容不一致，tag 会指向与制品不符的代码
  if [ -n "$(git status --porcelain)" ]; then
    echo "工作区有未提交改动，产出的镜像与 tag 指向的提交不一致，已中止：" >&2
    git status --short >&2
    exit 1
  fi
  echo "版本：${GIT_TAG}（git tag） / ${IMAGE_TAG}（制品 tag）"
  echo "镜像：${IMAGE}"
  # exports 从 result 对象取值，故用 set-output 输出
  echo "##[set-output image_tag=${IMAGE_TAG}]"
  echo "##[set-output git_tag=${GIT_TAG}]"
  echo "##[set-output image_ref=${IMAGE}]"
  printf 'IMAGE_REPO=%s\nIMAGE_TAG=%s\nGIT_TAG=%s\nIMAGE=%s\n' \
    "$IMAGE_REPO" "$IMAGE_TAG" "$GIT_TAG" "$IMAGE" > "$STATE_FILE"
}

# tag_push 事件专用：以被推送的 tag 为唯一事实源解析构建参数。
# 「不打镜像 / 不打 latest」的开关只能随 tag 附注传递（推 tag 必触发 tag_push）
from_tag() {
  : "${CNB_BRANCH:?from-tag 需在 tag_push 事件下运行（CNB_BRANCH=tag 名）}"
  local tag="$CNB_BRANCH" msg="" image_marker="" latest_marker
  # tag 名会被拼进镜像引用，先收口字符集，防 `]` / 空格之类把 tag 参数顶出去
  if ! [[ "$tag" =~ ^v?[A-Za-z0-9._-]{1,100}$ ]]; then
    echo "错误：tag 名 ${tag} 含非法字符，拒绝构建" >&2
    exit 1
  fi

  # 浅克隆可能缺 tag ref，缺则带内联凭据补拉
  if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    git -c http.extraHeader="Authorization: Bearer ${CNB_TOKEN:?缺少 CNB_TOKEN}" \
      fetch --force origin "refs/tags/${tag}:refs/tags/${tag}" >/dev/null 2>&1 || true
  fi
  # 仅附注 tag（对象类型=tag）有 message；轻量 tag 无附注 → 全默认。
  # 必须先判别：%(contents) 对轻量 tag 返回的是 commit message，不判别会误读提交信息里的同型行
  if [ "$(git cat-file -t "refs/tags/${tag}" 2>/dev/null || true)" = "tag" ]; then
    msg="$(git tag -l --format='%(contents)' "$tag")"
  fi
  # 每个标记取最后一个（tail -1）。两条硬约束：
  #   - 用 sed 而非 `grep | awk`：管道里的 awk 是外部程序，tag 附注里的 `- 提交：$CNB_COMMIT`
  #     会被 $CNB_COMMIT 直接插值展开（$CNB_COMMIT 在 fork 的仓库里可控），内容里带换行 + 标记样
  #     的行即可伪造 cnb-image: skip 静默跳过发布；sed 是 shell 内建替换，不二次展开
  #   - 允许前导空白：`  cnb-image: skip` 在 markdown 里被渲染成代码块，人眼很像正文，故一并认
  #     （白名单只剩 build/skip、push/skip，放宽前导空白不会引入歧义）
  # stdout 只留结果供 $( ) 取值，不能有别的输出
  image_marker="$(printf '%s\n' "$msg" | sed -nE 's/^[[:space:]]*cnb-image:[[:space:]]*(build|skip)[[:space:]]*$/\1/p' | tail -1)"
  latest_marker="$(printf '%s\n' "$msg" | sed -nE 's/^[[:space:]]*cnb-latest:[[:space:]]*(push|skip)[[:space:]]*$/\1/p' | tail -1)"
  if [ "$image_marker" = "skip" ];  then SKIP_BUILD=true;  fi
  if [ "$latest_marker" = "skip" ]; then PUSH_LATEST=false; fi

  # 镜像 tag = tag 名去 v（仅 v+数字 开头才去，防 version-x 之类被误剥）
  if [[ "$tag" =~ ^v[0-9] ]]; then IMAGE_TAG="${tag#v}"; else IMAGE_TAG="$tag"; fi
  # latest 只跟随 CalVer 发布；非 CalVer tag 仍构建出版本 tag（可端到端演练），但不碰 latest
  if ! [[ "$tag" =~ ^v[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]]; then
    PUSH_LATEST=false
    echo "注意：${tag} 非 CalVer 格式，仅推送版本 tag，不更新 latest"
  fi
  derive_refs

  echo "版本：${tag}（git tag）/ ${IMAGE_TAG}（制品 tag）"
  echo "决策：构建=$( [ "$SKIP_BUILD" = true ] && echo skip || echo build )，latest=$( [ "$PUSH_LATEST" = true ] && echo push || echo skip )"
  echo "##[set-output image_tag=${IMAGE_TAG}]"
  echo "##[set-output skip_build=${SKIP_BUILD}]"
  echo "##[set-output push_latest=${PUSH_LATEST}]"
  printf 'IMAGE_REPO=%s\nIMAGE_TAG=%s\nGIT_TAG=%s\nIMAGE=%s\nSKIP_BUILD=%s\nPUSH_LATEST=%s\n' \
    "$IMAGE_REPO" "$IMAGE_TAG" "$GIT_TAG" "$IMAGE" "$SKIP_BUILD" "$PUSH_LATEST" > "$STATE_FILE"
}

load_state() {
  # 状态文件可选：from-tag/resolve-tag 会写；本地手动可用环境变量替代
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  : "${IMAGE_TAG:?缺少 IMAGE_TAG（先跑 resolve-tag/from-tag，或导出 IMAGE_TAG）}"
  derive_refs
}

build_image() {
  if [ "$SKIP_BUILD" = "true" ]; then
    echo "SKIP_BUILD=true（tag 附注 cnb-image: skip）：跳过构建"
    return 0
  fi
  if [[ "$PLATFORMS" == *","* ]]; then
    echo "build 仅支持单平台（PLATFORMS=${PLATFORMS}）；多平台构建请用 release" >&2
    exit 2
  fi
  echo "构建 ${IMAGE}"
  # --provenance=false 避免导出 attestation manifest list（部分 registry 拉取不兼容）
  docker build \
    --platform "$PLATFORMS" \
    --provenance=false \
    -f "$DOCKERFILE" \
    -t "$IMAGE" \
    "$CONTEXT"
}

push_image() {
  if [ "$SKIP_BUILD" = "true" ]; then
    echo "SKIP_BUILD=true（tag 附注 cnb-image: skip）：跳过推送"
    return 0
  fi
  if [ "$PUSH_IMAGE" != "true" ]; then
    echo "PUSH_IMAGE=${PUSH_IMAGE}：仅验证构建，跳过推送"
    return 0
  fi
  docker push "$IMAGE"
  if [ "$PUSH_LATEST" = "true" ]; then
    docker tag "$IMAGE" "$LATEST"
    docker push "$LATEST"
    echo "已推送：${IMAGE} 与 ${LATEST}"
  else
    echo "PUSH_LATEST=false：仅推送版本 tag，不更新 latest"
  fi
}

# ---- release：多平台一次构建并推送（tag_push 管线用）----

# 多平台需 docker-container 驱动的 builder（内置 docker 驱动导出不了多平台 manifest）
ensure_builder() {
  docker buildx version >/dev/null 2>&1 || {
    echo "错误：docker buildx 不可用，多平台构建无法进行" >&2
    exit 1
  }
  if ! docker buildx inspect vpn-builder >/dev/null 2>&1; then
    echo "创建多平台 builder：vpn-builder"
    docker buildx create --name vpn-builder --driver docker-container --use
  else
    docker buildx use vpn-builder
  fi
}

# amd64 节点交叉构建 arm64 层需 binfmt/qemu 模拟器（Docker Desktop 等已内置则跳过）
setup_qemu() {
  if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then return 0; fi
  echo "注册 qemu-aarch64 binfmt 模拟器（交叉构建 arm64 层需要）"
  # 安装失败不在此处中断：节点若已自带模拟可继续；真缺模拟时 buildx 会以明确报错暴露
  if ! docker run --privileged --rm tonistiigi/binfmt --install arm64; then
    echo "警告：binfmt 安装失败；arm64 层若报 exec format error，请检查节点模拟支持" >&2
  fi
}

release() {
  if [ "$SKIP_BUILD" = "true" ]; then
    echo "SKIP_BUILD=true（tag 附注 cnb-image: skip）：跳过构建与推送"
    return 0
  fi
  if [ "$PUSH_IMAGE" != "true" ]; then
    echo "release 必须推送（PUSH_IMAGE=${PUSH_IMAGE}）；仅本地构建请用 build" >&2
    exit 1
  fi
  setup_qemu
  ensure_builder
  local tags=(-t "$IMAGE")
  if [ "$PUSH_LATEST" = "true" ]; then tags+=(-t "$LATEST"); fi
  echo "构建并推送：${PLATFORMS} → ${IMAGE}"
  docker buildx build \
    --platform "$PLATFORMS" \
    --provenance=false \
    -f "$DOCKERFILE" \
    "${tags[@]}" \
    --push \
    "$CONTEXT"
  if [ "$PUSH_LATEST" = "true" ]; then
    echo "已推送：${IMAGE} 与 ${LATEST}（均为多平台 manifest）"
  else
    echo "PUSH_LATEST=false：仅推送版本 tag，不更新 latest"
  fi
}

case "${1:-}" in
  resolve-tag) resolve_tag ;;
  from-tag)    from_tag ;;
  build)   load_state; build_image ;;
  push)    load_state; push_image ;;
  release) load_state; release ;;
  *) echo "用法：$0 <resolve-tag | from-tag | build | push | release>" >&2; exit 2 ;;
esac
