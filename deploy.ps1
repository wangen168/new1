# deploy.ps1 — 把 wq_repo 强推到已有仓库（会覆盖远端）
#
# 用法：
#   .\deploy.ps1 -RepoUrl https://github.com/wangen168/new.git
#   私有仓库需要带 token：
#   .\deploy.ps1 -RepoUrl https://<你的PAT>@github.com/wangen168/new.git
#
# ⚠️ 这是覆盖式推送（git push -f），远端原有的 loader.m / build-loader.yml 会被删除。

param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [string]$Branch = 'main',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

Write-Host "== 目标仓库: $RepoUrl" -ForegroundColor Cyan
Write-Host "== 分支: $Branch"

if (-not (Test-Path '.git')) {
    git init | Out-Null
    git checkout -b $Branch 2>$null | Out-Null
}

git add -A
if (git status --porcelain) {
    git commit -m 'wq build (overwrite)' | Out-Null
    Write-Host "已提交" -ForegroundColor Green
}

$remotes = git remote
if ($remotes -contains 'origin') { git remote set-url origin $RepoUrl }
else { git remote add origin $RepoUrl }

if ($DryRun) {
    Write-Host "DryRun：将执行 git push -f origin $Branch" -ForegroundColor Yellow
    git log --oneline -1
    exit 0
}

git push -f -u origin $Branch

Write-Host ""
Write-Host "推送完成。" -ForegroundColor Green
Write-Host "下一步：GitHub → Actions → build-wq-ipa → Run workflow"
Write-Host ""
Write-Host "注意：这次覆盖删掉了远端的 loader.m 与 build-loader.yml。" -ForegroundColor Yellow
Write-Host "如果想保留原来的 loader 构建，改用 wq_segment.m 的方式（见 PUSH.md 最后一节）。"
