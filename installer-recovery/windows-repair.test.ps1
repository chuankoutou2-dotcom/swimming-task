$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'repair-core.ps1')
if($PSVersionTable.PSVersion.Major-ne 5){throw 'Windows PowerShell 5.1 is required'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('swim-repair-ci-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$passed=0
function Check($ok,$message){if(-not $ok){throw $message}}
function New-Fixture($name){
 $base=Join-Path $root $name;$data=Join-Path $base 'data';$install=Join-Path $base 'install';$backup=Join-Path $base 'backup'
 [IO.Directory]::CreateDirectory((Join-Path $data 'keys'))|Out-Null;[IO.Directory]::CreateDirectory($install)|Out-Null
 [IO.File]::WriteAllText((Join-Path $data 'swim-data.json'),'synthetic encrypted tournament fixture')
 [IO.File]::WriteAllText((Join-Path $data 'keys/storage.key'),'synthetic-key-no-user-data')
 $target=Join-Path $install 'Uninstall SwimMeetManager.exe';$stage=Join-Path $install 'Uninstall SwimMeetManager.repair.tmp';$rollback=Join-Path $install 'Uninstall SwimMeetManager.repair-original.bak'
 [IO.File]::WriteAllText($target,'synthetic original exe, never executable')
 $fixed=[Text.Encoding]::UTF8.GetBytes('synthetic repaired exe, never executable')
 $hash=[Security.Cryptography.SHA256]::Create();try{$fixedHash=([BitConverter]::ToString($hash.ComputeHash($fixed))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
 return @{base=$base;data=$data;install=$install;backup=$backup;target=$target;stage=$stage;rollback=$rollback;fixed=$fixed;originalHash=Hash-Swim $target;fixedHash=$fixedHash}
}
function Repair-Fixture($f,$confirmed=$true){Repair-Swim $f.data $f.backup $f.target $f.stage $f.rollback $f.fixed $f.originalHash $f.fixedHash $confirmed}
function Case($name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}
try {
 Case 'PowerShell 5.1 reproduces the null backup argument failure' {
  $f=New-Fixture 'null-argument';Stage-Swim $f.stage $f.fixed $f.fixedHash;$failed=$false
  try{[IO.File]::Replace($f.stage,$f.target,$null)}catch{$failed=$true;Write-Output ('OLD_ERROR '+$_.Exception.Message)}
  Check $failed 'The old null argument did not reproduce';Check ((Hash-Swim $f.target)-eq $f.originalHash) 'Original changed after old failure';Check ((Hash-Swim $f.stage)-eq $f.fixedHash) 'Stage changed after old failure'
 }
 Case 'Fresh repair performs real atomic replacement and retains data and original' {
  $f=New-Fixture 'fresh';$before=@(Manifest-Swim $f.data);Check ((Repair-Fixture $f)-eq 'repaired') 'Fresh result';Check ((Hash-Swim $f.target)-eq $f.fixedHash) 'Target not repaired';Check ((Hash-Swim $f.rollback)-eq $f.originalHash) 'Rollback not original';Check (Same-SwimManifest $before @(Manifest-Swim $f.data)) 'Data changed';Verify-SwimBackup $f.data $f.backup $before $f.originalHash
 }
 Case 'Resume the exact previous failure with existing backup and stage, no overwrite of snapshot' {
  $f=New-Fixture 'resume';$manifest=@(Manifest-Swim $f.data);Backup-Swim $f.data $f.backup $f.target $manifest $f.originalHash;Stage-Swim $f.stage $f.fixed $f.fixedHash
  $meta=Join-Path $f.backup 'data-hashes.json';$snapshot=Hash-Swim $meta;$stamp=(Get-Item -LiteralPath $meta).LastWriteTimeUtc
  try{[IO.File]::Replace($f.stage,$f.target,$null)}catch{}
  Check ((Repair-Fixture $f)-eq 'repaired') 'Resume failed';Check ((Hash-Swim $meta)-eq $snapshot) 'Snapshot overwritten';Check ((Get-Item -LiteralPath $meta).LastWriteTimeUtc-eq $stamp) 'Snapshot rewritten';Check (-not(Test-Path -LiteralPath $f.stage)) 'Stage not consumed'
  Check ((Repair-Fixture $f)-eq 'already-fixed') 'Idempotence failed'
 }
 Case 'Changed data refuses reuse and preserves all versions' {
  $f=New-Fixture 'changed-data';Backup-Swim $f.data $f.backup $f.target @(Manifest-Swim $f.data) $f.originalHash
  [IO.File]::WriteAllText((Join-Path $f.data 'swim-data.json'),'newer synthetic tournament data');$before=@(Manifest-Swim $f.data);$failed=$false
  try{Repair-Fixture $f}catch{$failed=$true};Check $failed 'Changed data accepted';Check ((Hash-Swim $f.target)-eq $f.originalHash) 'Target changed';Check (Same-SwimManifest $before @(Manifest-Swim $f.data)) 'New data changed'
 }
 Case 'Unknown stage is retained and never replaces target' {
  $f=New-Fixture 'wrong-stage';[IO.File]::WriteAllText($f.stage,'unknown');$failed=$false;try{Repair-Fixture $f}catch{$failed=$true};Check $failed 'Unknown stage accepted';Check ((Hash-Swim $f.target)-eq $f.originalHash) 'Target changed';Check ([IO.File]::ReadAllText($f.stage)-eq 'unknown') 'Unknown stage removed'
 }
 Case 'Unknown rollback and incomplete backup stop safely' {
  $f=New-Fixture 'wrong-rollback';[IO.File]::WriteAllText($f.rollback,'unknown');$failed=$false;try{Repair-Fixture $f}catch{$failed=$true};Check $failed 'Unknown rollback accepted';Check ((Hash-Swim $f.target)-eq $f.originalHash) 'Target changed'
  $f=New-Fixture 'partial';[IO.Directory]::CreateDirectory($f.backup)|Out-Null;$failed=$false;try{Repair-Fixture $f}catch{$failed=$true};Check $failed 'Incomplete backup accepted';Check ((Hash-Swim $f.target)-eq $f.originalHash) 'Target changed'
 }
 Case 'Cancellation performs no writes' {
  $f=New-Fixture 'cancel';$failed=$false;try{Repair-Fixture $f $false}catch{$failed=$true};Check $failed 'Cancellation accepted';Check (-not(Test-Path -LiteralPath $f.backup)) 'Backup created without approval';Check (-not(Test-Path -LiteralPath $f.stage)) 'Stage created without approval'
 }
 Case 'Existing identical rollback is safe with Windows File.Replace' {
  $f=New-Fixture 'known-rollback';[IO.File]::Copy($f.target,$f.rollback);Check ((Repair-Fixture $f)-eq 'repaired') 'Existing rollback failed';Check ((Hash-Swim $f.rollback)-eq $f.originalHash) 'Rollback changed'
 }
 Case 'Actual CMD launcher handles Japanese and spaces, preview then typed approval' {
  $f=New-Fixture 'launcher';$kit=Join-Path $root '水泳 launcher space';[IO.Directory]::CreateDirectory($kit)|Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher.cmd') -Destination (Join-Path $kit 'repair.cmd')
  $core=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'repair-core.ps1'),[Text.Encoding]::UTF8)
  $entry=@'
& {
__CORE__
$ErrorActionPreference='Stop'
$target=Join-Path $env:SWIM_FIXTURE_ROOT 'install/Uninstall SwimMeetManager.exe'
$data=Join-Path $env:SWIM_FIXTURE_ROOT 'data';$backup=Join-Path $env:SWIM_FIXTURE_ROOT 'backup'
if($env:SWIM_REPAIR_PHASE-eq 'preview'){Write-Output 'PREVIEW 日本語';exit 42}
if($env:SWIM_REPAIR_APPROVAL-cne 'REPAIR'){exit 1}
$fixed=[Text.Encoding]::UTF8.GetBytes('synthetic repaired exe, never executable')
Repair-Swim $data $backup $target (Join-Path $env:SWIM_FIXTURE_ROOT 'install/Uninstall SwimMeetManager.repair.tmp') (Join-Path $env:SWIM_FIXTURE_ROOT 'install/Uninstall SwimMeetManager.repair-original.bak') $fixed $env:SWIM_ORIGINAL_HASH $env:SWIM_FIXED_HASH $true
Write-Output 'LAUNCHER_SUCCESS'
}

'@
  $entry=$entry.Replace('__CORE__',$core)+[Environment]::NewLine+[Environment]::NewLine
  [IO.File]::WriteAllText((Join-Path $kit 'repair.ps1'),$entry,(New-Object Text.UTF8Encoding($false)))
  $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$env:ComSpec;$start.Arguments='/d /c '+[char]34+[char]34+(Join-Path $kit 'repair.cmd')+[char]34+[char]34;$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.EnvironmentVariables['SWIM_FIXTURE_ROOT']=$f.base;$start.EnvironmentVariables['SWIM_ORIGINAL_HASH']=$f.originalHash;$start.EnvironmentVariables['SWIM_FIXED_HASH']=$f.fixedHash
  $p=New-Object Diagnostics.Process;$p.StartInfo=$start;Check ($p.Start()) 'CMD not started';$p.StandardInput.WriteLine('REPAIR');$p.StandardInput.WriteLine('');$p.StandardInput.Close();Check ($p.WaitForExit(30000)) 'CMD timeout';$output=$p.StandardOutput.ReadToEnd();$errorText=$p.StandardError.ReadToEnd();Write-Output $output;Check ($p.ExitCode-eq 0) ('CMD failed '+$errorText);Check ($output.Contains('LAUNCHER_SUCCESS')) ('No launcher success '+$errorText);Check ((Hash-Swim $f.target)-eq $f.fixedHash) 'CMD did not repair'
 }
 Write-Output ('RESULT '+$passed+' PASS; Windows PowerShell '+$PSVersionTable.PSVersion.ToString()+'; CLR '+[Environment]::Version)
} finally {
 if($root.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $root -Leaf)-like 'swim-repair-ci-*'){Remove-Item -LiteralPath $root -Recurse -Force}
}
