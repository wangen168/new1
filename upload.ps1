# upload.ps1 — 不用 git，直接用 GitHub REST API 把本目录上传到你的仓库
#
# 用法（在本目录执行）：
#   .\upload.ps1 -Repo "wangen168/wq-build" -Token "ghp_xxx"
#
# Token 需要 repo 权限（private 仓库还需要 workflow 权限才能提交 .github/workflows）。
# 生成地址：GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
#   勾选：Contents = Read and write，Workflows = Read and write
#
# 这个脚本会：
#   1) 逐个文件创建 blob（二进制也支持，内部走 base64）
#   2) 建一棵 tree
#   3) 建一个 commit（自动带上远端当前 HEAD 作父提交，空仓库则无父）
#   4) 把 main 分支指向新 commit（覆盖式，等于 force push）

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Branch = 'main',
    [string]$Message = 'wq build'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$api  = "https://api.github.com/repos/$Repo"
$headers = @{
    Authorization              = "Bearer $Token"
    Accept                     = 'application/vnd.github+json'
    'X-GitHub-Api-Version'     = '2022-11-28'
    'User-Agent'               = 'wq-upload'
}

function Invoke-GH {
    param([string]$Method, [string]$Url, $Body)
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 8 -Compress } else { $null }
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $json -ContentType 'application/json'
}

Write-Host "== 目标: $Repo ($Branch)" -ForegroundColor Cyan

# 1) 收集文件（跳过 .git）
$files = Get-ChildItem -Path $root -Recurse -File |
         Where-Object { $_.FullName -notmatch '\\\.git\\' }
Write-Host "== 文件数: $($files.Count)"

# 2) 上传 blob
$tree = @()
$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $b64   = [Convert]::ToBase64String($bytes)
    $resp = Invoke-GH -Method POST -Url "$api/git/blobs" -Body @{ content = $b64; encoding = 'base64' }
    $tree += @{ path = $rel; mode = '100644'; type = 'blob'; sha = $resp.sha }
    Write-Host ("  [{0}/{1}] {2} ({3:N1} KB)" -f $i, $files.Count, $rel, ($bytes.Length / 1KB))
}

# 3) 建 tree
$treeResp = Invoke-GH -Method POST -Url "$api/git/trees" -Body @{ tree = $tree }
Write-Host "== tree: $($treeResp.sha)"

# 4) 取当前 HEAD 作父提交（空仓库会 404）
$parents = @()
try {
    $ref = Invoke-GH -Method GET -Url "$api/git/ref/heads/$Branch"
    $parents = @($ref.object.sha)
    Write-Host "== 父提交: $($ref.object.sha)"
} catch {
    Write-Host "== 分支不存在（空仓库），作为首个提交" -ForegroundColor Yellow
}

$commitBody = @{ message = $Message; tree = $treeResp.sha }
if ($parents.Count) { $commitBody.parents = $parents }
$commit = Invoke-GH -Method POST -Url "$api/git/commits" -Body $commitBody
Write-Host "== commit: $($commit.sha)"

# 5) 更新/创建分支引用
if ($parents.Count) {
    Invoke-GH -Method PATCH -Url "$api/git/refs/heads/$Branch" -Body @{ sha = $commit.sha; force = $true } | Out-Null
} else {
    Invoke-GH -Method POST -Url "$api/git/refs" -Body @{ ref = "refs/heads/$Branch"; sha = $commit.sha } | Out-Null
}

Write-Host ""
Write-Host "上传完成：https://github.com/$Repo" -ForegroundColor Green
Write-Host "下一步：Actions → build-wq-ipa → Run workflow"
