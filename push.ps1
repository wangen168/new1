# push.ps1 — 把当前目录推成一个新的 GitHub 私有仓库
#
# 用法（在本目录下执行）：
#   .\push.ps1 -RepoUrl https://github.com/<你的账号>/wq-build.git
# 或者先建好仓库再跑：
#   .\push.ps1 -RepoUrl git@github.com:<你的账号>/wq-build.git

param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path '.git')) {
    git init | Out-Null
    git checkout -b $Branch 2>$null | Out-Null
}

git add -A
$status = git status --porcelain
if ($status) {
    git commit -m 'wq build' | Out-Null
    Write-Host "已提交变更" -ForegroundColor Green
} else {
    Write-Host "没有新变更，跳过提交"
}

$remotes = git remote
if ($remotes -contains 'origin') {
    git remote set-url origin $RepoUrl
} else {
    git remote add origin $RepoUrl
}

git push -u origin $Branch

Write-Host ""
Write-Host "完成。下一步：" -ForegroundColor Cyan
Write-Host "  1) 打开 $RepoUrl  → Actions → build-wq-ipa → Run workflow"
Write-Host "  2) （可选）先在 Settings → Secrets and variables → Actions 配："
Write-Host "     SIGN_P12_BASE64 / SIGN_P12_PASS / SIGN_PROFILE_BASE64"
Write-Host "  3) 跑完在 Artifacts 下载 WQCollector.dylib / injected.ipa / signed.ipa"
