param(
  [ValidateSet('apply','remove')][string]$Mode = 'apply',
  [string]$GameRoot = '',
  [string]$RPCS3Root = '',
  [switch]$NoPrompt
)
# 진·삼국무쌍 6 시리즈 한글패치 적용/제거 스크립트 (Windows PowerShell 5.1 이상)
# 본 한글패치는 개인이 제작한 비공식·비상업적 팬 한글패치입니다. / by Yonggary6425
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$cfg = Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function PutU64([byte[]]$a, [int]$o, [uint64]$v) {
  $b = [BitConverter]::GetBytes($v); if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
  [Array]::Copy($b, 0, $a, $o, 8)
}
function IsGameRoot([string]$p) {
  if (-not $p) { return $false }
  return (Test-Path -LiteralPath (Join-Path $p 'PS3_GAME\USRDIR\LINKDATA.IDX'))
}
function IsIso([string]$p) { return ($p -and $p.ToLowerInvariant().EndsWith('.iso') -and (Test-Path -LiteralPath $p -PathType Leaf)) }
function ResolveTarget([string]$g) {
  $g = $g.Trim().Trim('"').TrimEnd('\')
  if (IsIso $g) { return $g }
  if (IsGameRoot $g) { return $g }
  # PS3_GAME 이나 USRDIR 폴더를 넣은 경우
  foreach ($up in @((Split-Path -Parent $g), (Split-Path -Parent (Split-Path -Parent $g)))) { if (IsGameRoot $up) { return $up } }
  return $null
}
function FindGameRoot {
  if ($GameRoot) {
    $r = ResolveTarget $GameRoot
    if ($r) { return $r }
    throw "게임 폴더나 ISO 파일이 아닙니다: $GameRoot`n(PS3_GAME 폴더가 들어 있는 폴더 또는 .iso 파일을 지정하세요)"
  }
  # 패치 폴더를 게임 폴더 안에 넣고 실행한 경우: 상위 폴더를 차례로 확인
  $p = Split-Path -Parent $here
  for ($k = 0; $k -lt 4 -and $p; $k++) { if (IsGameRoot $p) { return $p }; $p = Split-Path -Parent $p }
  if ($NoPrompt) { throw '게임 폴더를 찾지 못했습니다.' }
  Say ''
  Say '게임 폴더(PS3_GAME 폴더가 들어 있는 폴더) 또는 ISO 파일을 이 창에 끌어다 놓고 Enter를 누르세요.' 'Yellow'
  $in = Read-Host '(그냥 Enter를 누르면 폴더 선택 창이 뜹니다)'
  if ($in.Trim()) {
    $r = ResolveTarget $in
    if ($r) { return $r }
    throw "게임 폴더나 ISO 파일이 아닙니다: $in"
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $cfg.name + ' 게임 폴더(PS3_GAME 폴더가 들어 있는 폴더)를 선택하세요.'
    if ($dlg.ShowDialog() -eq 'OK' -and (IsGameRoot $dlg.SelectedPath)) { return $dlg.SelectedPath }
  } catch { }
  throw '게임 폴더를 찾지 못했습니다. PS3_GAME 폴더가 들어 있는 폴더 또는 ISO 파일을 지정하세요.'
}

# ================================================================ ISO
$isoCs = @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Security.Cryptography;
public class Ps3Iso : IDisposable {
  public FileStream Fs;
  byte[] key;
  ICryptoTransform ecb;
  public List<long> PlainStart = new List<long>();
  public List<long> PlainEnd = new List<long>();
  public bool HasTable;
  public Ps3Iso(string path, byte[] k) {
    Fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
    key = k;
    byte[] s0 = new byte[2048];
    Fs.Position = 0; ReadFull(s0, 0, 2048);
    uint n = BE(s0, 0);
    if (n >= 1 && n <= 32 && BE(s0, 4) == 0) {
      HasTable = true;
      for (int i = 0; i < n; i++) { PlainStart.Add(BE(s0, 8 + 8 * i)); PlainEnd.Add(BE(s0, 12 + 8 * i)); }
    }
    if (key != null) {
      Aes aes = Aes.Create(); aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None;
      ecb = aes.CreateDecryptor(key, new byte[16]);
    }
  }
  public static uint BE(byte[] b, int o) { return ((uint)b[o] << 24) | ((uint)b[o + 1] << 16) | ((uint)b[o + 2] << 8) | b[o + 3]; }
  void ReadFull(byte[] buf, int off, int n) {
    int got = 0;
    while (got < n) { int r = Fs.Read(buf, off + got, n - got); if (r <= 0) throw new IOException("ISO file is shorter than expected"); got += r; }
  }
  public bool IsEnc(long sec) {
    if (key == null || !HasTable) return false;
    for (int i = 0; i < PlainStart.Count; i++) if (sec >= PlainStart[i] && sec <= PlainEnd[i]) return false;
    return true;
  }
  void ReadSectors(long sec, int cnt, byte[] buf) {
    Fs.Position = sec * 2048; ReadFull(buf, 0, cnt * 2048);
    if (key == null) return;
    for (int i = 0; i < cnt; i++) {
      long s = sec + i; if (!IsEnc(s)) continue;
      int o = i * 2048;
      byte[] p = ecb.TransformFinalBlock(buf, o, 2048);
      for (int b = 2047; b >= 16; b--) p[b] ^= buf[o + b - 16];
      p[12] ^= (byte)(s >> 24); p[13] ^= (byte)(s >> 16); p[14] ^= (byte)(s >> 8); p[15] ^= (byte)s;
      Buffer.BlockCopy(p, 0, buf, o, 2048);
    }
  }
  public byte[] ReadBytes(long pos, int n) {
    long s0 = pos / 2048; long s1 = (pos + n + 2047) / 2048; int cnt = (int)(s1 - s0);
    byte[] buf = new byte[cnt * 2048]; ReadSectors(s0, cnt, buf);
    byte[] r = new byte[n]; Buffer.BlockCopy(buf, (int)(pos - s0 * 2048), r, 0, n); return r;
  }
  public void CopyTo(Stream dst, long from, long len, long to) {
    dst.Position = to; const int CH = 4096; byte[] buf = new byte[CH * 2048]; long sec = from / 2048; long left = len;
    while (left > 0) {
      long need = Math.Min(left, (long)CH * 2048); int cnt = (int)((need + 2047) / 2048);
      ReadSectors(sec, cnt, buf); dst.Write(buf, 0, (int)need); left -= need; sec += cnt;
    }
  }
  public static byte[] D1ToKey(byte[] d1) {
    Aes aes = Aes.Create(); aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.None;
    byte[] k = new byte[] { 0x38, 0x0B, 0xCF, 0x0B, 0x53, 0x45, 0x5B, 0x3C, 0x78, 0x17, 0xAB, 0x4F, 0xA3, 0xBA, 0x90, 0xED };
    byte[] iv = new byte[] { 0x69, 0x47, 0x47, 0x72, 0xAF, 0x6F, 0xDA, 0xB3, 0x42, 0x74, 0x3A, 0xEF, 0xAA, 0x18, 0x62, 0x87 };
    return aes.CreateEncryptor(k, iv).TransformFinalBlock(d1, 0, 16);
  }
  public void Dispose() { Fs.Dispose(); }
}
'@
if (-not ('Ps3Iso' -as [type])) {
  if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $isoCs } else { Add-Type -TypeDefinition $isoCs -ReferencedAssemblies 'System.Core' }
}
function U32LE([byte[]]$b, [int]$o) { return [uint32]([BitConverter]::ToUInt32($b, $o)) }
function U32BE([byte[]]$b, [int]$o) { return [Ps3Iso]::BE($b, $o) }
function ReadAt($r, [int64]$pos, [int]$n) { return ,($r.ReadBytes($pos, $n)) }
function Both32([uint32]$v) {
  $le = [BitConverter]::GetBytes($v); $be = [BitConverter]::GetBytes($v); [Array]::Reverse($be)
  return ,([byte[]]($le + $be))
}
function BE32([uint32]$v) { $be = [BitConverter]::GetBytes($v); [Array]::Reverse($be); return ,$be }
function WriteAt($fs, [int64]$pos, [byte[]]$b) { $fs.Position = $pos; $fs.Write($b, 0, $b.Length) }
function ReadTree($r, [int64]$rootLba, [int64]$rootSize, [bool]$joliet) {
  $files = New-Object System.Collections.ArrayList
  $dirs = New-Object System.Collections.ArrayList
  $seen = @{}
  $stack = New-Object System.Collections.Stack
  $stack.Push(@($rootLba, $rootSize, ''))
  while ($stack.Count -gt 0) {
    $it = $stack.Pop(); $lba = [int64]$it[0]; $size = [int64]$it[1]; $path = $it[2]
    if ($seen.ContainsKey($lba)) { continue }; $seen[$lba] = 1
    if ($size -le 0 -or $size -gt 16MB) { throw '디렉터리 정보를 읽을 수 없습니다.' }
    [void]$dirs.Add(@{ lba = $lba; size = $size; path = $path })
    $b = ReadAt $r ($lba * 2048) ([int]$size)
    $o = 0
    while ($o -lt $size) {
      $len = [int]$b[$o]
      if ($len -eq 0) { $o = [int]([Math]::Floor($o / 2048) + 1) * 2048; continue }
      if ($o + 33 -gt $size) { break }
      $elba = [int64](U32LE $b ($o + 2)); $dlen = [int64](U32LE $b ($o + 10)); $flags = $b[$o + 25]; $nl = [int]$b[$o + 32]
      if (-not ($nl -eq 1 -and $b[$o + 33] -le 1)) {
        if ($joliet) { $name = [System.Text.Encoding]::BigEndianUnicode.GetString($b, $o + 33, $nl) } else { $name = [System.Text.Encoding]::ASCII.GetString($b, $o + 33, $nl) }
        $sc = $name.IndexOf(';'); if ($sc -ge 0) { $name = $name.Substring(0, $sc) }
        $name = $name.TrimEnd('.')
        $full = if ($path) { $path + '/' + $name } else { $name }
        if ($flags -band 2) { $stack.Push(@($elba, $dlen, $full)) }
        else { [void]$files.Add([pscustomobject]@{ path = $full.ToUpperInvariant(); lba = $elba; size = $dlen; flags = $flags; rec = ($lba * 2048 + $o) }) }
      }
      $o += $len
    }
  }
  return @{ files = $files; dirs = $dirs }
}
# ISO 구조를 읽고 원본 인덱스가 맞는지 확인
function AnalyzeIso($r) {
  $pvdPos = $null; $svdPos = @(); $sec = 16; $udf = $false
  while ($sec -lt 64) {
    $d = ReadAt $r ($sec * 2048) 2048
    $id = [System.Text.Encoding]::ASCII.GetString($d, 1, 5)
    if ($id -eq 'CD001') {
      if ($d[0] -eq 1 -and $pvdPos -eq $null) { $pvdPos = $sec * 2048; $pvd = $d }
      elseif ($d[0] -eq 2 -and $d[88] -eq 0x25 -and $d[89] -eq 0x2F) { $svdPos += ,($sec * 2048) }
    } elseif ($id -eq 'NSR02' -or $id -eq 'NSR03') { $udf = $true }
    elseif ($id -ne 'BEA01' -and $id -ne 'TEA01' -and $id -ne 'BOOT2') { break }
    $sec++
  }
  if ($pvdPos -eq $null) { throw 'ISO9660 형식이 아닙니다.' }
  $trees = @()
  $trees += ,(ReadTree $r ([int64](U32LE $pvd 158)) ([int64](U32LE $pvd 166)) $false)
  foreach ($sp in $svdPos) { $sv = ReadAt $r $sp 2048; $trees += ,(ReadTree $r ([int64](U32LE $sv 158)) ([int64](U32LE $sv 166)) $true) }
  $P = $trees[0].files
  $link = @($P | Where-Object { $_.path -eq 'PS3_GAME/USRDIR/LINKDATA.BIN' } | Sort-Object rec)
  $idxRec = @($P | Where-Object { $_.path -eq 'PS3_GAME/USRDIR/LINKDATA.IDX' })
  if ($link.Count -eq 0 -or $idxRec.Count -ne 1) { throw 'NOLINK' }
  if ([int64]$idxRec[0].size -ne [int64]$cfg.idxSize) { throw 'OTHERGAME' }
  $idx = ReadAt $r ($idxRec[0].lba * 2048) ([int]$idxRec[0].size)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = ([BitConverter]::ToString($sha.ComputeHash($idx)) -replace '-', '').ToLowerInvariant()
  return @{ ok = ($h -eq $cfg.idxSha256); pvdPos = $pvdPos; svdPos = $svdPos; pvd = $pvd; trees = $trees; P = $P; link = $link; idxRec = $idxRec; idx = $idx; udf = $udf }
}
function FindDiscKey([string]$isoPath) {
  $base = Join-Path (Split-Path -Parent $isoPath) ([System.IO.Path]::GetFileNameWithoutExtension($isoPath))
  foreach ($ext in @('.dkey', '.key')) {
    $p = $base + $ext
    if (Test-Path -LiteralPath $p) {
      $raw = [System.IO.File]::ReadAllBytes($p)
      $txt = [System.Text.Encoding]::ASCII.GetString($raw)
      $m = [regex]::Match($txt, '(?i)(?:0x)?([0-9a-f]{32})')
      if ($m.Success) { $hx = $m.Groups[1].Value; $k = New-Object byte[] 16; for ($i = 0; $i -lt 16; $i++) { $k[$i] = [Convert]::ToByte($hx.Substring($i * 2, 2), 16) }; return ,$k }
      if ($raw.Length -eq 16) { return ,$raw }
    }
  }
  # 3k3y 암호화 ISO: 헤더에 D1 키가 들어 있음
  $fs = [System.IO.File]::Open($isoPath, 'Open', 'Read', 'Read')
  try { $h = New-Object byte[] 4096; $fs.Position = 0; [void]$fs.Read($h, 0, 4096) } finally { $fs.Dispose() }
  if ($h[0xF70] -eq [byte][char]'E' -or $h[0xF70] -eq [byte][char]'e') {
    $d1 = New-Object byte[] 16; [Array]::Copy($h, 0xF80, $d1, 0, 16)
    return ,([Ps3Iso]::D1ToKey($d1))
  }
  return $null
}

function PatchIso([string]$isoPath) {
  Say "ISO 파일: $isoPath"
  $outPath = Join-Path (Split-Path -Parent $isoPath) ([System.IO.Path]::GetFileNameWithoutExtension($isoPath) + '_KOR.iso')
  if ($Mode -eq 'remove') {
    Say 'ISO 패치는 원본 ISO를 건드리지 않고 새 ISO(_KOR.iso)를 만드는 방식입니다.' 'Yellow'
    Say '한글패치를 지우려면 _KOR.iso 파일을 삭제하고 원본 ISO를 그대로 쓰면 됩니다.' 'Yellow'
    return
  }
  if ([System.IO.Path]::GetFileNameWithoutExtension($isoPath).EndsWith('_KOR')) { throw '이미 한글패치로 만든 ISO입니다. 원본 ISO를 지정하세요.' }
  Say '패치 파일 검사 중...'
  foreach ($e in $cfg.entries) {
    $p = Join-Path $here ('patch\' + $e.file)
    if (-not (Test-Path -LiteralPath $p) -or (Sha $p) -ne $e.sha256) { throw "패치 파일이 손상되었습니다: $($e.file) (압축을 다시 풀어 주세요)" }
  }
  Say 'ISO 확인 중...'
  $key = FindDiscKey $isoPath
  $tries = @(); if ($key) { $tries += ,$key }; $tries += ,$null
  $r = $null; $A = $null; $why = ''; $selKey = $null
  foreach ($k in $tries) {
    $cand = [Ps3Iso]::new($isoPath, [byte[]]$k)
    try { $info = AnalyzeIso $cand } catch { $why = $_.Exception.Message; $cand.Dispose(); continue }
    if ($info.ok) { $r = $cand; $A = $info; $selKey = $k; break }
    $why = 'HASH'; $cand.Dispose()
  }
  if (-not $A) {
    if ($why -eq 'OTHERGAME') { throw ('이 패치가 지원하는 게임(' + $cfg.titleId + ')의 ISO가 아닙니다.') }
    if ($why -eq 'NOLINK') { throw '이 ISO에서 PS3_GAME/USRDIR/LINKDATA.BIN 을 찾지 못했습니다.' }
    if (-not $key) {
      throw ("원본 데이터를 확인할 수 없습니다. 암호화된 ISO(Redump 등)라면 ISO와 같은 폴더에 같은 이름의 .dkey 파일(디스크 키)을 두고 다시 실행하세요.`n예: " + [System.IO.Path]::GetFileNameWithoutExtension($isoPath) + '.dkey')
    }
    throw '원본 ISO가 아니거나 디스크 키(.dkey)가 맞지 않습니다. 수정되지 않은 원본 ISO와 맞는 .dkey 파일을 사용하세요.'
  }
  try {
    if ($A.udf) { Say '  (참고) 이 ISO의 UDF 정보는 갱신하지 않습니다. RPCS3는 ISO9660 정보로 읽습니다.' 'DarkGray' }
    $trees = $A.trees; $P = $A.P; $link = $A.link; $idxRec = $A.idxRec; $idx = $A.idx; $pvdPos = $A.pvdPos; $svdPos = $A.svdPos
    $oldTotal = [int64](U32LE $A.pvd 80)
    # LINKDATA.BIN 구간
    $first = [int64]$link[0].lba; $sumPrev = [int64]0
    for ($k = 0; $k -lt $link.Count; $k++) {
      if ($k -gt 0) { $exp = [int64]$link[$k-1].lba + [int64]([Math]::Ceiling($link[$k-1].size / 2048.0)); if ([int64]$link[$k].lba -ne $exp) { throw 'LINKDATA.BIN이 연속 배치되지 않은 ISO입니다. 폴더로 풀어서 패치하세요.' } }
      if ($k -lt $link.Count - 1) { $sumPrev += [int64]$link[$k].size }
    }
    $last = $link[$link.Count - 1]
    $E = [int64]$last.lba + [int64]([Math]::Ceiling($last.size / 2048.0))
    $oldLinkSize = $sumPrev + [int64]$last.size
    if ($oldLinkSize -lt [int64]$cfg.binLength) { throw 'LINKDATA.BIN 크기가 원본과 다릅니다.' }
    foreach ($t in $trees) { foreach ($dd in $t.dirs) { if ($dd.lba -ge $E) { throw '지원하지 않는 ISO 구조입니다(폴더 정보가 데이터 뒤에 있음). 폴더로 풀어서 패치하세요.' } } }
    # LINKDATA.BIN 뒤에 있던 파일(옮길 대상)
    $tail = @{}
    foreach ($t in $trees) { foreach ($f in $t.files) { if ($f.size -gt 0 -and $f.lba -ge $E) { if (-not $tail.ContainsKey($f.lba) -or $tail[$f.lba] -lt $f.size) { $tail[$f.lba] = [int64]$f.size } } } }
    # 교체 파일
    $repl = @{}
    foreach ($f in $cfg.files) { $repl[($f.dst -replace '\\', '/').ToUpperInvariant()] = $f }
    foreach ($k in $repl.Keys) { if (-not ($P | Where-Object { $_.path -eq $k })) { throw "ISO에서 $k 을(를) 찾지 못했습니다." } }

    $need = [int64]$r.Fs.Length + 1GB
    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($outPath))
    if ($drive.AvailableFreeSpace -lt $need) { throw ('새 ISO를 만들 공간이 부족합니다. 필요: 약 ' + [Math]::Round($need / 1GB, 1) + 'GB') }
    if ($selKey) { Say '암호화된 ISO입니다. 복호화된 한글판 ISO로 만듭니다.' }
    Say "새 ISO를 만드는 중: $outPath"
    Say '(원본 ISO는 그대로 둡니다. 몇 분 걸릴 수 있습니다)'
    $dst = [System.IO.File]::Open($outPath, 'Create', 'ReadWrite', 'None')
    $ok = $false
    try {
      $r.CopyTo($dst, 0, $E * 2048, 0)
      # 한글 데이터를 LINKDATA.BIN 끝에 이어 붙임
      $rel = ($E - $first) * 2048
      $k = 0
      foreach ($e in $cfg.entries) {
        $data = [System.IO.File]::ReadAllBytes((Join-Path $here ('patch\' + $e.file)))
        WriteAt $dst ($first * 2048 + $rel) $data
        $o = [int]$e.index * 32
        PutU64 $idx $o ([uint64]$rel)
        if ($e.file.EndsWith('.kz')) {
          $usize = ([uint64]$data[8] * 16777216) + ([uint64]$data[9] * 65536) + ([uint64]$data[10] * 256) + [uint64]$data[11]
          PutU64 $idx ($o + 8) $usize; PutU64 $idx ($o + 16) ([uint64]$data.Length); PutU64 $idx ($o + 24) 1
        } else {
          PutU64 $idx ($o + 8) ([uint64]$data.Length); PutU64 $idx ($o + 16) ([uint64]$data.Length); PutU64 $idx ($o + 24) 0
        }
        $rel += $data.Length
        if ($rel % 2048 -ne 0) { $rel += 2048 - ($rel % 2048) }
        $k++; if ($k % 100 -eq 0) { Write-Host ("  {0}/{1}" -f $k, $cfg.entries.Count) }
      }
      $newLastSize = $rel - $sumPrev
      if ($newLastSize -gt [int64]4294965248) { throw 'LINKDATA.BIN 마지막 구간이 4GB를 넘습니다. 폴더로 풀어서 패치하세요.' }
      $next = $first + [int64]($rel / 2048)
      # 뒤에 있던 파일 이동
      $map = @{}
      foreach ($l in ($tail.Keys | Sort-Object)) {
        $map[[int64]$l] = $next
        $r.CopyTo($dst, [int64]$l * 2048, $tail[$l], $next * 2048)
        $next += [int64]([Math]::Ceiling($tail[$l] / 2048.0))
      }
      # 교체 파일 기록
      $rmap = @{}
      foreach ($f in $cfg.files) {
        $k2 = ($f.dst -replace '\\', '/').ToUpperInvariant(); $data = [System.IO.File]::ReadAllBytes((Join-Path $here $f.src))
        WriteAt $dst ($next * 2048) $data
        $rmap[$k2] = @{ lba = $next; size = [int64]$data.Length }
        $next += [int64]([Math]::Ceiling($data.Length / 2048.0))
        Say ('  교체: ' + $k2)
      }
      $newTotal = $next
      $dst.SetLength($newTotal * 2048)
      # 디렉터리 기록 수정 (기본 + Joliet)
      foreach ($t in $trees) {
        foreach ($f in $t.files) {
          if ($rmap.ContainsKey($f.path)) {
            WriteAt $dst ($f.rec + 2) (Both32 ([uint32]$rmap[$f.path].lba)); WriteAt $dst ($f.rec + 10) (Both32 ([uint32]$rmap[$f.path].size))
          } elseif ($f.path -eq 'PS3_GAME/USRDIR/LINKDATA.BIN' -and [int64]$f.lba -eq [int64]$last.lba) {
            WriteAt $dst ($f.rec + 10) (Both32 ([uint32]$newLastSize))
          } elseif ($map.ContainsKey([int64]$f.lba)) {
            WriteAt $dst ($f.rec + 2) (Both32 ([uint32]$map[[int64]$f.lba]))
          }
        }
      }
      # 새 인덱스
      $idxLba = [int64]$idxRec[0].lba; if ($map.ContainsKey($idxLba)) { $idxLba = $map[$idxLba] }
      WriteAt $dst ($idxLba * 2048) $idx
      # 볼륨 크기
      WriteAt $dst ($pvdPos + 80) (Both32 ([uint32]$newTotal))
      foreach ($sp in $svdPos) { WriteAt $dst ($sp + 80) (Both32 ([uint32]$newTotal)) }
      # PS3 디스크 영역표(섹터 0): 전체를 하나의 비암호화 영역으로
      if ($r.HasTable) {
        $n = $r.PlainStart.Count
        WriteAt $dst 0 (New-Object byte[] (8 + 8 * $n))
        WriteAt $dst 0 (BE32 1); WriteAt $dst 8 (BE32 0); WriteAt $dst 12 (BE32 ([uint32]($newTotal - 1)))
      }
      # 3k3y 표시: 암호화 → 복호화
      $h = $r.ReadBytes(0xF70, 1)
      if ($selKey -and ($h[0] -eq [byte][char]'E' -or $h[0] -eq [byte][char]'e')) { WriteAt $dst 0xF70 ([System.Text.Encoding]::ASCII.GetBytes('Decrypted 3K ISO')) }
      $dst.Flush()
      $ok = $true
    } finally {
      $dst.Dispose()
      if (-not $ok -and (Test-Path -LiteralPath $outPath)) { Remove-Item -LiteralPath $outPath -Force }
    }
  } finally { $r.Dispose() }

  foreach ($rp in @(AskRPCS3)) {
    $n = 0
    foreach ($e in $cfg.entries) {
      foreach ($c in (CachePaths $rp ([int]$e.index))) {
        if (-not (Test-Path -LiteralPath $c.full -PathType Leaf)) { continue }
        if ($e.file.EndsWith('.kz')) { Remove-Item -LiteralPath $c.full -Force }
        else { Copy-Item -LiteralPath (Join-Path $here ('patch\' + $e.file)) -Destination $c.full -Force }
        $n++
      }
    }
    Say "  RPCS3 캐시 갱신($rp): $n 개"
  }
  Say ''
  Say '한글패치 ISO 생성 완료!' 'Green'
  Say ('새 ISO: ' + $outPath) 'Green'
  Say '원본 ISO는 바뀌지 않았습니다. 새 ISO로 게임을 실행하세요.'
}
function FindRPCS3 {
  # 고정 디스크에서 rpcs3.exe가 있는 폴더를 3단계 깊이까지 찾는다
  $found = New-Object System.Collections.ArrayList
  foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
    $level = @($d.RootDirectory.FullName)
    for ($depth = 0; $depth -lt 3; $depth++) {
      $next = @()
      foreach ($dir in $level) {
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($sd in $subs) {
          $nm = [System.IO.Path]::GetFileName($sd)
          if ($nm -match '^(\$|Windows$|Program Files|ProgramData$|System Volume|Recovery$|AppData$|node_modules$)') { continue }
          if ([System.IO.File]::Exists([System.IO.Path]::Combine($sd, 'rpcs3.exe')) -and [System.IO.Directory]::Exists([System.IO.Path]::Combine($sd, 'dev_hdd1'))) { [void]$found.Add($sd) }
          $next += $sd
        }
      }
      $level = $next
    }
  }
  return $found
}
function Tag([string]$p) {
  $h = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($p.ToLowerInvariant()))
  return ([BitConverter]::ToString($h, 0, 4) -replace '-', '')
}
function AskRPCS3 {
  if ($RPCS3Root) { return @($RPCS3Root.Trim('"').TrimEnd('\')) }
  Say ''
  Say 'RPCS3 폴더를 찾는 중... (예전 실행으로 남은 데이터 사본을 새 한글 데이터로 바꿉니다)'
  $auto = @(FindRPCS3)
  if ($NoPrompt) { return $auto }
  if ($auto.Count -gt 0) {
    Say '찾은 RPCS3 폴더:' 'Yellow'
    foreach ($a in $auto) { Say ('  ' + $a) }
    $in = Read-Host '이 폴더(들)를 정리하려면 Enter, 다른 RPCS3 폴더면 경로 입력'
  } else {
    Say 'RPCS3 폴더를 자동으로 찾지 못했습니다.' 'Yellow'
    $in = Read-Host 'RPCS3 폴더(rpcs3.exe가 있는 폴더) 경로를 입력하세요 (건너뛰려면 그냥 Enter)'
  }
  $in = $in.Trim().Trim('"').TrimEnd('\')
  if (-not $in) { return $auto }
  if (-not (Test-Path -LiteralPath (Join-Path $in 'dev_hdd1'))) { Say "  dev_hdd1 폴더가 없어 캐시 정리를 건너뜁니다: $in" 'DarkYellow'; return $auto }
  return @($in) + @($auto | Where-Object { $_ -ne $in })
}
function CachePaths([string]$rp, [int]$i) {
  $grp = ([int]([Math]::Floor($i / 500.0) * 500)).ToString('00000')
  $sub = ([int]([Math]::Floor($i / 50.0) * 50)).ToString('00000')
  $num = $i.ToString('00000')
  $t = $cfg.titleId
  return @(
    @{ rel = "dev_hdd1\caches\${t}_${t}\$grp\$sub\$num"; full = Join-Path $rp "dev_hdd1\caches\${t}_${t}\$grp\$sub\$num" },
    @{ rel = "dev_hdd0\game\$t\USRDIR\$grp\$sub\$num"; full = Join-Path $rp "dev_hdd0\game\$t\USRDIR\$grp\$sub\$num" }
  )
}

Say '============================================================' 'Cyan'
Say (' ' + $cfg.name + ' 한글패치 ' + $cfg.version) 'Cyan'
Say ' 본 한글패치는 개인이 제작한 비공식·비상업적 팬 한글패치입니다.' 'Cyan'
Say ' by Yonggary6425 (용가리)' 'Cyan'
Say '============================================================' 'Cyan'
Say '게임과 RPCS3를 완전히 종료한 상태에서 진행하세요.' 'Yellow'

$root = FindGameRoot
if (IsIso $root) { PatchIso $root; return }
$usr = Join-Path $root 'PS3_GAME\USRDIR'
$idxPath = Join-Path $usr 'LINKDATA.IDX'
$binPath = Join-Path $usr 'LINKDATA.BIN'
$bk = Join-Path $root ('_hanpatch_backup_' + $cfg.titleId)
$statePath = Join-Path $bk 'state.json'
Say "게임 폴더: $root"

if ((Get-Item -LiteralPath $idxPath).Length -ne [int64]$cfg.idxSize) { throw ('이 패치가 지원하는 게임(' + $cfg.titleId + ')이 아닙니다. LINKDATA.IDX 크기가 다릅니다.') }

# ---------------------------------------------------------------- 제거
if ($Mode -eq 'remove') {
  if (-not (Test-Path -LiteralPath $statePath)) { throw '이 패치로 적용한 기록(_hanpatch_backup 폴더)이 없습니다. 제거할 것이 없습니다.' }
  $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $fs = [System.IO.File]::Open($binPath, 'Open', 'ReadWrite', 'None')
  try { $fs.SetLength([int64]$st.binLength) } finally { $fs.Dispose() }
  Copy-Item -LiteralPath (Join-Path $bk 'LINKDATA.IDX') -Destination $idxPath -Force
  foreach ($f in $cfg.files) {
    $saved = Join-Path $bk ('files\' + $f.dst)
    $dst = Join-Path $root $f.dst
    if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $dst -Force; Say ('  복원: ' + $f.dst) }
    else { Say ('  원본 백업이 없어 그대로 둡니다: ' + $f.dst) 'DarkYellow' }
  }
  $rps = @(); if ($st.rpcs3) { $rps = @($st.rpcs3 -split ';' | Where-Object { $_ }) } else { $rps = @(AskRPCS3) }
  foreach ($rp in $rps) {
    $n = 0
    foreach ($e in $cfg.entries) {
      foreach ($c in (CachePaths $rp ([int]$e.index))) {
        $saved = Join-Path $bk ('cache\' + (Tag $rp) + '\' + $c.rel)
        if (Test-Path -LiteralPath $saved) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $c.full) | Out-Null; Copy-Item -LiteralPath $saved -Destination $c.full -Force; $n++ }
        elseif (Test-Path -LiteralPath $c.full) { Remove-Item -LiteralPath $c.full -Force; $n++ }
      }
    }
    Say "  RPCS3 캐시 정리($rp): $n 개"
  }
  Remove-Item -LiteralPath $bk -Recurse -Force
  Say ''
  Say '한글패치를 제거하고 원본 상태로 되돌렸습니다.' 'Green'
  return
}

# ---------------------------------------------------------------- 적용
Say '패치 파일 검사 중...'
foreach ($e in $cfg.entries) {
  $p = Join-Path $here ('patch\' + $e.file)
  if (-not (Test-Path -LiteralPath $p) -or (Sha $p) -ne $e.sha256) { throw "패치 파일이 손상되었습니다: $($e.file) (압축을 다시 풀어 주세요)" }
}
foreach ($f in $cfg.files) {
  $p = Join-Path $here $f.src
  if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -ne [int64]$f.size) { throw "패치 파일이 손상되었습니다: $($f.src)" }
}

if (Test-Path -LiteralPath $statePath) {
  $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  Say '이전에 적용한 기록이 있어 원본 기준으로 다시 적용합니다.'
} else {
  # 원본 인덱스 찾기: 현재 파일 또는 예전 작업 백업
  $cands = @($idxPath) + @($cfg.legacyIdx | ForEach-Object { Join-Path $root $_ })
  $orig = $null
  foreach ($c in $cands) { if ((Test-Path -LiteralPath $c) -and (Sha $c) -eq $cfg.idxSha256) { $orig = $c; break } }
  if (-not $orig) { throw '원본 LINKDATA.IDX가 아닙니다. 다른 한글패치나 수정이 적용된 상태입니다. 원본 게임 파일로 되돌린 뒤 다시 실행하세요.' }
  $binLen = (Get-Item -LiteralPath $binPath).Length
  if ($binLen -lt [int64]$cfg.binLength) { throw 'LINKDATA.BIN 크기가 원본보다 작습니다. 게임 파일이 손상되었거나 다른 판본입니다.' }
  New-Item -ItemType Directory -Force -Path $bk | Out-Null
  Copy-Item -LiteralPath $orig -Destination (Join-Path $bk 'LINKDATA.IDX') -Force
  $st = [pscustomobject]@{ binLength = [int64]$cfg.binLength; rpcs3 = ''; version = $cfg.version }
  # 교체할 파일의 원본 백업
  foreach ($f in $cfg.files) {
    $dst = Join-Path $root $f.dst
    $saved = Join-Path $bk ('files\' + $f.dst)
    if (-not (Test-Path -LiteralPath $dst)) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
    $src = $dst
    if ((Get-Item -LiteralPath $dst).Length -eq [int64]$f.size -and (Sha $dst) -eq $f.sha256) {
      # 이미 한글판으로 바뀐 파일: 예전 작업 백업에서 원본을 찾는다
      $src = $null
      $leaf = Split-Path -Leaf $f.dst
      foreach ($lb in $cfg.legacyBackups) {
        foreach ($nm in @($f.dst, ('movie\' + $leaf), $leaf, ($leaf + '.orig'))) {
          $q = Join-Path (Join-Path $root $lb) $nm
          if ((Test-Path -LiteralPath $q) -and (Sha $q) -ne $f.sha256) { $src = $q; break }
        }
        if ($src) { break }
      }
    }
    if ($src) { Copy-Item -LiteralPath $src -Destination $saved -Force }
  }
  $st | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

$idx = [System.IO.File]::ReadAllBytes((Join-Path $bk 'LINKDATA.IDX'))
Say ('LINKDATA.BIN에 한글 데이터 ' + $cfg.entries.Count + '개를 추가하는 중...')
$fs = [System.IO.File]::Open($binPath, 'Open', 'ReadWrite', 'None')
try {
  $fs.SetLength([int64]$st.binLength)
  $pos = [int64]$st.binLength
  if ($pos % 2048 -ne 0) { $pos += 2048 - ($pos % 2048) }
  $k = 0
  foreach ($e in $cfg.entries) {
    $data = [System.IO.File]::ReadAllBytes((Join-Path $here ('patch\' + $e.file)))
    $fs.Position = $pos
    $fs.Write($data, 0, $data.Length)
    $o = [int]$e.index * 32
    PutU64 $idx $o ([uint64]$pos)
    if ($e.file.EndsWith('.kz')) {
      $usize = ([uint64]$data[8] * 16777216) + ([uint64]$data[9] * 65536) + ([uint64]$data[10] * 256) + [uint64]$data[11]
      PutU64 $idx ($o + 8) $usize; PutU64 $idx ($o + 16) ([uint64]$data.Length); PutU64 $idx ($o + 24) 1
    } else {
      PutU64 $idx ($o + 8) ([uint64]$data.Length); PutU64 $idx ($o + 16) ([uint64]$data.Length); PutU64 $idx ($o + 24) 0
    }
    $pos += $data.Length
    if ($pos % 2048 -ne 0) { $pos += 2048 - ($pos % 2048) }
    $k++
    if ($k % 100 -eq 0) { Write-Host ("  {0}/{1}" -f $k, $cfg.entries.Count) }
  }
  $fs.SetLength($pos)
  $fs.Flush()
} catch {
  $fs.SetLength([int64]$st.binLength); throw
} finally { $fs.Dispose() }
[System.IO.File]::WriteAllBytes($idxPath, $idx)

foreach ($f in $cfg.files) {
  $dst = Join-Path $root $f.dst
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath (Join-Path $here $f.src) -Destination $dst -Force
  Say ('  교체: ' + $f.dst)
}

# RPCS3 캐시: 예전 일본어 데이터 사본을 백업 후 갱신/삭제
$rps = @(AskRPCS3)
foreach ($rp in $rps) {
  $n = 0
  foreach ($e in $cfg.entries) {
    foreach ($c in (CachePaths $rp ([int]$e.index))) {
      if (-not (Test-Path -LiteralPath $c.full -PathType Leaf)) { continue }
      $saved = Join-Path $bk ('cache\' + (Tag $rp) + '\' + $c.rel)
      if (-not (Test-Path -LiteralPath $saved)) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null; Copy-Item -LiteralPath $c.full -Destination $saved }
      if ($e.file.EndsWith('.kz')) { Remove-Item -LiteralPath $c.full -Force }
      else { Copy-Item -LiteralPath (Join-Path $here ('patch\' + $e.file)) -Destination $c.full -Force }
      $n++
    }
  }
  Say "  RPCS3 캐시 갱신($rp): $n 개"
}
if ($rps.Count -gt 0) {
  $st.rpcs3 = ($rps -join ';')
  $st | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

Say ''
Say '한글패치 적용 완료!' 'Green'
Say ('원본 백업 폴더: ' + $bk + '  (지우지 마세요. 제거할 때 필요합니다)')
