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

# 添加所有修改
echo "👉 正在添加所有文件..."

sed "s|\(https://github.com\)|$GITHUB_MIRROR/\1|g" config.yml >| config-mirror.yml
sed "s|\(.*PProviders, url: \)'.*',|\1'https://your-subscribe-url',|g" config.yml | sed 's/^.*proxy-providers:.*$/#&/' | sed 's/^.*additional-prefix.*$/#&/' >| config-template.yml

sed "s|\(https://github.com\)|$GITHUB_MIRROR/\1|g" config-template.yml >| config-template-mirror.yml


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
