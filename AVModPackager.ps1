## NAMESPACES
using namespace System
using namespace System.Xml
using namespace System.Text
using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Windows.Forms
using namespace System.Drawing

## PARAMETERS
param($repositoryForkUrl = $null)

## Assemblies
Add-Type -AssemblyName "System.Windows.Forms"
Add-Type -AssemblyName "System.Drawing"

## CONSTANTS
$ScriptRoot = if (-not $PSScriptRoot) { Split-Path -Parent (Convert-Path ([environment]::GetCommandLineArgs()[0])) } else { $PSScriptRoot }
$RemoteModRepository = "https://github.com/MaragonMH/AxiomVergeMods.git"
$HighlightColor = "239,118,118"
$BackgroundColor = "#242424"
$SidebarColor = "#303030"
$FooterColor = "#3c3c3c"
$TextColor = "white"
$Font = "Nirmala UI"
$NormalFont = [Font]::new($Font, 9)
$HeaderFont = [Font]::new($Font, 12, [FontStyle]::Bold)
$SubHeaderFont = [Font]::new($Font, 10, [FontStyle]::Bold)
$SubSubHeaderFont = [Font]::new($Font, 9, [FontStyle]::Bold)

## UI-Elements
$Window = $null
$Workspace = $null
$Sidebar = $null
$GamesContainer = $null
$PackagesContainer = $null
$PackagesHeader = $null
$SidebarMarker = $null
$Footer = $null
$FooterInput = $null
$FooterInputFrame = $null
$FooterButton = $null

## SCRIPTS

## CLASSES
class GameData {
    [String] $GameIdentifier
    [String] $GamePath
    [String] $Gameversion
    [Boolean] $IsBeta = $false

    GameData($gameIdentifier, $gamePath){
        $this.GameIdentifier = $gameIdentifier
        $this.GamePath = $gamePath
        $versionInfo = (Get-ChildItem "$gamePath/*.exe" | Where-Object {
            $_.Name -match "^AxiomVerge.?\.exe$" }).VersionInfo
        $this.Gameversion = $versionInfo.ProductVersion
        # TODO: Remove the special condition for AV1 once the changes have been made
        $isAV1SteamBeta = $gameIdentifier -eq "AV1-Steam" -and ([version]$this.Gameversion).Revision -gt 0
        $this.IsBeta = $versionInfo.PreRelease -or $isAV1SteamBeta
    }
}
class ModData {
    [String] $Description
    [String] $Author
    [String] $Patch
    [String] $Game
    [String] $Platform
    [String] $Modname
    [String] $Modversion
    [String] $Gameversion
    [String[]] $Dependencies
    [String[]] $Conflicts
    [Bool] $Installed
    [String] $Package
    $History
    [String]GameIdentifier(){ return "$($this.Game)-$($this.Platform)" }

    ModData($description, $author, $patch, $game, $platform, $modname, $modversion, $gameversion, $dependencies, $conflicts, $installed, $history, $package){
        $this.Description = $description
        $this.Author = $author
        $this.Patch = $patch
        $this.Game = $game
        $this.Platform = $platform
        $this.Modname = $modname
        $this.Modversion = $modversion
        $this.Gameversion = $gameversion
        $this.Dependencies = $dependencies
        $this.Conflicts = $conflicts
        $this.Installed = $installed
        $this.History = $history
        $this.Package = $package
    }
}

## REPOSITORY FUNCTIONS
function initializeRepository($repositoryName, $gamePath, $gameIdentifier, $forkedRepo = ""){
    function initHooks(){
        # Update the *.avmod file with your current changes and increment the tag
        Set-Content ".git/hooks/post-commit" "exec powershell.exe -ExecutionPolicy Bypass -file .git/hooks/post-commit.ps1"
        Set-Content ".git/hooks/post-commit.ps1" $postCommitHook

        Set-Content ".git/hooks/pre-push" $prePushHook

        Set-Content ".git/avmod-merger.ps1" $mergeDriver
        Add-Content ".git/info/attributes" "*.avmod merge=avmod"
        Add-Content ".git/config" $mergeDriverConfig
    }

    # Initializes the main github repository
    # Be careful this enters the directory automatically
    $developmentDirectory = "Dev"
    $gamePath = $gamePath
    $gameExe = Get-Item "$gamePath/AxiomVerge*.exe" | Where-Object { $_.Name -match "^AxiomVerge.?\.exe$" }
    $gameName = $gameExe.Name
    $gameBaseName = $gameExe.BaseName
    
    # Clone base repository
    if($forkedRepo){
        # Add remote mod repository fork
        git clone -q $forkedRepo .
    } else {
        git clone -q $RemoteModRepository .
    }
    git checkout -q --orphan $gameIdentifier
    git rm -rf .
    Get-ChildItem $gamePath | ForEach-Object { Copy-Item $_.FullName . -Recurse }
    
    # Import Saves
    if(Test-Path "../Saves") { Move-Item "../Saves" "Saves" }
    else { New-Item "Saves" -ItemType Directory }
    

    # Decompile executable
    New-Item "$developmentDirectory" -ItemType Directory 
	ilspycmd "$gameName" -o "$developmentDirectory" -p -lv CSharp7_3

	# Change build directory to original directory for convienience in vs
	[xml]$projFile = Get-Content "$developmentDirectory/$gameBaseName.csproj"
    $projFile.Project.PropertyGroup[0].TargetFramework = "net48"
    $projFile.Project.PropertyGroup[1].LangVersion = "latest"
    $projFile.Project.PropertyGroup[0].AppendChild($projFile.CreateElement("OutDir"))
    $projFile.Project.PropertyGroup[0].OutDir = "../"
    $target = $projFile.CreateElement("Target")
    $target.SetAttribute("Name", "PreBuild")
    $target.SetAttribute("BeforeTargets", "PreBuildEvent")
    $projFile.Project.AppendChild($target)
    $exec = $projFile.CreateElement("Exec")

    $zipCommand = "Compress-Archive -Force OuterBeyond/EmbeddedContent.Content/* OuterBeyond/EmbeddedContent.Content.zip;"

    $exec.SetAttribute("Command", "powershell.exe -NonInteractive -executionpolicy Bypass -command `"& { $zipCommand } `"")
    $exec.SetAttribute("WorkingDirectory", "`$(MSBuildProjectDirectory)")
    $projFile.Project.Target.AppendChild($exec)
    # Be careful this save option is not relativ to the current location 
	$projFile.Save("$repositoryName/$developmentDirectory/$gameBaseName.csproj")

	# Unzip the EmbeddedContent Files
	Expand-Archive "$developmentDirectory/OuterBeyond/EmbeddedContent.Content.zip" "$developmentDirectory/OuterBeyond/EmbeddedContent.Content"

    # Create the Modfile
    $modFileHandle = New-object XmlDocument
    $modFileHandle.LoadXml("<AVMods></AVMods>")
    # Be careful this save option is not relativ to the current location 
    $modFileHandle.Save("$repositoryName/.avmod")

    # Set config
    git config user.name "AVModPackager"
    git config user.email "offline"

	# Initialize Repository for patches
	Set-Content ".gitignore" "AxiomVergeMods/`r`nSaves/`r`nLog/`r`nAxiomVerge*.exe`r`nAxiomVerge*.exe.config`r`n*.avmod`r`n**/bin/`r`n*/obj/`r`n**/.vs/`r`n*.sln`r`n*.csproj.user`r`n*.zip`r`n*.rej`r`n*.pdb"
    # initHooks
    # Supress crlf warnings 
    git config core.safecrlf false
	git add -A
	git commit -m "Initialized Repo"
	git tag "$gameIdentifier-1.0.0.0" HEAD
}
function applyMod([ModData]$modData, $repositoryName){
    # Set Author
    git config user.name $modData.Author

    # Creates the initial commit for the new mod as new branch
    if($modData.Dependencies){
        git checkout -q -b $modData.Modname $modData.Dependencies[0]
        if($modData.Dependencies.Count -gt 1){
            git merge $modData.Dependencies -m "Init new Mod: $($modData.Modname)"
        } else {
            git commit --allow-empty -m "Init new Mod: $($modData.Modname)"
        }
        git tag "$($modData.Modname)-1.0.0.0" -m "$($modData.Dependencies -join "\n")"
    } else {
        git checkout -q tags/$($modData.GameIdentifier())-1.0.0.0 -b $modData.Modname
        git commit --allow-empty -m "Init new Mod: $($modData.Modname)"
        git tag "$($modData.Modname)-1.0.0.0"
    }

    # Set Description 
    git config branch.$($modData.Modname).note $modData.Description

    # Create the patched commit with version as a tag
    $modData.History | Sort-Object Modversion | ForEach-Object{
        [Encoding]::Unicode.GetString([Convert]::FromBase64String($_.Patch)) | Set-Content temp
        # The application of the diff file should be done with different severity
        git apply temp --whitespace=nowarn
        if($LASTEXITCODE -ne 0) {
            git reset --hard
            git apply temp -C 1 --recount --reject --ignore-whitespace
            if($LASTEXITCODE -ne 0) {
                displayInfoBox "Error:`n`nThe mod $($_.Modname) could not be applied. Installation will continue, but without this mod. Contact the mod-creator for help"
                git reset --hard
                return
            } else {
                displayInfoBox "Warning:`n`nThe mod $($_.Modname) was applied in a degraded state. This may work, but it is advisable to inform the mod-creator about the defect"
            }
        }
        Remove-Item temp
        git add -A
        git commit -m $_.Message
        git tag "$($_.Modname)-$($_.Modversion)"
    }

    # Update mod file
    $modFileHandle = [xml](Get-Content ".avmod")
    $modData.History | Foreach-Object {
        $node = $modFileHandle.ImportNode($_, $true)
        $modFileHandle.FirstChild.AppendChild($node) 
    }
    $modFileHandle.Save("$repositoryName/.avmod")
}
function buildPackage($gameIdentifier){
    # Merges all branches into the main branch
    git checkout -q $gameIdentifier
    $branches = git branch --format "%(refname:short)" --contains $gameIdentifier
    if($branches) { git merge $branches }

    # Build Game
    dotnet build "Dev"
    if($LASTEXITCODE -ne 0){
        displayInfoBox "Your build failed"
    } else {
        displayInfoBox "Your build succeeded"
    }
}
function packageMod(){
    # Block specific package names
    $packageName = $FooterInput.Text -replace "[$([RegEx]::Escape([string][IO.Path]::GetInvalidFileNameChars()))]+","_"
    if($SidebarMarker.Page.Parent -eq $PackagesContainer) { $packageName = $SidebarMarker.Page.Text }
    if(($packageName -in @("AxiomVergeMods", "", "Saves", "Mod")) -or ($packageName.StartsWith("AV"))){ 
        displayInfoBox "Invalid package name. Check that it is not Empty and does not start with AV or match AxiomVergeMods, Saves, Mod."
        return
    }

    # Check for duplicates
    if(Test-Path $packageName){
        $result = displayInfoBox "This package already exists. Do you want to overwrite it" $true
        if($result -ne [DialogResult]::Yes) { return }
        Move-Item "$packageName/Saves" "Saves"
        Remove-Item $packageName -Recurse -Force
    }

    # Prepare the package directory
    New-Item $packageName -ItemType Directory
    Set-Location $packageName
    initializeRepository $packageName $SidebarMarker.Page.GameData.GamePath $SidebarMarker.Page.GameData.GameIdentifier

    # Make sure to only discard old mods. This only happens for packages and their automatic updates
    $mods = $Workspace.Controls.Where{$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true} | Select-Object -ExpandProperty ModData
    $mods = $mods | Group-Object Modname | ForEach-Object { 
        $maxVersion = ($_.group.Modversion | Measure-Object -Maximum).Maximum
        $recentMod = $_.group | Where-Object { $_.Modversion -eq $maxVersion }
        $recentMod
    }

    # Make sure that all mods are installed in the correct order
    if ($null -eq $mods) { $mods = @() }
    if ($mods -isnot [Array]) { $mods = @($mods) }
    $mods = [ArrayList]$mods
    $installedMods = New-Object HashSet[String]
    while($mods.Count -ne 0){
        $mod = $mods[0]
        $mods.RemoveAt(0)
        # Check if this mod has all dependencies installed
        if(($mod.Dependencies.Where{$_ -notin $installedMods}).Count -eq 0){
            applyMod $mod $packageName $SidebarMarker.Page.GameIdentifier
            $installedMods.Add($mod.Modname) | Out-Null
        } else {
            $mods.Add($mod)
        }
    }
    buildPackage $SidebarMarker.Page.GameIdentifier
    Set-Location "../"

    # Refresh Window
    refreshUI
}

## PRELOAD FUNCTIONS
function installDependencies(){
    # Install winget as a package manager
    if(!(Get-Command -ErrorAction SilentlyContinue winget)){
        $URL = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $URL = (Invoke-WebRequest -Uri $URL).Content | ConvertFrom-Json |
                Select-Object -ExpandProperty "assets" |
                Where-Object "browser_download_url" -Match '.msixbundle' |
                Select-Object -ExpandProperty "browser_download_url"

        # download
        Invoke-WebRequest -Uri $URL -OutFile "Setup.msix" -UseBasicParsing

        # install
        Add-AppxPackage -Path "Setup.msix"

        # delete file
        Remove-Item "Setup.msix"
    }
    if(!(Get-Command -ErrorAction SilentlyContinue winget)){ $env:Path += ';%UserProfile%\AppData\Local\Microsoft\WindowsApps' }

    # Install the required dependencies
    $dependencies = @(
        "Git.Git"
        "Microsoft.DotNet.SDK.7"
        "Microsoft.DotNet.Framework.DeveloperPack_4"
        "Microsoft.DotNet.DesktopRuntime.3_1"
        "AngusJohnson.ResourceHacker"
    ) 
    $dependencies | Foreach-Object { Start-Job -Arg $_ -ScriptBlock {
        param($dep) winget install $dep --no-upgrade --silent --accept-source-agreements --accept-package-agreements
    }} | Wait-Job | Out-Null
    
    # Reload Path
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")

    # Remove x86 dotnet from environment
    $env:Path = $env:Path -replace "C:\\Program Files \(x86\)\\dotnet\\(;|$)",""
    
    # Add to Path
    if(!(Get-Command git -ErrorAction SilentlyContinue)){ $env:Path += ';C:\Program Files\Git\usr\bin' }
    if(!(Get-Command dotnet -ErrorAction SilentlyContinue)){ $env:Path += ';C:\Program Files\dotnet' }
    if(!(Get-Command ResourceHacker -ErrorAction SilentlyContinue)){ $env:Path += ';C:\Program Files (x86)\Resource Hacker' }

    # Install Decompiler
    if(!(Get-Command ilspycmd -ErrorAction SilentlyContinue)){ dotnet tool install --global ilspycmd --version 7.1.0.6543 }

    # Configure script for git
    # $env:GIT_REDIRECT_STDERR = "2>&1"

    # Download or update all available Mods
    if (Test-Path "AxiomVergeMods") {
        git -C "AxiomVergeMods" status -s | Out-Null
        if($LASTEXITCODE -eq 0){
            git -C "AxiomVergeMods" pull | Out-Null
        }
    } else {
        git clone -q $RemoteModRepository "AxiomVergeMods"
    }
}
function loadIcon(){
    # powershell does not block this command properly
    cmd /c ResourceHacker -open "AVModPackager.exe"-save "AV-Sources/check.res" -action extract -mask ICONGROUP
    if(Test-Path "AV-Sources/check.res"){
        Remove-Item "AV-Sources/*.res"
        return
    }
    Get-Item "AV-Sources/*/AxiomVerge*.exe" | 
        Where-Object { $_.Name -match "^AxiomVerge.?\.exe$" } | ForEach-Object{ 
        cmd /c ResourceHacker -open $_.FullName -save "AV-Sources/icon.res" -action extract -mask ICONGROUP}
    
    $id = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $command = { param($id) 
        Wait-Process -id $id -ErrorAction SilentlyContinue
        cmd /c ResourceHacker -open AVModPackager.exe -save AVModPackager.exe -action addskip -res AV-Sources/icon.res
        Remove-Item AV-Sources/icon.res
        Start-Process AVModPackager.exe
    }
    Start-Process powershell -ArgumentList "-WindowStyle Minimized -command & {$command} $id"
    Exit
}
function loadGames(){
    # Locate Steam and Epic AV1 and AV2 to add available Games to sidebar
    $supportedGames = @{
        "AV1-Steam" = "C:/Program Files (x86)/Steam/steamapps/common/Axiom Verge"
        "AV2-Steam" = "C:/Program Files (x86)/Steam/steamapps/common/Axiom Verge 2"
        "AV1-Epic" = "C:/Program Files/Epic Games/AxiomVerge1"
        "AV2-Epic" = "C:/Program Files/Epic Games/AxiomVerge2"
    }
    foreach ($supportedGame in $supportedGames.Keys.Where{ Test-Path $supportedGames[$_]}) {
        $gameData = [GameData]::new($supportedGame, $supportedGames[$supportedGame])
        $storagePath = "$((Get-Location).Path)/AV-Sources/$supportedGame"
        
        # Store currently available Version (Beta/Original) for use when the other is selected
        if($gameData.IsBeta) { $alternateGamePath = "$storagePath-Beta" }
        else { $alternateGamePath = "$storagePath-Original" }
        if(Test-Path $alternateGamePath){
            if($gameData.Gameversion -gt [GameData]::new("", $alternateGamePath).Gameversion) { 
                Remove-Item $alternateGamePath -Recurse -Force }}
        if(!(Test-Path $alternateGamePath)){
            Copy-Item $gameData.GamePath $alternateGamePath -Recurse -Force }

        # Create Games
        $orgGamePath = "$storagePath-Original"
        if(Test-Path $orgGamePath){
            $gameData = [GameData]::new($supportedGame, $orgGamePath)
            createPageButton $gameData.GameIdentifier $gameData $true }
        $betaGamePath = "$storagePath-Beta"
        if(Test-Path $betaGamePath){
            $gameData = [GameData]::new("$supportedGame-Beta", $betaGamePath)
            createPageButton $gameData.GameIdentifier $gameData $true }
    }
}
function loadAvailableMods(){
    # Add all available mods
    Get-ChildItem "AxiomVergeMods/*.avmod", "*.avmod" | ForEach-Object {
        [xml]$AVMod = Get-Content $_.FullName
        $AVMod.AVMods.Mod | Group-Object Game, Platform | ForEach-Object {
            $modHistory = $_.group
            $maxVersion = ($modHistory.Modversion | Measure-Object -Maximum).Maximum
            $recentMod = $modHistory | Where-Object { $_.Modversion -eq $maxVersion }
            $modData = [ModData]::new($recentMod.Description, $recentMod.Author, $recentMod.Patch, $recentMod.Game, $recentMod.Platform, $recentMod.Modname, $recentMod.Modversion, $recentMod.Gameversion, $recentMod.Dependencies.Dependency, $recentMod.Conflicts.Conflict, $false, $modHistory, "")
            createCollapsible $modData
        }
    }
}
function loadInstalledPackages(){
    # Add all installed packages
    Get-ChildItem -Directory | Where-Object {Test-Path "$($_.FullName)/.avmod"} | ForEach-Object {
        # Assume that every package has uniform game/platform
        $packageMods = ([xml](Get-Content "$($_.FullName)/.avmod")).AVMods.Mod
        if (!$packageMods) { return }
        if ($packageMods -is [Array]) { $firstMod = $packageMods[0] }
        else { $firstMod = $packageMods }
        # Create page
        $packageName = $_.Name
        $gameIdentifier = "$($firstMod.Game)-$($firstMod.Platform)"
        $gameHeader = $GamesContainer.Controls.Where{$_.GameData.GameIdentifier -eq $gameIdentifier }
        if($gameHeader) { $gameData = $gameHeader.GameData }
        else { $gameData = $null}
        createPageButton $packageName $gameData $false

        # Add installed mods
        [xml]$AVMod = Get-Content "$($_.FullName)/.avmod"
        $AVMod.AVMods.Mod | Group-Object Modname | ForEach-Object {
            $modHistory = $_.group
            $maxVersion = ($modHistory.Modversion | Measure-Object -Maximum).Maximum
            $recentMod = $modHistory | Where-Object { $_.Modversion -eq $maxVersion}
            $modData = [ModData]::new($recentMod.Description, $recentMod.Author, $recentMod.Patch, $recentMod.Game, $recentMod.Platform, $recentMod.Modname, $recentMod.Modversion, $recentMod.Gameversion, $recentMod.Dependencies.Dependency, $recentMod.Conflicts.Conflict, $true, $modHistory, $packageName)
            createCollapsible $modData
        }
    }
}
function unloadInstalledPackages(){
    foreach($mod in $Workspace.Controls.Where{$_.ModData.Package}){
        $Workspace.Controls.Remove($mod)
        $mod.Dispose()
    }
    foreach($packageElement in $PackagesContainer.Controls.Where{$_ -is [Button]}){
        $PackagesContainer.Controls.Remove($packageElement)
        $packageElement.Dispose()
    }
}

## UI FUNCTIONS
function adjustMods(){
    # Ensure that the mod configuration is valid and reset if not

    function resetMods(){
        foreach($mod in $Workspace.Controls.Where{ !$_.ModData.Installed }){
            $mod.CheckBox.Checked = $false
        }
    }

    function checkMods(){
        $dependencies = New-Object HashSet[String]
        $violations = New-Object HashSet[String]
        [version]$minGameversion = "1.0.0.0"
        $conflicts = New-Object HashSet[String]
        # Fetch all dependencies and conflicts in the current mod selection
        foreach($mod in $Workspace.Controls.Where{$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true}){
            foreach($dependency in $mod.ModData.Dependencies) { 
                $dependencies.Add($dependency) | Out-Null }
            foreach($conflict in $mod.ModData.Conflicts) { $conflicts.Add($conflict) | Out-Null }
            if($minGameversion -lt [version]$mod.ModData.Gameversion) { 
                $minGameversion = [version]$mod.ModData.Gameversion }
        }
        # Check if all of these are satisfied
        foreach($mod in $Workspace.Controls.Where{$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true}){
            $dependencies.Remove($mod.ModData.Modname) | Out-Null
            if($mod.ModData.Modname -in $conflicts) { $violations.Add($mod.ModData.Modname) | Out-Null }
        }
        return $dependencies, $violations, $minGameversion
    }

    $dependencies, $violations, $minGameversion = checkMods $Workspace
    while($dependencies.Count -ne 0){
        # Try to enable dependencies
        foreach($mod in $Workspace.Controls.Where{$_.Visible -eq $true}){
            if($mod.ModData.Modname -in $dependencies){
                $mod.CheckBox.Checked = $true
                $dependencies.Remove($mod.ModData.Modname)
            }
        }
        if($dependencies.Count -ne 0) { 
            resetMods
            displayInfoBox "Aborting. Not all required dependencies could be enabled`n`nMissing Dependencies:`n$($dependencies -join "`n")"
            return
        }
        $dependencies, $violations, $minGameversion = checkMods
    }
    if($violations.Count -ne 0) {
        resetMods
        displayInfoBox "Your mod selection has conflicts`n`nConflicts:`n$($violations -join "`n")"
        return
    }
    if($minGameversion -gt [version]$SidebarMarker.Page.GameData.Gameversion){
        resetMods
        displayInfoBox "Your gameversion is outdated and does not support this mod. Please update your game`n`nCurrent Gameversion: $($SidebarMarker.Page.GameData.Gameversion)`nRequired Gameversion: $($minGameversion)"
    }
}
function createPageButton($name, [GameData]$gameData, $isGame){
    $pageButton = New-object Button
    $pageButton.Dock = "Top"
    $pageButton.Height = 40
    $pageButton.Font = $SubHeaderFont
    $pageButton.Text = $name
    $pageButton.TextAlign = "MiddleRight"
    $pageButton.FlatAppearance.BorderSize = 0
    $pageButton.FlatStyle = "Flat"
    $pageButton.Add_Click({ selectPage })

    # Prepare Links
    $pageButton | Add-Member NoteProperty GameData $gameData

    if($isGame) { $GamesContainer.Controls.Add($pageButton) }
    else { $PackagesContainer.Controls.Add($pageButton) }
}
function createCollapsible([ModData]$modData){
    function generateModInfo($modData){
        $dependenciesText = $modData.Dependencies -join ", "
        $conflictsText = $modData.Conflicts -join ", "
        return " $($modData.Description)`n Author: $($modData.Author)`n Modversion: $($modData.Modversion)`n Gameversion: $($modData.Gameversion)`n Dependencies: $dependenciesText`n Conflicts: $conflictsText"
    }

    $collapsibleContainer = New-object Panel
    $collapsibleContainer.Dock = "Top"
    $collapsibleContainer.AutoSize = $true
    $collapsibleContainer.Visible = $false

    $collapsibleHeaderContainer = New-object Panel
    $collapsibleHeaderContainer.Dock = "Top"
    $collapsibleHeaderContainer.Height = 40

    $collapsibleButton = New-object Button
    $collapsibleButton.Dock = "Fill"
    $collapsibleButton.AutoSize = $true
    $collapsibleButton.Font = $SubSubHeaderFont
    $collapsibleButton.Text = $modData.Modname
    $collapsibleButton.TextAlign = "MiddleLeft"
    $collapsibleButton.FlatAppearance.BorderSize = 0
    $collapsibleButton.FlatStyle = "Flat"
    if($modData.Installed) {$collapsibleButton.ForeColor = $HighlightColor}
    $collapsibleButton.Add_Click({
        $collapsibleContent = $this.Content
        if($collapsibleContent.Visible -eq $true){
            $collapsibleContent.Visible = $false
        } else {
            $collapsibleContent.Visible = $true
        }
    })

    $modCheckbox = New-Object CheckBox
    $modCheckbox.Dock = "Right"
    $modCheckbox.FlatStyle = "Flat"
    $modCheckbox.Width = 60
    $modCheckbox.TextAlign = "MiddleCenter"
    if($modData.Installed) { 
        $modCheckbox.Checked = $true
        $modCheckbox.AutoCheck = $false
    }
    $modCheckbox.Add_Click({
        $this.Header
        if($this.Mod.ModData.Installed){ return }
        adjustMods
    })

    $collapsibleBodyContainer = New-object Panel
    $collapsibleBodyContainer.Dock = "Top"
    $collapsibleBodyContainer.AutoSize = $true
    $collapsibleBodyContainer.Visible = $false

    $modInfo = New-object Label
    $modInfo.Dock = "Fill"
    $modInfo.AutoSize = $true
    $modInfo.Font = $NormalFont
    $modInfo.Text = generateModInfo($modData)

    $collapsibleBodyContainer.Controls.Add($modInfo)

    $collapsibleHeaderContainer.Controls.Add($modCheckbox)
    $collapsibleHeaderContainer.Controls.Add($collapsibleButton)
    
    $collapsibleContainer.Controls.Add($collapsibleBodyContainer)
    $collapsibleContainer.Controls.Add($collapsibleHeaderContainer)
    
    # Prepare Links
    $collapsibleContainer | Add-Member NoteProperty ModData $modData
    $modCheckbox | Add-Member NoteProperty Mod $collapsibleContainer
    $collapsibleButton | Add-Member NoteProperty Content $collapsibleBodyContainer
    $collapsibleContainer | Add-Member NoteProperty CheckBox $modCheckbox

    $Workspace.Controls.Add($collapsibleContainer)
}
function displayInfoBox($messageBoxText, $isYesNoPrompt = $false){
    $messageBoxForm = New-Object Form
    $messageBoxForm.ShowIcon = $false
    $messageBoxForm.Size = "400,300"
    $messageBoxForm.MinimumSize = "300, 200"
    $messageBoxForm.StartPosition = "CenterScreen"
    $messageBoxForm.BackColor = $BackgroundColor
    $messageBoxForm.ForeColor = $TextColor

    $messageBoxWorkspace = New-object Panel
    $messageBoxWorkspace.Dock = "Fill"
    $messageBoxWorkspace.Padding = 10

    $messageBoxFooter = New-object Panel
    $messageBoxFooter.Dock = "Bottom"
    $messageBoxFooter.Height = 50
    $messageBoxFooter.BackColor = $FooterColor
    $messageBoxFooter.Padding = 10
    
    $messageBoxOkButton = New-Object Button
    $messageBoxOkButton.Text = "OK"
    $messageBoxOkButton.Dock = "Right"
    $messageBoxOkButton.DialogResult = [DialogResult]::OK
    $messageBoxOkButton.Width = 100
    $messageBoxOkButton.BackColor = $HighlightColor
    $messageBoxOkButton.ForeColor = $FooterColor
    $messageBoxOkButton.Font = $SubHeaderFont
    $messageBoxOkButton.FlatAppearance.BorderSize = 0
    $messageBoxOkButton.FlatStyle = "Flat"
    $messageBoxFooter.Controls.Add($messageBoxOkButton)
    
    if($isYesNoPrompt){
        $messageBoxOkButton.Text = "Yes"
        $messageBoxOkButton.DialogResult = [DialogResult]::Yes
        $messageBoxNoButton = New-Object Button
        $messageBoxNoButton.Text = "No"
        $messageBoxNoButton.Dock = "Left"
        $messageBoxNoButton.DialogResult = [DialogResult]::No
        $messageBoxNoButton.Width = 100
        $messageBoxNoButton.Font = $SubHeaderFont
        $messageBoxNoButton.FlatAppearance.BorderSize = 0
        $messageBoxNoButton.FlatStyle = "Flat"
        $messageBoxFooter.Controls.Add($messageBoxNoButton)
    }
    
    $messageBoxLabel = New-Object Label
    $messageBoxLabel.Text = $messageBoxText
    $messageBoxLabel.Dock = "Fill"
    $messageBoxLabel.Font = $SubHeaderFont
    $messageBoxWorkspace.Controls.Add($messageBoxLabel)
    
    $messageBoxForm.Controls.Add($messageBoxWorkspace)
    $messageBoxForm.Controls.Add($messageBoxFooter)

    $messageBoxForm.Topmost = $true
    return $messageBoxForm.ShowDialog()
}
function selectPage(){
    # Style Pages
    foreach($sidebarContainer in $Sidebar.Controls){
        foreach($sidebarElements in $sidebarContainer.Controls){
            $sidebarElements.ForeColor = $textcolor
    }}
    $this.ForeColor = $HighlightColor
    $SidebarMarker.Visible = $true
    $SidebarMarker.Location = [Point]::new(0, $this.Location.Y + $this.Parent.Location.Y)
    
    # Prepare Links
    $SidebarMarker | Add-Member NoteProperty -Force Page $this

    # Customize Footer
    if($this.Parent -eq $GamesContainer){
        $Footer.Visible = $true
        $FooterInputFrame.Visible = $true
        $FooterButton.Text = "Package"
    } elseif (!$this.GameData) {
        $Footer.Visible = $false
    } else {
        $Footer.Visible = $true
        $FooterInputFrame.Visible = $false
        $FooterButton.Text = "Update"
    }
    
    # Show mods
    $Workspace.Location = "0,0"
    foreach($mod in $Workspace.Controls){
        if(!$mod.ModData.Installed){ $mod.CheckBox.Checked = $false }
        # this is always false if the GameData is $null, but that is fine if the Package matches
        $isUpdate = $mod.ModData.GameIdentifier() -eq $this.GameData.GameIdentifier -and $mod.ModData.Package -eq ""
        if($mod.ModData.Package -eq $this.Text -or $isUpdate){
            $mod.Visible = $true
        } else {
            $mod.Visible = $false
        }
    }

    # Propose updates to installed mods if the game is available
    if($this.Parent -eq $GamesContainer -or !$this.GameData) { return }
    foreach($mod in $Workspace.Controls.Where{$_.ModData.Installed}){
        foreach($modUpdate in $Workspace.Controls.Where{ $_.ModData.Modname -eq $mod.ModData.Modname -and !$_.ModData.Installed }){
            if([version]$_.ModData.Modversion -gt [version]$mod.ModData.Modversion){
                $modUpdate.CheckBox.Checked = $true
            } else {
                $modUpdate.Visible = $false
            }
        }
    }
    adjustMods
}
function initializeUI(){
    $scrollAction = {
        $newScroll = $this.Location.Y + $_.Delta / 5;
        $maxHeight = $this.Parent.Height - $this.Height;
        if ($newScroll -gt 0 -or $maxHeight -gt 0) { $newScroll = 0 }
        elseif ($newScroll -lt $maxHeight -and $maxHeight -lt 0) { $newScroll = $maxHeight }
        $this.Location = [Point]::new(0, $newScroll);
    }

    # Fix dpi issues only for script
    if ("ProcessDPI" -as [type]) {} else {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices;public class ProcessDPI {[DllImport("user32.dll", SetLastError=true)]public static extern bool SetProcessDPIAware();}'
    }
    $null = [ProcessDPI]::SetProcessDPIAware()

    # Create Window
    $Window = New-Object Form
    $Window.Text = "Axiom Verge Mod Packager"
    $Window.ShowIcon = $false
    $Window.StartPosition = "CenterScreen"
    $Window.AutoScaleMode  = "Dpi"
    $Window.ClientSize = "800,600"
    $Window.Font = $NormalFont
    $Window.BackColor = $BackgroundColor
    $Window.ForeColor = $TextColor

    $sidebarScrollBox = New-object Panel
    $sidebarScrollBox.Dock = "Left"
    $sidebarScrollBox.Width = 170
    $sidebarScrollBox.BackColor = $SidebarColor

    $Sidebar = New-object Panel
    $Sidebar.Width = 170
    $Sidebar.AutoSize = $true
    $Sidebar.Add_MouseWheel($scrollAction)

    $workspaceScrollBox = New-object Panel
    $workspaceScrollBox.Dock = "Fill"
    
    $Workspace = New-object Panel
    $Workspace.Anchor = "Left, Top, Right"
    $Workspace.AutoSize = $true
    $Workspace.Add_MouseWheel($scrollAction)
    
    $Footer = New-object Panel
    $Footer.Dock = "Bottom"
    $Footer.Height = 50
    $Footer.BackColor = $FooterColor
    $Footer.Padding = 10
    $Footer.Visible = $false
    
    $GamesContainer = New-object Panel
    $GamesContainer.Dock = "Top"
    $GamesContainer.AutoSize = $true
    
    $PackagesContainer = New-object Panel
    $PackagesContainer.Dock = "Top"
    $PackagesContainer.AutoSize = $true
    
    $gamesHeader = New-object Label
    $gamesHeader.Dock = "Top"
    $gamesHeader.Height = 60
    $gamesHeader.Font = $HeaderFont
    $gamesHeader.Text = "Games"
    $gamesHeader.TextAlign = "MiddleLeft"

    $SidebarMarker = New-object Panel
    $SidebarMarker.Height = 40
    $SidebarMarker.Width = 5
    $SidebarMarker.BackColor = $HighlightColor
    $SidebarMarker.Visible = $false

    $PackagesHeader = New-object Label
    $PackagesHeader.Dock = "Top"
    $PackagesHeader.Height = 60
    $PackagesHeader.Font = $HeaderFont
    $PackagesHeader.Text = "Packages"
    $PackagesHeader.TextAlign = "MiddleLeft"

    $Sidebar.Controls.Add($SidebarMarker)
    $Sidebar.Controls.Add($PackagesContainer)
    $Sidebar.Controls.Add($GamesContainer)

    $FooterInputFrame = New-object Panel
    $FooterInputFrame.BackColor = $HighlightColor
    $FooterInputFrame.Dock = "Fill"
    $FooterInputFrame.Padding = 2

    $FooterInput = New-object TextBox
    $FooterInput.AutoSize = $false
    $FooterInput.Dock = "Fill"
    $FooterInput.BackColor = $FooterColor
    $FooterInput.ForeColor = $TextColor
    $FooterInput.Font = $SubHeaderFont
    $FooterInput.BorderStyle = "None"
 
    $FooterButton = New-object Button
    $FooterButton.Dock = "Right"
    $FooterButton.Width = 150
    $FooterButton.BackColor = $HighlightColor
    $FooterButton.ForeColor = $FooterColor
    $FooterButton.Font = $SubHeaderFont
    $FooterButton.Text = "Package"
    $FooterButton.FlatAppearance.BorderSize = 0
    $FooterButton.FlatStyle = "Flat"
    $FooterButton.Add_Click({ packageMod })

    $FooterInputFrame.Controls.Add($FooterInput)

    $Footer.Controls.Add($FooterButton)
    $Footer.Controls.Add($FooterInputFrame)
    
    $sidebarScrollBox.Controls.Add($Sidebar)
    $workspaceScrollBox.Controls.Add($Workspace)
    
    $Window.Controls.Add($workspaceScrollBox)
    $Window.Controls.Add($Footer)
    $Window.Controls.Add($sidebarScrollBox)
    
    loadGames
    # Hotfix loadIcon
    loadAvailableMods
    loadInstalledPackages
    
    $GamesContainer.Controls.Add($gamesHeader)
    $PackagesContainer.Controls.Add($PackagesHeader)

    $Window.ShowDialog() | Out-Null
}
function refreshUI(){
    unloadInstalledPackages
    loadInstalledPackages
    $PackagesHeader.SendToBack()
}

## MAIN
Push-Location $ScriptRoot
installDependencies
initializeUI
Pop-Location