param($repositoryForkUrl = $null)
Push-Location $PSScriptRoot

# Constants
$RemoteModRepository = "https://github.com/MaragonMH/AxiomVergeMods.git"

# Scripts 
$postCommitHook = @'
$branches = (git branch --format "%(refname:short))" | Where-Object { $_ -ne main }
foreach($branch in $branches){ 
    $modFileHandle = New-object System.Xml.XmlDocument
    $modFileHandle.LoadXml("<?xml version="1.0" encoding="utf-8"?><AVMods></AVMods>")

    foreach($tag in (git tag $branch-*.*.*.* -l)){ 
        $mod = $modFileHandle.Mods.CreateElement(Mods)
        $modFileHandle.mods.AppendChild($mod)
        $modname = $mod.CreateElement(Modname)
        $mod.Modname = $branch
        $mod.AppendChild($modname)

        $author = $mod.CreateElement(Author)
        $mod.Author = git show $tag -s --format="%an"
        $mod.AppendChild($author)

        $description = $mod.CreateElement(Description)
        $mod.Description = git config branch.$($branch).note
        $mod.AppendChild($description)

        $game = $mod.CreateElement(Game)
        $mod.Game = $($page.Game)
        $mod.AppendChild($game)

        $platform = $mod.CreateElement(Platform)
        $mod.Platform = $($page.Platform)
        $mod.AppendChild($platform)

        $gameversion = $mod.CreateElement(Gameversion)
        $mod.Gameversion = $($page.Gameversion)
        $mod.AppendChild($gameversion)

        $modversion = $mod.CreateElement(Modversion)
        $mod.Modversion = $tag
        $mod.AppendChild($modversion)

        $dependencies = $mod.CreateElement(Dependencies)
        $mod.AppendChild($dependencies)

        foreach($originMod in (git tag Start-$branch -l --format="%(contents)")){
            $dependency = $dependencies.CreateElement(Dependency)
            $mod.Dependency = $originMod
            $mod.AppendChild($dependency)
        }

        $conflicts = $mod.CreateElement(Conflicts)
        $mod.AppendChild($conflicts)

        foreach($conflictBranch in $branches){
            git merge $conflictBranch --no-ff --no-commit --into-name $branch
            if(!$?){
                $conflict = $dependencies.CreateElement(Conflict)
                $mod.Conflict = $conflictBranch
                $mod.AppendChild($conflict) 
            }
            git merge --abort 
        }

        $patchText = git diff Start-$branch $branch --text
        $patch = $mod.CreateElement(Patch)
        $mod.Patch = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($patchText))
        $mod.AppendChild($patch)
    }
    $modFileHandle.Save(../AxiomVergeMods/$branch.avmod)
}
'@

$prePushHook = @'
while read local_ref local_sha remote_ref remote_sha
do
    if [[ "`$remote_ref" == "refs/heads/"* ]]; then
        # Check if the remote branch exists
        git ls-remote --exit-code . "`$remote_ref" >/dev/null 2>&1
        if [ `$? -ne 0 ]; then
            exit 1
        fi
    fi
done  
'@

$mergeDriverConfig = "[merge ""avmod""]
        name = avmod merge driver
        driver = ""powershell.exe -ExecutionPolicy Bypass -File .git/avmod-merger.ps1 %O %A %B"""

$mergeDriver = @'
param($base, $current, $other)

# Read the contents of the three input files
$baseContent = Get-Content $base
$currentContent = Get-Content $current
$otherContent = Get-Content $other

# TODO: Implement your custom merge logic here
#       This script should produce the merged result as its output

# Example: concatenate the contents of all three files
$result = $baseContent + $currentContent + $otherContent

# Write the merged result to the standard output stream
Write-Output $result
'@

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

    # Install the required dependencies
    winget install Git.Git --no-upgrade
    winget install Microsoft.DotNet.SDK.7 --no-upgrade
    winget install Microsoft.DotNet.Framework.DeveloperPack_4 --no-upgrade
    winget install Microsoft.DotNet.DesktopRuntime.3_1 --no-upgrade

    # Reload Path
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Add to Path
    if(!(Get-Command git -ErrorAction SilentlyContinue)){ $env:Path += ';C:\Program Files\Git\usr\bin' }
    if(!(Get-Command dotnet -ErrorAction SilentlyContinue)){ $env:Path += ';C:\Program Files\dotnet' }

    # Install Decompiler
    if(!(Get-Command ilspycmd -ErrorAction SilentlyContinue)){ dotnet tool install --global ilspycmd --version 7.1.0.6543 }

    # Download or update all available Mods
    if (Test-Path "AxiomVergeMods") {
        git -C "AxiomVergeMods" pull 
    } else {
        git clone $RemoteModRepository "AxiomVergeMods"
    }
}

function initializeRepository($repositoryName, $page, $forkedRepo = ""){
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
    $gamePath = $page.GamePath
    $gameName = (Get-Item "$gamePath/AxiomVerge*.exe").Name
    $gameBaseName = (Get-Item "$gamePath/AxiomVerge*.exe").BaseName
    if(Test-Path $repositoryName){ Remove-Item $repositoryName -Recurse -Force }
    New-Item $repositoryName -ItemType Directory
    Set-Location $repositoryName
    
    # Clone base repository
    if($forkedRepo){
        # Add remote mod repository fork
        git clone $forkedRepo .
    } else {
        git clone $RemoteModRepository .
    }
    git checkout --orphan -b av
    git rm -rf .
    Get-ChildItem $gamePath | ForEach-Object { Copy-Item $_.FullName . -Recurse }
    
    # Import Saves
    New-Item "Saves" -ItemType Directory
    # TODO

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
    $modFileHandle = New-object System.Xml.XmlDocument
    $modFileHandle.LoadXml("<?xml version=`"1.0`" encoding=`"utf-8`"?><AVMods></AVMods>")
    # Be careful this save option is not relativ to the current location 
    $modFileHandle.Save("$repositoryName/.avmod")

    # Set config
    git config user.name "AVModPackager"
    git config user.email "offline"

	# Initialize Repository for patches
	Set-Content ".gitignore" "AxiomVergeMods/`r`nSaves/`r`nLog/`r`nAxiomVerge*.exe`r`nAxiomVerge*.exe.config`r`n*.avmod`r`n**/bin/`r`n*/obj/`r`n**/.vs/`r`n*.sln`r`n*.csproj.user`r`n*.zip`r`n*.rej`r`n*.pdb"
    # initHooks
	git add -A
	git commit -m "Initialized Repo"
	git tag "av-1.0.0.0" HEAD
}

function applyMod($mod){
    # Set Author
    git config user.name $mod.Author

    # Creates the initial commit for the new mod as new branch
    if($mod.Dependencies){
        git checkout $mod.Dependencies[0] -b $mod.Modname
        git merge $mod.Dependencies -m "Init new Mod: $($mod.Modname)"
    } else {
        git checkout tags/av-1.0.0.0 -b $mod.Modname
        git commit --allow-empty -m "Init new Mod: $($mod.Modname)"
    }
    git tag "$($mod.Modname)-$($mod.Modversion)" -m $($mod.dependencies -join "\n")

    # Set Description 
    git config branch.$($mod.Modname).note $mod.Description

    # Create the patched commit with version as a tag
    ([System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($mod.Patch))) | Set-Content temp
    # The application of the diff file should be done with different severity
    git apply temp --ignore-whitespace
    if(!$?) {
        git reset --hard
        git apply temp -C 1 --recount --reject --ignore-whitespace
        if(!$?) {
            displayInfoBox "Error:`n`nThe mod $($mod.Modname) could not be applied. Installation will continue, but without this mod. Contact the mod-creator for help"
            git reset --hard
            return
        } else {
            displayInfoBox "Warning:`n`nThe mod $($mod.Modname) was applied in a degraded state. This may work, but it is advisable to inform the mod-creator about the defect"
        }
    }
    Remove-Item temp
    git add -A
    git commit -m "Generated from Patch"
    git tag "$($mod.Modname)-$($mod.Modversion)"
    
    # Update mod file
    $modFileHandle = [xml](Get-Content ".avmod")
    $modFileHandle.AVMods.AppendChild($mod.History)
    $modFileHandle.Save(".avmod")
}

function generateMod(){
    # Merges all branches into the main branch
    git checkout av
    $branches = (git branch --format "%(refname:short)") | Where-Object { $_ -notin @("main", "av") }
    if($branches) { git merge $branches }

    # Build Game
    dotnet build "Dev"
}

function initializeUI(){

    function adjustMods(){
        # Ensure that the mod configuration is valid and reset if not

        function resetMods(){
            foreach($mod in $workspace.Controls.Where({ !$_.Installed })){
                $mod.CheckBox.Checked = $false
            }
        }

        function checkMods(){
            $dependencies = New-Object System.Collections.Generic.HashSet[String]
            $violations = New-Object System.Collections.Generic.HashSet[String]
            [version]$minGameversion = "1.0.0.0"
            $conflicts = New-Object System.Collections.Generic.HashSet[String]
            # Fetch all dependencies and conflicts in the current mod selection
            foreach($mod in $workspace.Controls.Where({$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true})){
                foreach($dependency in $mod.Dependencies) { $dependencies.Add($dependency) | Out-Null}
                foreach($conflict in $mod.Conflicts) { $conflicts.Add($conflict) | Out-Null }
                if($minGameversion -lt [version]$mod.Gameversion) { $minGameversion = [version]$mod.Gameversion}
            }
            # Check if all of these are satisfied
            foreach($mod in $workspace.Controls.Where({$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true})){
                $dependencies.Remove($mod.Modname) | Out-Null
                if($mod.Modname -in $conflicts) { $violations.Add($mod.Modname) | Out-Null }
            }
            return $dependencies, $violations, $minGameversion
        }

        $dependencies, $violations, $minGameversion = checkMods
        while($dependencies.Count -ne 0){
            # Try to enable dependencies
            foreach($mod in $workspace.Controls.Where({$_.Visible -eq $true})){
                if($mod.Modname -in $dependencies){
                    $mod.CheckBox.Checked = $true
                    $dependencies.Remove($mod.Modname)
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
        if($minGameversion -gt [version]$sidebarMarker.Page.Gameversion){
            resetMods
            displayInfoBox "Your gameversion is outdated and does not support this mod. Please update your game`n`nCurrent Gameversion: $($sidebarMarker.Page.Gameversion)`nRequired Gameversion: $($minGameversion)"
        }
    }

    function createPageButton($name){
        $pageButton = New-object System.Windows.Forms.Button
        $pageButton.Dock = "Top"
        $pageButton.Height = 40
        $pageButton.Font = $subHeaderFont
        $pageButton.Text = $name
        $pageButton.TextAlign = "MiddleRight"
        $pageButton.FlatAppearance.BorderSize = 0
        $pageButton.FlatStyle = "Flat"
        $pageButton.Add_Click({
            foreach($sidebarContainer in $sidebar.Controls){
                foreach($sidebarElements in $sidebarContainer.Controls){
                    $sidebarElements.ForeColor = $textcolor
            }}
            $this.ForeColor = $highlightColor
            $sidebarMarker.Visible = $true
            $sidebarMarker.Location = [System.Drawing.Point]::new(0, $this.Location.Y + $this.Parent.Location.Y)
            $sidebarMarker | Add-Member -Force -NotePropertyName Page -NotePropertyValue $this
            $workspace.Location = "0,0"
            foreach($mod in $workspace.Controls){
                if(!$mod.Installed){ $mod.CheckBox.Checked = $false }
                if($mod.Page -eq $this.Text -or $mod.Page -eq $this.GameIdentifier){
                    $mod.Visible = $true
                } else {
                    $mod.Visible = $false
                }
            }

            if($this.Parent -eq $gamesContainer){
                $footer.Visible = $true
                $footerInputFrame.Visible = $true
                $footerButton.Text = "Package"
            } else {
                $footer.Visible = $true
                $footerInputFrame.Visible = $false
                $footerButton.Text = "Update"

                # Propose updates to installed mods
                foreach($mod in $workspace.Controls.Where({$_.Installed})){
                    foreach($modUpdate in $workspace.Controls.Where({
                        $_.Modname -eq $mod.Modname -and [version]$_.Modversion -gt [version]$mod.Modversion
                    })){
                        $modUpdate.CheckBox.Checked = $true
                    }
                }
                adjustMods
            }
        })
        return $pageButton
    }

    function createCollapsible($modFileHandle, $page, $history, $installed = $false){
        function generateModInfo($modFileHandle){
            $dependenciesText = $modFileHandle.Dependencies.Dependency -join ", "
            $conflictsText = $modFileHandle.Conflicts.Conflict -join ", "
            return " $($modFileHandle.Description)`n Author: $($modFileHandle.Author)`n Modversion: $($modFileHandle.Modversion)`n Gameversion: $($modFileHandle.Gameversion)`n Dependencies: $dependenciesText`n Conflicts: $conflictsText"
        }

        $collapsibleContainer = New-object System.Windows.Forms.Panel
        $collapsibleContainer.Dock = "Top"
        $collapsibleContainer.AutoSize = $true
        $collapsibleContainer.Visible = $false
        $collapsibleContainer | Add-Member -NotePropertyName Page -NotePropertyValue $page
        $collapsibleContainer | Add-Member -NotePropertyName Patch -NotePropertyValue $modFileHandle.Patch
        $collapsibleContainer | Add-Member -NotePropertyName Modname -NotePropertyValue $modFileHandle.Modname
        $collapsibleContainer | Add-Member -NotePropertyName Modversion -NotePropertyValue $modFileHandle.Modversion
        $collapsibleContainer | Add-Member -NotePropertyName Gameversion -NotePropertyValue $modFileHandle.Gameversion
        $collapsibleContainer | Add-Member -NotePropertyName Dependencies -NotePropertyValue $modFileHandle.Dependencies.Dependency
        $collapsibleContainer | Add-Member -NotePropertyName Conflicts -NotePropertyValue $modFileHandle.Conflicts.Conflict
        $collapsibleContainer | Add-Member -NotePropertyName Installed -NotePropertyValue $installed
        $collapsibleContainer | Add-Member -NotePropertyName History -NotePropertyValue $history

        $collapsibleHeaderContainer = New-object System.Windows.Forms.Panel
        $collapsibleHeaderContainer.Dock = "Top"
        $collapsibleHeaderContainer.Height = 40

        $collapsibleButton = New-object System.Windows.Forms.Button
        $collapsibleButton.Dock = "Fill"
        $collapsibleButton.AutoSize = $true
        $collapsibleButton.Font = $subSubHeaderFont
        $collapsibleButton.Text = $modFileHandle.Modname
        $collapsibleButton.TextAlign = "MiddleLeft"
        $collapsibleButton.FlatAppearance.BorderSize = 0
        $collapsibleButton.FlatStyle = "Flat"
        if($installed) {$collapsibleButton.ForeColor = $highlightColor}
        $collapsibleButton.Add_Click({
            $collapsibleContent = $this.Content
            if($collapsibleContent.Visible -eq $true){
                $collapsibleContent.Visible = $false
            } else {
                $collapsibleContent.Visible = $true
            }
        })

        $modCheckbox = New-Object System.Windows.Forms.CheckBox
        $modCheckbox.Dock = "Right"
        $modCheckbox.FlatStyle = "Flat"
        $modCheckbox.Width = 60
        $modCheckbox.TextAlign = "MiddleCenter"
        if($installed) { 
            $modCheckbox.Checked = $true
            $modCheckbox.AutoCheck = $false
        }
        $modCheckbox.Add_Click({
            if($this.Parent.Parent.Installed){ return }
            adjustMods
        })

        $collapsibleBodyContainer = New-object System.Windows.Forms.Panel
        $collapsibleBodyContainer.Dock = "Top"
        $collapsibleBodyContainer.AutoSize = $true
        $collapsibleBodyContainer.Visible = $false

        $modInfo = New-object System.Windows.Forms.Label
        $modInfo.Dock = "Fill"
        $modInfo.AutoSize = $true
        $modInfo.Font = $normalFont
        $modInfo.Text = generateModInfo($modFileHandle)

        $collapsibleBodyContainer.Controls.Add($modInfo)

        $collapsibleHeaderContainer.Controls.Add($modCheckbox)
        $collapsibleButton | Add-Member -NotePropertyName Content -NotePropertyValue $collapsibleBodyContainer
        $collapsibleHeaderContainer.Controls.Add($collapsibleButton)

        $collapsibleContainer | Add-Member -NotePropertyName CheckBox -NotePropertyValue $modCheckbox
        $collapsibleContainer.Controls.Add($collapsibleBodyContainer)
        $collapsibleContainer.Controls.Add($collapsibleHeaderContainer)

        return $collapsibleContainer
    }

    function displayInfoBox($messageBoxText, $isYesNoPrompt = $false){
        $messageBoxForm = New-Object System.Windows.Forms.Form
        $messageBoxForm.ShowIcon = $false
        $messageBoxForm.Size = "400,300"
        $messageBoxForm.MinimumSize = "300, 200"
        $messageBoxForm.StartPosition = "CenterScreen"
        $messageBoxForm.BackColor = $backgroundColor
        $messageBoxForm.ForeColor = $textColor

        $messageBoxWorkspace = New-object System.Windows.Forms.Panel
        $messageBoxWorkspace.Dock = "Fill"
        $messageBoxWorkspace.Padding = 10
    
        $messageBoxFooter = New-object System.Windows.Forms.Panel
        $messageBoxFooter.Dock = "Bottom"
        $messageBoxFooter.Height = 50
        $messageBoxFooter.BackColor = $footerColor
        $messageBoxFooter.Padding = 10
        
        $messageBoxOkButton = New-Object System.Windows.Forms.Button
        $messageBoxOkButton.Text = "OK"
        $messageBoxOkButton.Dock = "Right"
        $messageBoxOkButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $messageBoxOkButton.Width = 100
        $messageBoxOkButton.BackColor = $highlightColor
        $messageBoxOkButton.ForeColor = $footerColor
        $messageBoxOkButton.Font = $subHeaderFont
        $messageBoxOkButton.FlatAppearance.BorderSize = 0
        $messageBoxOkButton.FlatStyle = "Flat"
        $messageBoxFooter.Controls.Add($messageBoxOkButton)
        
        if($isYesNoPrompt){
            $messageBoxOkButton.Text = "Yes"
            $messageBoxOkButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes
            $messageBoxNoButton = New-Object System.Windows.Forms.Button
            $messageBoxNoButton.Text = "No"
            $messageBoxNoButton.Dock = "Left"
            $messageBoxNoButton.DialogResult = [System.Windows.Forms.DialogResult]::No
            $messageBoxNoButton.Width = 100
            $messageBoxNoButton.Font = $subHeaderFont
            $messageBoxNoButton.FlatAppearance.BorderSize = 0
            $messageBoxNoButton.FlatStyle = "Flat"
            $messageBoxFooter.Controls.Add($messageBoxNoButton)
        }
        
        $messageBoxLabel = New-Object System.Windows.Forms.Label
        $messageBoxLabel.Text = $messageBoxText
        $messageBoxLabel.Dock = "Fill"
        $messageBoxLabel.Font = $subHeaderFont
        $messageBoxWorkspace.Controls.Add($messageBoxLabel)
        
        $messageBoxForm.Controls.Add($messageBoxWorkspace)
        $messageBoxForm.Controls.Add($messageBoxFooter)

        $messageBoxForm.Topmost = $true
        return $messageBoxForm.ShowDialog()
    }

    $scrollAction = {
        $newScroll = $this.Location.Y + $_.Delta / 5;
        $maxHeight = $this.Parent.Height - $this.Height;
        if ($newScroll -gt 0 -or $maxHeight -gt 0) { $newScroll = 0 }
        elseif ($newScroll -lt $maxHeight -and $maxHeight -lt 0) { $newScroll = $maxHeight }
        $this.Location = [System.Drawing.Point]::new(0, $newScroll);
    }

    # Fix dpi issues
    if ("ProcessDPI" -as [type]) {} else {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices;public class ProcessDPI {[DllImport("user32.dll", SetLastError=true)]public static extern bool SetProcessDPIAware();}'
    }
    $null = [ProcessDPI]::SetProcessDPIAware()

    Add-Type -AssemblyName "System.Windows.Forms"
    Add-Type -AssemblyName "System.Drawing"

    $highlightColor = "239,118,118"
    $backgroundColor = "#242424"
    $sidebarColor = "#303030"
    $footerColor = "#3c3c3c"
    $textColor = "white"

    $font = "Nirmala UI"
    $normalFont = [System.Drawing.Font]::new($font, 9)
    $headerFont = [System.Drawing.Font]::new($font, 12, [System.Drawing.FontStyle]::Bold)
    $subHeaderFont = [System.Drawing.Font]::new($font, 10, [System.Drawing.FontStyle]::Bold)
    $subSubHeaderFont = [System.Drawing.Font]::new($font, 9, [System.Drawing.FontStyle]::Bold)

    # Create Window
    $window = New-Object System.Windows.Forms.Form
    $window.Text = "Axiom Verge Mod Packager"
    $window.ShowIcon = $false
    $window.StartPosition = "CenterScreen"
    $window.AutoScaleMode  = "Dpi"
    $window.ClientSize = "800,600"
    $window.Font = $normalFont
    $window.BackColor = $backgroundColor
    $window.ForeColor = $textColor

    $sidebarScrollBox = New-object System.Windows.Forms.Panel
    $sidebarScrollBox.Dock = "Left"
    $sidebarScrollBox.Width = 150
    $sidebarScrollBox.BackColor = $sidebarColor

    $sidebar = New-object System.Windows.Forms.Panel
    $sidebar.Width = 150
    $sidebar.AutoSize = $true
    $sidebar.Add_MouseWheel($scrollAction)

    $workspaceScrollBox = New-object System.Windows.Forms.Panel
    $workspaceScrollBox.Dock = "Fill"
    
    $workspace = New-object System.Windows.Forms.Panel
    $workspace.Anchor = "Left, Top, Right"
    $workspace.AutoSize = $true
    $workspace.Add_MouseWheel($scrollAction)
    
    $footer = New-object System.Windows.Forms.Panel
    $footer.Dock = "Bottom"
    $footer.Height = 50
    $footer.BackColor = $footerColor
    $footer.Padding = 10
    $footer.Visible = $false
    
    $gamesContainer = New-object System.Windows.Forms.Panel
    $gamesContainer.Dock = "Top"
    $gamesContainer.AutoSize = $true
    
    $packagesContainer = New-object System.Windows.Forms.Panel
    $packagesContainer.Dock = "Top"
    $packagesContainer.AutoSize = $true
    
    $gamesHeader = New-object System.Windows.Forms.Label
    $gamesHeader.Dock = "Top"
    $gamesHeader.Height = 60
    $gamesHeader.Font = $headerFont
    $gamesHeader.Text = "Games"
    $gamesHeader.TextAlign = "MiddleLeft"

    $sidebarMarker = New-object System.Windows.Forms.Panel
    $sidebarMarker.Height = 40
    $sidebarMarker.Width = 5
    $sidebarMarker.BackColor = $highlightColor
    $sidebarMarker.Visible = $false

    # Locate Steam and Epic AV1 and AV2 to add available Games to sidebar
    $supportedGames = @{
        "AV1-Steam" = "C:/Program Files (x86)/Steam/steamapps/common/Axiom Verge"
        "AV2-Steam" = "C:/Program Files (x86)/Steam/steamapps/common/Axiom Verge 2"
        "AV1-Epic" = "C:/Program Files/Epic Games/AxiomVerge1"
        "AV2-Epic" = "C:/Program Files/Epic Games/AxiomVerge2"
    }
    foreach ($supportedGame in $supportedGames.Keys.Where{ Test-Path $supportedGames[$_]}) {
        $gamePage = createPageButton($supportedGame)
        $gamePage | Add-Member -NotePropertyName "GameIdentifier" -NotePropertyValue $supportedGame
        $gamePage | Add-Member -NotePropertyName "GamePath" -NotePropertyValue $supportedGames[$supportedGame]
        $gamePage | Add-Member -NotePropertyName "Gameversion" -NotePropertyValue (Get-Item "$($supportedGames[$supportedGame])/AxiomVerge*.exe").VersionInfo.ProductVersion
        $gamesContainer.Controls.Add($gamePage)
    }

    $packagesHeader = New-object System.Windows.Forms.Label
    $packagesHeader.Dock = "Top"
    $packagesHeader.Height = 60
    $packagesHeader.Font = $headerFont
    $packagesHeader.Text = "Packages"
    $packagesHeader.TextAlign = "MiddleLeft"

    # Add all available mods
    Get-ChildItem "AxiomVergeMods/*.avmod", "*.avmod" | ForEach-Object {
        [xml]$AVMod = Get-Content $_.FullName
        $AVMod.AVMods.Mod | Group-Object Game, Platform | ForEach-Object {
            $modHistory = $_.group
            $maxVersion = ($modHistory.Modversion | Measure-Object -Maximum).Maximum
            $recentMod = $modHistory | Where-Object { $_.Modversion -eq $maxVersion}
            $modElement = createCollapsible $recentMod "$($recentMod.Game)-$($recentMod.Platform)" $modHistory
            $workspace.Controls.Add($modElement)
        }
    }

    $sidebar.Controls.Add($sidebarMarker)
    $sidebar.Controls.Add($packagesContainer)
    $sidebar.Controls.Add($gamesContainer)

    # Add all installed packages
    Get-ChildItem -Directory | Where-Object {Test-Path "$($_.FullName)/.avmod"} | ForEach-Object {
        # Create page
        $packagePage = createPageButton($_.Name)
        $packagesContainer.Controls.Add($packagePage)
        # Assume that every package has uniform game/platform
        $firstMod = [xml](Get-Content "$($_.FullName)/.avmod").AVMods.Mod[0]
        $gameIdentifier = "$($firstMod.Game)-$($firstMod.Platform)"
        # Fill page properties
        $sidebarElement = $gamesContainer.Controls.Where{$_.GameIdentifier -eq $gameIdentifier}
        $packagePage | Add-Member -NotePropertyName "GameIdentifier" -NotePropertyValue $gameIdentifier
        $packagePage | Add-Member -NotePropertyName "GamePath" -NotePropertyValue $sidebarElement.GamePath
        $packagePage | Add-Member -NotePropertyName "Gameversion" -NotePropertyValue (Get-Item "$($sidebarElement.GamePath)/AxiomVerge*.exe").VersionInfo.ProductVersion                       
        $packageName = $_.Name

        # Add installed mods
        [xml]$AVMod = Get-Content "$($_.FullName)/.avmod"
        $AVMod.AVMods.Mod | Group-Object Modname | ForEach-Object {
            $modHistory = $_.group
            $maxVersion = ($modHistory.Modversion | Measure-Object -Maximum).Maximum
            $recentMod = $modHistory | Where-Object { $_.Modversion -eq $maxVersion}
            $modElement = createCollapsible $recentMod $packageName $modHistory $true
            $workspace.Controls.Add($modElement)
        }
    }

    $footerInputFrame = New-object System.Windows.Forms.Panel
    $footerInputFrame.BackColor = $highlightColor
    $footerInputFrame.Dock = "Fill"
    $footerInputFrame.Padding = 2

    $footerInput = New-object System.Windows.Forms.TextBox
    $footerInput.AutoSize = $false
    $footerInput.Dock = "Fill"
    $footerInput.BackColor = $footerColor
    $footerInput.ForeColor = $textColor
    $footerInput.Font = $subHeaderFont
    $footerInput.BorderStyle = "None"
 
    $footerButton = New-object System.Windows.Forms.Button
    $footerButton.Dock = "Right"
    $footerButton.Width = 150
    $footerButton.BackColor = $highlightColor
    $footerButton.ForeColor = $footerColor
    $footerButton.Font = $subHeaderFont
    $footerButton.Text = "Package"
    $footerButton.FlatAppearance.BorderSize = 0
    $footerButton.FlatStyle = "Flat"
    $footerButton.Add_Click({
        # Block specific package names
        $normalizedPackageName = $footerInput.Text -replace "[$([RegEx]::Escape([string][IO.Path]::GetInvalidFileNameChars()))]+","_"
        if(($normalizedPackageName -in @("AxiomVergeMods", "", "Mod")) -or ($normalizedPackageName.StartsWith("AV"))){ 
            displayInfoBox "Invalid package name"
            return
        }
        # Check for duplicates
        if(Test-Path $normalizedPackageName){
            $result = displayInfoBox "This package already exists. Do you want to overwrite it" $true
            if($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Remove-Item $normalizedPackageName -Recurse
        }
        initializeRepository $normalizedPackageName $sidebarMarker.Page
        # Make sure to only discard old mods. This only happens for packages and their automatic updates
        $mods = $workspace.Controls.Where({$_.Visible -eq $true -and $_.CheckBox.Checked -eq $true})
        $mods = $mods | Group-Object Modname | ForEach-Object { 
            $maxVersion = ($_.group.Modversion | Measure-Object -Maximum).Maximum
            $recentMod = $_.group | Where-Object { $_.Modversion -eq $maxVersion }
            $recentMod
        }
        if ( $mods -isnot [array]) {applyMod $mod}
        else {
            $mods = New-Object System.Collections.ArrayList(, $mods)
            # Make sure that all mods are installed in the correct order
            $installedMods = New-Object System.Collections.Generic.HashSet[String]
            while($mods.Count -ne 0){
                $mod = $mods[0]
                $mods.RemoveAt(0)
                # Check if this mod has all dependencies installed
                if(($mod.Dependencies.Where{$_ -notin $installedMods}).Count -eq 0){
                    applyMod $mod
                    $installedMods.Add($mod.Modname) | Out-Null
                } else {
                    $mods.Add($mod)
                }
            }
        }
        generateMod
        Set-Location "../"
    })

    $footerInputFrame.Controls.Add($footerInput)

    $footer.Controls.Add($footerButton)
    $footer.Controls.Add($footerInputFrame)
    
    $gamesContainer.Controls.Add($gamesHeader)
    $packagesContainer.Controls.Add($packagesHeader)

    $sidebarScrollBox.Controls.Add($sidebar)
    $workspaceScrollBox.Controls.Add($workspace)

    $window.Controls.Add($workspaceScrollBox)
    $window.Controls.Add($footer)
    $window.Controls.Add($sidebarScrollBox)
    $window.ShowDialog()
}

installDependencies
initializeUI
Pop-Location