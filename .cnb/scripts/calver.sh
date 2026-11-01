#!/usr/bin/env bash
# CalVer 版本计算：年.周.build（ISO 周，UTC）
#
# 用法：
#   calver.sh next     基于已有 git tag 算出下一个版本 → 2026.39.1
#   calver.sh git-tag  同上，带 v 前缀（git 用）      → v2026.39.1
#
# 可用环境变量：
#   CALVER_PREFIX  tag 前缀，默认 v（仅 git-tag 模式生效）
#   BASE_VERSION   指定基准版本（手动构建时手填），build 号在该「年.周」里自增；
#                  不传则按当天「年.周」取已有 tag 的最大 build + 1
#
# 版本来源：git tag（CI 下先 fetch，见 fetch_tags），无需额外状态文件
set -euo pipefail

PREFIX="${CALVER_PREFIX:-v}"

# 构建机的克隆可能是浅克隆且不自动带 tag，CI 下按需补齐
# （CNB_BRANCH 非空即判定在流水线里，本地执行不打扰用户的 git 配置）
fetch_tags() {
  [ -n "${CNB_BRANCH:-}" ] || return 0
  # 私有仓库裸 fetch 会静默失败（build 号归 1），故同样带内联凭据，与 git-tag.sh 推送同款
  git -c http.extraHeader="Authorization: Bearer ${CNB_TOKEN:-}" \
    fetch --tags --force --quiet origin >/dev/null 2>&1 || \
    echo "警告：拉取远端 tag 失败，build 号可能从 1 重新开始" >&2
}

# 今日（UTC）的年.周，如 2026.44
# 用 %G（ISO 周基年）而非 %Y（日历年）：跨年周如 2027-01-01 属 ISO 2026-W53，
# %Y.%V 会错标成 2027.53
current_yyww() {
  date -u +%G.%V
}

# 列出 年.周（$1）下已发布的 build 号
builds_of() {
  local yyww="${1//./\\.}" tag
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^v${yyww}\.([0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done < <(git tag -l "v${1}.*")
}

latest_build() {
  builds_of "$1" | sort -n | tail -1
}

next_version() {
  fetch_tags
  # 指定基准版本时只自增 build 号：周号一旦发布过就固定，不跟着当天日期跑
  local yyww="${BASE_VERSION:-$(current_yyww)}"
  # BASE_VERSION 是手填值，脏输入（带空格、"v2026.44"、写成完整版本号）直接拦下：
  # 放过去会产出 "2026.44 .1" 这种镜像引用，报错要拖到 docker build 才出现
  if ! [[ "$yyww" =~ ^[0-9]{4}\.[0-9]{1,2}$ ]]; then
    echo "错误：BASE_VERSION=\"${yyww}\" 不是 年.周 格式（如 2026.44）" >&2
    exit 1
  fi
  echo "${yyww}.$(( $(latest_build "$yyww" || true) + 0 + 1 ))"
}

case "${1:-}" in
  next)    next_version ;;
  git-tag) echo "${PREFIX}$(next_version)" ;;
  *) echo "用法：$0 <next | git-tag>" >&2; exit 2 ;;
esac
