# ============================================================================
#  BSide: Olivia Lin 离线版 —— 写信功能恢复工具
#  在你自己电脑上的客户端里就地打补丁；工具本身不含任何人的信件/账号数据。
#
#  用法：
#    .\restore-letters.ps1                 # 自动找游戏并打补丁
#    .\restore-letters.ps1 -Check          # 只检查，不修改
#    .\restore-letters.ps1 -Rollback       # 还原成官方原版
#    .\restore-letters.ps1 -GameRoot "E:\SteamLibrary\steamapps\common\BSide Olivia Lin Test"
#    .\restore-letters.ps1 -ServiceUrl "http://127.0.0.1:27149"
# ============================================================================
[CmdletBinding()]
param(
    [string]$GameRoot,
    [string]$ServiceUrl = "http://127.0.0.1:27149",
    [switch]$Check,
    [switch]$Rollback
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }

$Base = $ServiceUrl.TrimEnd("/")
$HostPort = ([regex]::Match($Base, '127\.0\.0\.1:\d+')).Value
if (-not $HostPort) { throw "ServiceUrl 必须是 127.0.0.1:<端口> 形式，当前为：$ServiceUrl" }

$Markers = [ordered]@{
    v3 = '/*OliviaSoulPatch:mail-cache-v3*/'
    v4 = '/*OliviaSoulPatch:mail-cache-v4*/'
    v5 = '/*OliviaSoulPatch:mail-cache-v5*/'
    v6 = '/*OliviaSoulPatch:mail-cache-v6*/'
    v7 = '/*OliviaSoulPatch:mail-cache-v7*/'
}

function Write-Step($text) { Write-Host "  $text" }
function Write-Head($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 找游戏目录
function Get-SteamRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).SteamPath
            if ($p) { $roots.Add(($p -replace '/', '\')) }
        } catch { }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) {
        foreach ($sub in @('Steam', 'steam', 'SteamLibrary', 'steamlibrary', 'Games\Steam', 'Games\SteamLibrary')) {
            $candidate = "${drive}:\$sub"
            if (Test-Path -LiteralPath $candidate) { $roots.Add($candidate) }
        }
    }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        if (-not $all.Contains($r)) { $all.Add($r) }
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s*"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if ((Test-Path -LiteralPath $lib) -and -not $all.Contains($lib)) { $all.Add($lib) }
            }
        }
    }
    return $all
}

function Resolve-GameRoot([string]$path) {
    if (-not $path) { return $null }
    $p = $path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    if ((Split-Path $p -Leaf) -eq 'resources' -and (Test-Path -LiteralPath (Join-Path $p 'feapp.dat'))) {
        return (Split-Path (Split-Path $p -Parent) -Parent)
    }
    if (Test-Path -LiteralPath (Join-Path $p 'resources\feapp.dat')) { return (Split-Path $p -Parent) }
    return $p
}

function Find-GameRoot {
    $patterns = @('BSide*', '*Olivia*Lin*', '*Olivia*林离*')
    foreach ($root in (Get-SteamRoots)) {
        $common = Join-Path $root "steamapps\common"
        if (-not (Test-Path -LiteralPath $common)) { continue }
        foreach ($pattern in $patterns) {
            foreach ($dir in (Get-ChildItem -LiteralPath $common -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
                $direct = Test-Path -LiteralPath (Join-Path $dir.FullName 'resources\feapp.dat')
                $nested = $false
                if (-not $direct) {
                    foreach ($sub in (Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)) {
                        if (Test-Path -LiteralPath (Join-Path $sub.FullName 'resources\feapp.dat')) { $nested = $true; break }
                    }
                }
                if ($direct -or $nested) { return $dir.FullName }
            }
        }
    }
    return $null
}

function Select-FolderDialog {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "请选择 BSide: Olivia Lin 的游戏根目录（里面有 launcher.exe，例如 ...\steamapps\common\BSide Olivia Lin Test）"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return $null
}

function Get-FeappFiles([string]$root) {
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $feapp = Join-Path $dir.FullName 'resources\feapp.dat'
        if (Test-Path -LiteralPath $feapp) {
            $found.Add([pscustomobject]@{ Version = $dir.Name; Path = $feapp; Resources = (Join-Path $dir.FullName 'resources') })
        }
    }
    return $found
}

function Stop-Game([string]$root) {
    $prefix = $root.TrimEnd('\') + '\'
    $stopped = $false
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Write-Step "关闭运行中的游戏进程：$($_.Name) (pid $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped = $true
        }
    if ($stopped) { Start-Sleep -Milliseconds 500 }
}

# ------------------------------------------------------------- zip 内读写
function Read-MainEntry([string]$zipPath) {
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $zip = New-Object IO.Compression.ZipArchive -ArgumentList @($fs, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $entry = @($zip.Entries | Where-Object { $_.FullName -match '^assets/main-.*\.js$' })
            if ($entry.Count -ne 1) { throw "feapp.dat 里应有且仅有一个 assets/main-*.js，实际 $($entry.Count) 个" }
            $reader = New-Object IO.StreamReader($entry[0].Open(), (New-Object Text.UTF8Encoding $false))
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            return [pscustomobject]@{ Name = $entry[0].FullName; Text = $text; Entries = $zip.Entries.Count }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Write-MainEntry([string]$zipPath, [string]$entryName, [string]$text) {
    $fs = [IO.File]::Open($zipPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive -ArgumentList @($fs, [IO.Compression.ZipArchiveMode]::Update, $false)
        try {
            $entry = $zip.GetEntry($entryName)
            if (-not $entry) { throw "找不到条目 $entryName" }
            $entry.Delete()
            $created = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $stream = $created.Open()
            try {
                $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($text)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Get-MainHash([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
    return (($sha | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------- 补丁规则
function Get-Rules([string]$stage) {
    $r = New-Object System.Collections.Generic.List[object]
    function Add([string]$name, [string]$from, [string]$to) {
        $r.Add([pscustomobject]@{ Name = $name; From = $from; To = $to })
    }
    switch ($stage) {
        'v3' {
            foreach ($ep in @('/signIn', '/getUserInfo', '/letter/send', '/letter/list', '/letter/detail', '/letter/unread_count', '/letter/share', '/letter/resend')) {
                Add "信件接口 $ep 指向本地服务" ('"' + $ep + '"') ('"' + $Base + '/toy' + $ep + '"')
            }
            Add "信箱写信按钮开关 N3" 'N3=!1,Ss=!1,wa=({onComplete' 'N3=!0,Ss=!1,wa=({onComplete'
            Add "回信视频判定" 'content:e.replyText??"",type:Wn(e.replyType,e.letterStatus,e.auditStatus),replyType:e.replyType,videoUrl:e.replyVideoUrl||void 0' 'content:e.replyText??"",type:e.letterStatus===bt.FAILED?Wn(e.replyType,e.letterStatus,e.auditStatus):e.replyVideoUrl?"video":"text",replyType:e.replyType,videoUrl:e.replyVideoUrl||void 0'
            Add "离线 uid 同步" 'const oe=await Dn({hideToast:!0,loading:!0}),{status:Ce,modelGatewayToken:Fe}=oe;oe.userInfo&&Ie().setUserProfile(oe.userInfo),P.value' 'const oe=await Dn({hideToast:!0,loading:!0}),{status:Ce,modelGatewayToken:Fe}=oe;oe.uid!==void 0&&l.setUid(oe.uid.toString()),oe.userInfo&&Ie().setUserProfile(oe.userInfo),P.value'
            Add "信箱轮询顺序" 'for(const re of ue){const ye=t.value.findIndex' 'for(const re of [...ue].reverse()){const ye=t.value.findIndex'
            Add "轮询状态比较" '(((B=re.received)==null?void 0:B.type)!==((K=Ee.received)==null?void 0:K.type)||re.isUnread!==Ee.isUnread)&&' '(((B=re.received)==null?void 0:B.type)!==((K=Ee.received)==null?void 0:K.type)||re.isUnread!==Ee.isUnread||re.letterStatus!==Ee.letterStatus)&&'
            Add "回信中图标状态" 'const m=s.mail.id===ro,u=!s.mail.received,p=s.mail.isUnread,d=(h=s.mail.received)==null?void 0:h.type;return' 'const m=s.mail.id===ro,u=!s.mail.received||s.mail.letterStatus===bt.LLM_PROCESSING,p=s.mail.isUnread,d=(h=s.mail.received)==null?void 0:h.type;return'
        }
        'v4' {
            Add "信箱页显示写信按钮" '"hide-write":o(p)||!o(N3)' '"hide-write":!1'
            Add "不再强制关闭入口开关" 'const m=()=>{e.isOfflineMode&&(l.value.mailWidget!==!1&&(l.value.mailWidget=!1),l.value.musicWidget!==!1&&(l.value.musicWidget=!1))};' 'const m=()=>{};'
            Add "保持 mailWidget 开启" 'l.value={...l.value,...p}};let c={...l.value};' 'l.value={...l.value,...p,mailWidget:!0}};let c={...l.value};'
            Add "离线放行本地信件服务" 'if(t.isOfflineMode)throw new Ol(e);' ('if(t.isOfflineMode&&!String(e.url||"").includes("' + $HostPort + '"))throw new Ol(e);')
            Add "离线也拉取信件列表" 'He(()=>{p.value||d.fetchMailList(!0)})' 'He(()=>{d.fetchMailList(!0)})'
            Add "离线也启动信箱轮询" 's.isOfflineMode||(s.appMode===Se.PRO?Lt().proRestoreFromApi():s.appMode===Se.LITE&&(Lt().liteStartPoll(),uo().startPolling()))' '(s.appMode===Se.PRO?Lt().proRestoreFromApi():s.appMode===Se.LITE&&(Lt().liteStartPoll(),uo().startPolling()))'
        }
        'v5' {
            Add "设置里恢复写信/音乐开关" 'X=["mail-widget","music-widget"]' 'X=[]'
            Add "把 mailWidget=true 下发给客户端" 'l.value={...l.value,...p,mailWidget:!0}};let c={...l.value};' 'l.value={...l.value,...p,mailWidget:!0}};let c={...l.value,mailWidget:!1};'
        }
        'v6' {
            Add "菜单加「信箱」入口" '{key:"history",icon:"history",label:a("user_menu_history"),visible:i.value===Se.PRO,onClick:()=>d(ve.History)}' '{key:"mailbox",icon:"history",label:a("mailbox_title"),visible:!0,onClick:()=>d(ve.Collection)}'
            Add "菜单加「曲库」入口" '{key:"userCenter",icon:"userCenter",label:a("user_menu_user_center"),visible:((g=(y=t.clientConfig)==null?void 0:y.appInfo)==null?void 0:g.Channel)==="steam",onClick:h}' '{key:"studio",icon:"userCenter",label:a("studio_title"),visible:!0,onClick:()=>d(ve.Studio)}'
        }
        'v7' {
            Add "离线也能打开头像菜单" 'onClick:g[0]||(g[0]=x=>d(o(ve).Settings))' 'onClick:p'
            Add "菜单按钮图标" '[k(w,{type:"setting",class:"text-[20px] text-primary-0"})],8,c0)' '[k(w,{type:"userCenter",class:"text-[20px] text-primary-0"})],8,c0)'
        }
    }
    return $r
}

# 在内存里试算：任何一处对不上就抛错（调用方据此判断版本是否匹配）
function Invoke-Patch([string]$source) {
    $text = $source
    $applied = New-Object System.Collections.Generic.List[string]
    $repoint = $false
    $existingBase = [regex]::Match($text, 'http://127\.0\.0\.1:\d+/toy').Value
    if ($existingBase -and -not $text.Contains($Base + '/toy')) {
        $oldBase = $existingBase.Substring(0, $existingBase.Length - 4)
        $oldHostPort = [regex]::Match($existingBase, '127\.0\.0\.1:\d+').Value
        $text = $text.Replace($oldBase, $Base)
        $text = $text.Replace($oldHostPort, $HostPort)
        $repoint = $true
    }
    foreach ($stage in $Markers.Keys) {
        $marker = $Markers[$stage]
        if ($text.Contains($marker)) { continue }
        foreach ($rule in (Get-Rules $stage)) {
            $count = ([regex]::Matches($text, [regex]::Escape($rule.From))).Count
            if ($count -ne 1) { throw "补丁步骤「$($rule.Name)」在客户端里匹配到 $count 处（应为 1 处）" }
            $text = $text.Replace($rule.From, $rule.To)
            $applied.Add($rule.Name)
        }
        $last = $null
        foreach ($k in $Markers.Keys) {
            if ($k -eq $stage) { break }
            if ($text.Contains($Markers[$k])) { $last = $Markers[$k] }
        }
        if ($last) { $text = $text.Replace($last, $last + $marker) } else { $text = $marker + $text }
    }
    return [pscustomobject]@{ Text = $text; Applied = $applied; Repointed = $repoint; ExistingBase = $existingBase }
}

# ================================================================ 主流程
Write-Host ""
Write-Host "BSide: Olivia Lin 离线版 —— 写信功能恢复工具" -ForegroundColor Green
Write-Host "（只修改客户端 feapp.dat；不读取、不打包任何信件或账号数据）" -ForegroundColor DarkGray

Write-Head "1/5 定位游戏"
if ($GameRoot) {
    $GameRoot = Resolve-GameRoot $GameRoot
} else {
    $GameRoot = Find-GameRoot
    if (-not $GameRoot) {
        Write-Step "没有自动找到游戏目录，请手动选择…"
        $picked = Select-FolderDialog
        if (-not $picked) { throw "已取消。也可以用 -GameRoot 参数指定游戏目录。" }
        $GameRoot = Resolve-GameRoot $picked
    }
}
if (-not $GameRoot -or -not (Test-Path -LiteralPath $GameRoot)) { throw "游戏目录无效：$GameRoot" }
Write-Step "游戏目录：$GameRoot"

$feapps = Get-FeappFiles $GameRoot
if ($feapps.Count -eq 0) { throw "在 $GameRoot 下没找到 <版本号>\resources\feapp.dat，请确认目录是否选对" }

$target = $null
$main = $null
$patched = $null
$lastError = ""
foreach ($f in $feapps) {
    try {
        $candidate = Read-MainEntry $f.Path
        $result = Invoke-Patch $candidate.Text
        $target = $f; $main = $candidate; $patched = $result
        break
    } catch {
        $lastError = $_.Exception.Message
    }
}
if (-not $target) {
    throw "客户端版本与补丁不匹配，已中止（未修改任何文件）。原因：$lastError`n如果之前用别的工具改过，请先还原成官方原版，或换用对应版本的工具。"
}
Write-Step "客户端版本：$($target.Version)"
Write-Step "入口文件：$($main.Name)（$($main.Text.Length) 字符，压缩包共 $($main.Entries) 项）"

$alreadyStages = @()
foreach ($stage in $Markers.Keys) { if ($main.Text.Contains($Markers[$stage])) { $alreadyStages += $stage } }
Write-Step ("当前状态：" + $(if ($alreadyStages.Count) { "已打补丁（" + ($alreadyStages -join ', ') + "）" } else { "官方原版" }))
if ($patched.Repointed -and -not $Rollback) { Write-Step ("检测到旧服务地址 " + ($patched.ExistingBase -replace '/toy$', '') + "，将改为 $Base") }

if ($Check) {
    Write-Head "检查完成（未修改任何文件）"
    if ($patched.Applied.Count -eq 0 -and -not $patched.Repointed) { Write-Step "结果：已是恢复状态，无需处理。" }
    elseif ($patched.Applied.Count -eq 0) { Write-Step "结果：补丁已就绪，仅需把服务地址更新为 $Base。" }
    else { Write-Step ("结果：可以打补丁，共 " + $patched.Applied.Count + " 项修改。") }
    exit 0
}

if ($patched.Applied.Count -eq 0 -and -not $patched.Repointed) {
    Write-Head "无需处理"
    Write-Step "这个客户端的写信功能已经是恢复状态了。"
    exit 0
}

Write-Head "2/5 备份"
$originalBak = Join-Path $target.Resources 'feapp.dat.original.bak'
if (-not (Test-Path -LiteralPath $originalBak)) {
    Copy-Item -LiteralPath $target.Path -Destination $originalBak -Force
    Write-Step "已保存官方原版备份：$originalBak"
} else {
    Write-Step "官方原版备份已存在：$originalBak"
}
if ($alreadyStages.Count -gt 0) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stepBak = Join-Path $target.Resources "feapp.dat.before-$stamp.bak"
    Copy-Item -LiteralPath $target.Path -Destination $stepBak -Force
    Write-Step "已保存当前状态备份：$stepBak"
}

if ($Rollback) {
    Write-Head "回退"
    Stop-Game $GameRoot
    Copy-Item -LiteralPath $originalBak -Destination $target.Path -Force
    $after = Read-MainEntry $target.Path
    Write-Host ""
    Write-Host "已还原成官方原版 ✅" -ForegroundColor Green
    Write-Step "入口文件：$($after.Name)，$($after.Text.Length) 字符"
    Write-Step "sha256 = $(Get-MainHash $after.Text)"
    Write-Host ""
    exit 0
}

Write-Head "3/5 打补丁"
foreach ($name in $patched.Applied) { Write-Step "· $name" }
if ($patched.Repointed) { Write-Step "· 本地服务地址更新为 $Base" }
Write-Step ("共 " + ($patched.Applied.Count + $(if ($patched.Repointed) { 1 } else { 0 })) + " 项修改")

Write-Head "4/5 写入客户端"
Stop-Game $GameRoot
Write-MainEntry $target.Path $main.Name $patched.Text
Write-Step "已写回：$($target.Path)"

Write-Head "5/5 校验"
$verify = Read-MainEntry $target.Path
if ($verify.Text -ne $patched.Text) { throw "校验失败：写回内容与预期不一致，请用 -Rollback 还原后重试。" }
if ($verify.Entries -ne $main.Entries) { throw "校验失败：压缩包条目数从 $($main.Entries) 变成 $($verify.Entries)。" }
Write-Step "内容校验通过，main JS sha256 = $(Get-MainHash $verify.Text)"

Write-Host ""
Write-Host "写信功能已恢复 ✅" -ForegroundColor Green
Write-Host ""
Write-Host "接下来：" -ForegroundColor Yellow
Write-Host "  1) 需要有「本地信件服务」在本机 $Base 运行（它负责生成回信），"
Write-Host "     否则寄信会提示 Network Error（请求发不出去）。"
Write-Host "  2) 打开游戏 → 右上角头像 → 信箱 → 左下角「写信」。"
Write-Host "  3) 设置 → 桌面偏好 → 「写信」开关应保持开启。"
Write-Host ""
Write-Host "还原：用菜单选 [3]，或执行" -ForegroundColor DarkGray
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Rollback" -ForegroundColor DarkGray
Write-Host "原版备份：$originalBak" -ForegroundColor DarkGray
Write-Host ""
