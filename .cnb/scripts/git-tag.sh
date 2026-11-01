#!/usr/bin/env bash
# CNB 流水线：把本次构建的 CalVer 版本打成 git tag 并推送到远端
#
# 用法：git-tag.sh
# 由 .cnb.yml 的「打 git tag」stage 调用，需先执行 docker-build.sh resolve-tag
# （版本号从 ${CNB_BUILD_WORKSPACE}/.cnb-image.env 读取，与镜像 tag 同源）
#
# 鉴权：用 CNB 内置临时令牌 CNB_TOKEN（用户名固定 cnb），
#       令牌权限来自触发事件；web_trigger / api_trigger 属可信事件，拥有代码读写权限
#
# 可覆盖的环境变量：
#   SKIP_IMAGE  "true" 时 tag 附注写入 cnb-image: skip（tag_push 管线据此跳过构建推送）；
#                仅手动场景使用（云原生开发/本地），发布按钮已不提供该开关
#   NO_LATEST   "true" 时 tag 附注写入 cnb-latest: skip（tag_push 管线据此不更新 latest）
#   （NO_LATEST 由 .cnb/web_trigger.yml 按钮注入；不传 = 默认 build+latest）
set -euo pipefail

STATE_FILE="${CNB_BUILD_WORKSPACE:-.}/.cnb-image.env"
[ -f "$STATE_FILE" ] || { echo "缺少 ${STATE_FILE}，请先执行 docker-build.sh resolve-tag" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE_FILE"

: "${CNB_TOKEN:?缺少 CNB_TOKEN，无法推送 tag}"
: "${CNB_REPO_URL_HTTPS:?缺少 CNB_REPO_URL_HTTPS}"
: "${GIT_TAG:?缺少 GIT_TAG}"
: "${CNB_PIPELINE_KEY:?缺少 CNB_PIPELINE_KEY}"

# 附注里的机器可读标记（tag_push 管线的 from-tag 解析；始终写入 = 自文档化）
IMAGE_MARKER="build"
LATEST_MARKER="push"
if [ "${SKIP_IMAGE:-false}" = "true" ]; then IMAGE_MARKER="skip"; fi
if [ "${NO_LATEST:-false}" = "true" ]; then LATEST_MARKER="skip"; fi

# 1. 版本号已存在（重跑旧构建 / 与手动打的 tag 撞号）时不覆盖，
#    已发布的 tag 必须不可变，否则版本号与镜像内容的对应关系会失真
#    （私有仓库裸 ls-remote 会失败，带内联凭据，与推送同款）
if git -c http.extraHeader="Authorization: Bearer ${CNB_TOKEN}" \
  ls-remote --tags origin "refs/tags/${GIT_TAG}" | grep -q "refs/tags/${GIT_TAG}$"; then
  echo "${GIT_TAG} 已存在，跳过（版本号不重复使用）"
  echo "##[set-output git_tag_created=false]"
  exit 0
fi

# 2. 本流水线不是「当前代码」唯一发布者：在自己打 tag 之前，
#    若目标提交已经被别的版本打上（CI 里可能有多条流水线并发），同样跳过
TAGGED="$(git for-each-ref --points-at "$CNB_COMMIT" --format='%(refname:short)' refs/tags 2>/dev/null || true)"
if [ -n "$TAGGED" ] && ! echo "$TAGGED" | grep -qx "$GIT_TAG"; then
  echo "提交 ${CNB_COMMIT_SHORT} 已有 tag：$(echo "$TAGGED" | tr '\n' ' ')"
  echo "跳过 ${GIT_TAG}，避免两个版本指向同一提交"
  echo "##[set-output git_tag_created=false]"
  exit 0
fi

# 3. 打附注 tag 并推送。message 里带上构建上下文，
#    方便在 Tag 列表页直接点回对应流水线；
#    末尾两行机器可读标记由 tag_push 管线的 from-tag 解析（开关随 tag 传递）
git config user.name "cnb"
git config user.email "cnb@cnb.cool"

git tag -a "$GIT_TAG" \
  -m "Release ${GIT_TAG}

- 制品：${IMAGE_REPO}:${IMAGE_TAG}
- 提交：${CNB_COMMIT}
- 触发事件：${CNB_EVENT}
- 流水线：${CNB_BUILD_WEB_URL}

cnb-image: ${IMAGE_MARKER}
cnb-latest: ${LATEST_MARKER}" \
  "$CNB_COMMIT"

# 通过内联凭据推送：不写 .git/config、不落盘令牌，避免污染工作区。
# 绝不 force；并发流水线抢先推了同号 tag 时（服务端原子裁决），
# 重查远端确认已存在则按幂等处理，其余失败原样退出
if ! git -c http.extraHeader="Authorization: Bearer ${CNB_TOKEN}" \
  push origin "refs/tags/${GIT_TAG}"; then
  if git -c http.extraHeader="Authorization: Bearer ${CNB_TOKEN}" \
    ls-remote --tags origin "refs/tags/${GIT_TAG}" | grep -q "refs/tags/${GIT_TAG}$"; then
    echo "${GIT_TAG} 已被并发流水线推送，按已存在处理"
    echo "##[set-output git_tag_created=false]"
    exit 0
  fi
  exit 1
fi

echo "已打 tag：${GIT_TAG} → ${CNB_COMMIT_SHORT}"
echo "##[set-output git_tag_created=true]"
