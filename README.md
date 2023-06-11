# Overview
This is the repository for the Axiom Verge Mod Packager. This allows you to install community developed modifications for all Axiom Verge games for Steam and Epic.

# Features
- Modern UI
- Support for all PC versions with Windows 10+
- Dynamic patches accross multiple versions
- Mod interoperability
- Auto-Update detection
- Intuitiv packaging system
- Improved workflow for developers
- Beta support

# Installation
Download the executeable from the [Releases](https://github.com/MaragonMH/AxiomVergeMods/releases/latest) section and put it inside an empty folder that is not right restricted. Now you can run the executeable. Check out the introduction [video](), if you are stuck somewhere.

# Modding
Modding is the sole purpose for this project. This should empower creators to develop new custom mods for the Axiom Verge series. Check out the developer [video]() as well.\
Here is a quick user guide:
1. Fork this repository
2. Copy the repository url
3. Open powershell in the applications directory
4. Run the following command
```powershell
.\AVModPackager.exe <YourForkUrl>
```
5. Select the game you want to develop for in the sidebar.
6. Enter a name for your modding package in the footer. I recommend "Dev"
7. Without selecting any mods, click "Package" in the footer.
8. Navigate to the "Dev/Dev" directory.
9. Make yourself familiar with the branching and tagging concept of the git repository. 
10. Create a new branch, based on the mod dependencies you want.
11. Make your changes
12. Create a pull request for your Modname.avmod file.

# Build
Install [ps2exe](https://github.com/MScholtes/PS2EXE):
```powershell
Install-Module ps2exe
```
Create the executeable from the script:
```powershell
Invoke-ps2exe .\AVModPackager.ps1 .\AVModPackager.exe -noConsole
```

# Contributions
If you want to add improvements or give feedback to this application, please feel free to contact me in the official Axiom Verge discord, in the #modding channel, so you can make this app even better. 