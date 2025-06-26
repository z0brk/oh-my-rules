#!/bin/bash

set -e

GITHUB_MIRROR=https://gh-proxy.com

# 检查是否在 git 仓库中
if [ ! -d ".git" ]; then
  echo "错误：当前目录不是一个 Git 仓库。"
  exit 1
fi

# 获取当前分支名
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -z "$BRANCH" ]; then
  echo "错误：无法获取当前分支名称。"
  exit 1
fi

# 模板保留节点池名称，但不发布本地订阅链接或节点凭据。
echo "正在生成配置模板..."
GITHUB_MIRROR="$GITHUB_MIRROR" python3 - <<'PY'
import os
from pathlib import Path

source = Path('config.yml').read_text()
start = source.index('\nproxy-providers:\n') + 1
end = source.index('\n# 全局配置', start)
pools = ['默认节点池', '优质节点池', '流量节点池']
public = 'proxy-providers:\n' + ''.join(
    f'  {name}: {{type: inline, payload: [{{name: {name}未配置, type: reject}}]}}\n'
    for name in pools
)
template = source[:start] + public + source[end:]
mirror = os.environ['GITHUB_MIRROR'] + '/https://github.com'
def mirrored(text):
    return text.replace('https://github.com', mirror).replace(mirror + '/robots.txt', 'https://github.com/robots.txt')

Path('config-mirror.yml').write_text(mirrored(source))
Path('config-template.yml').write_text(template)
Path('config-template-mirror.yml').write_text(mirrored(template))
PY

# 本地验证只生成文件，不进入下面的提交、历史改写和推送流程。
if [ "${1:-}" = "--generate-only" ]; then
  exit 0
fi


# 创建新提交
COMMIT_MESSAGE="$(date +'%Y-%m-%d %H:%M:%S')"
echo "${COMMIT_MESSAGE}" >| commit.gitkeep
echo "👉 正在创建提交..."
git add .
git commit -m "$COMMIT_MESSAGE"

# 获取当前分支上的第一个 commit
FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD)

if [ "$(git log --oneline | wc -l)" -gt 1 ]; then
  echo "👉 正在合并所有提交为一个 commit..."
  git reset --soft $FIRST_COMMIT
  git commit --amend -m "$COMMIT_MESSAGE"
else
  echo "ℹ️ 只有一个提交，无需合并。"
fi

# 推送并强制覆盖远程
echo "👉 正在强制推送到远程分支..."
git push origin $BRANCH --force

echo "✅ 完成！远程分支 '$BRANCH' 现在只有一个 commit。"
