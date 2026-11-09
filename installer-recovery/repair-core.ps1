function Assert-Swim($ok,$message){if(-not $ok){throw $message}};
function Hash-Swim($file){(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()};
function Safe-Swim($file){
 $item=Get-Item -LiteralPath $file -Force;
 while($null -ne $item){
  Assert-Swim (($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-eq 0) 'リンクを含む保存先は修復しません。';
  if($item -is [IO.FileInfo]){$item=$item.Directory}else{$item=$item.Parent};
 };
};
function Manifest-Swim($data){
 Safe-Swim $data;$all=@(Get-ChildItem -LiteralPath $data -Recurse -Force);
 Assert-Swim ($all.Count -le 20000) 'バックアップ対象が多すぎます。';
 Assert-Swim (@($all|Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0 -or $_.Name -match 'write-lock|\.tmp$'}).Count -eq 0) 'リンク・保存ロック・一時ファイルがあります。';
 $files=@($all|Where-Object {-not $_.PSIsContainer});
 Assert-Swim (($files|Measure-Object -Property Length -Sum).Sum -le 2147483648) 'バックアップ対象が2GBを超えています。';
 @($files|ForEach-Object {[pscustomobject]@{path=$_.FullName.Substring($data.Length+1);sha256=Hash-Swim $_.FullName}}|Sort-Object path);
};
function Same-SwimManifest($left,$right){
 $left=@($left);$right=@($right);if($left.Count-ne $right.Count){return $false};
 foreach($item in $left){$matches=@($right|Where-Object {$_.path -ceq $item.path -and $_.sha256 -eq $item.sha256});if($matches.Count-ne 1){return $false}};
 return $true;
};
function Verify-SwimBackup($data,$backup,$manifest,$expectedOriginal){
 Safe-Swim $backup;
 $names=@(Get-ChildItem -LiteralPath $backup -Force|ForEach-Object {$_.Name});
 Assert-Swim ($names.Count-eq 3 -and @($names|Where-Object {$_ -notin @('data','original-uninstaller.exe','data-hashes.json')}).Count-eq 0) '前回のバックアップは未完了か管理外ファイルがあります。削除せず停止します。';
 Safe-Swim (Join-Path $backup 'original-uninstaller.exe');Safe-Swim (Join-Path $backup 'data-hashes.json');
 Assert-Swim ((Hash-Swim (Join-Path $backup 'original-uninstaller.exe'))-eq $expectedOriginal) '前回の元EXEバックアップが一致しません。';
 $saved=@(Get-Content -LiteralPath (Join-Path $backup 'data-hashes.json') -Raw -Encoding UTF8|ConvertFrom-Json);
 $copied=@(Manifest-Swim (Join-Path $backup 'data'));
 Assert-Swim ((Same-SwimManifest $saved $manifest) -and (Same-SwimManifest $copied $manifest) -and (Same-SwimManifest @(Manifest-Swim $data) $manifest)) '現在のデータと前回のバックアップが違います。どちらも変更せず停止します。';
};
function Backup-Swim($data,$backup,$target,$manifest,$expectedOriginal){
 if(Test-Path -LiteralPath $backup){Verify-SwimBackup $data $backup $manifest $expectedOriginal;return};
 Safe-Swim (Split-Path $backup);[IO.Directory]::CreateDirectory($backup)|Out-Null;
 $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false);
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();
 foreach($sid in @($identity.User.Value,'S-1-5-18','S-1-5-32-544')){$rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule)};
 Set-Acl -LiteralPath $backup -AclObject $acl;
 Copy-Item -LiteralPath $data -Destination (Join-Path $backup 'data') -Recurse;
 Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'original-uninstaller.exe');
 $manifest|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $backup 'data-hashes.json') -Encoding UTF8;
 Verify-SwimBackup $data $backup $manifest $expectedOriginal;
};
function Stage-Swim($stage,$fixed,$expectedFixed){
 if(Test-Path -LiteralPath $stage){Safe-Swim $stage;Assert-Swim ((Hash-Swim $stage)-eq $expectedFixed) '残った一時ファイルの内容が違います。削除せず停止します。';return};
 $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);
 try{$stream.Write($fixed,0,$fixed.Length);$stream.Flush($true)}finally{$stream.Dispose()};
 Assert-Swim ((Hash-Swim $stage)-eq $expectedFixed) '修復用一時ファイルの照合に失敗しました。';
};
function Invoke-SwimAtomicReplace($stage,$target,$rollback){
 Assert-Swim (-not [string]::IsNullOrWhiteSpace($rollback)) '置き換え用バックアップのパスが空です。';
 [IO.File]::Replace($stage,$target,$rollback);
};
function Repair-Swim($data,$backup,$target,$stage,$rollback,$fixed,$expectedOriginal,$expectedFixed,$confirmed){
 Assert-Swim ($confirmed -eq $true) '実行の了承がありません。';
 Safe-Swim $target;$current=Hash-Swim $target;
 if($current-eq $expectedFixed){return 'already-fixed'};
 Assert-Swim ($current-eq $expectedOriginal) '元の削除プログラムが一致しません。';
 $sha=[Security.Cryptography.SHA256]::Create();try{$candidate=([BitConverter]::ToString($sha.ComputeHash($fixed))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};
 Assert-Swim ($candidate-eq $expectedFixed) '修復内容のハッシュが違います。';
 Assert-Swim (([IO.Path]::GetFullPath((Split-Path $stage)) -eq [IO.Path]::GetFullPath((Split-Path $target))) -and ([IO.Path]::GetFullPath((Split-Path $rollback)) -eq [IO.Path]::GetFullPath((Split-Path $target)))) '置き換え用ファイルは同じフォルダに限定します。';
 $manifest=@(Manifest-Swim $data);
 if(Test-Path -LiteralPath $rollback){Safe-Swim $rollback;Assert-Swim ((Hash-Swim $rollback)-eq $expectedOriginal) '置き換え用バックアップに別の内容があります。';};
 Backup-Swim $data $backup $target $manifest $expectedOriginal;
 Stage-Swim $stage $fixed $expectedFixed;
 Safe-Swim $target;Assert-Swim ((Hash-Swim $target)-eq $expectedOriginal) '直前に元の削除プログラムが変わりました。';
 Assert-Swim (-not(Test-Path -LiteralPath (Join-Path (Split-Path $data) 'desktop-service.write-lock'))) '内部処理が起動しました。置き換えず停止します。';
 Assert-Swim (Same-SwimManifest @(Manifest-Swim $data) $manifest) 'バックアップ後に大会データが変わりました。';
 Invoke-SwimAtomicReplace $stage $target $rollback;
 Assert-Swim ((Hash-Swim $target)-eq $expectedFixed -and (Hash-Swim $rollback)-eq $expectedOriginal) '置き換え結果を確認できません。バックアップは残っています。';
 Assert-Swim (Same-SwimManifest @(Manifest-Swim $data) $manifest) '修復中にデータが変わりました。バックアップは残っています。';
 return 'repaired';
};
