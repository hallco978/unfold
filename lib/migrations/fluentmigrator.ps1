# Support for FluentMigrator based migrations. 
#
# FluentMigrator based migrations typically are put in a separate project 
# inside your solution. This project creates an assembly that is loaded
# by Migrate.exe, a FluentMigrator tool to actually execute the migrations
#
# The deployment extension consists of three step
# * building the project in order to generate the migrations assembly
# * putting the build result inside a database folder under an unfold release
# * executing the migrations
#
# Configuration options
# Set-Config migrations fluentmigrator # tell unfold to include this file
# Set-Config fluentmigrator @{
#   msbuild = ".\code\path\to\fluentmigrator.csproj" # path to dbup project
#   assembly = ".\code\path\to\outputassembly.dll" # (optional) in case name cannot be derived
#   provider = "sqlserver2009" # provider the Migrate.exe assembly should use
# }
# Set-Config automigrate $true # this will automatically run migrations on deployment

task buildmigrations {
    If(-not $config.fluentmigrator.msbuild) {
        Write-Warning "No migrations msbuild project configured"
        Write-Warning "Please add Set-Config fluentmigrator @{"
        Write-Warning "                 msbuild = '.\code\path\to\msbuild\msbuild.csproj'"
        Write-Warning "                 }"
        Write-Warning "to your deploy.ps1 file"
        return
    }

    Write-Host "Building fluentmigrator project" -Fore Green
    Invoke-Script {
        Exec {
            $buildConfig = $config.buildConfiguration
            if(-not $buildConfig) {
                $buildConfig = "Debug"
            }
            msbuild /p:Configuration="$buildConfig" /target:Rebuild $config.fluentmigrator.msbuild
        }
    }
}

Set-AfterTask build buildmigrations

task releasemigrations {
    $migrationsPath = Split-Path $config.fluentmigrator.msbuild
    $migrationsBuildOutputPath = "$migrationsPath\bin\$($config.buildConfiguration)"

    $config.migrationsdestination = ".\$($config.releasepath)\database"

    # Copy assembly output
    Write-Host "Copying migrations assembly to release folder"
    Invoke-Script -arguments $migrationsBuildOutputPath {
        param($outputPath)

        Copy-Item -Recurse $outputPath $config.migrationsdestination
    }

    # Copy migrate.exe
    Write-Host "Copying Migrate.exe to release folder"
    Invoke-Script {
        param($outputPath)
        $migrate = Get-ChildItem .\code -Recurse | Where-Object { $_.Name -eq "Migrate.exe" } | Select-Object -last 1

        If(-not $migrate) {
            Write-Warning "Migrate.exe migration tool not found"
            Write-Warning "If you're using NuGet this should be downloaded automatically"
            Write-Warning "Otherwise you should add it to your scm"
            return
        }

        Copy-Item -Force $migrate.FullName $config.migrationsdestination
    }
}

Set-AfterTask release releasemigrations

task runmigrations {
    If($config.rollback) {
        Write-Warning "Rollback not supported yet"
        return
    }

    $target = $config.releasepath
    If(-not $target) {
        $target = Get-CurrentFolder
    }

    Invoke-Script -arguments $target {
        param($target)
        $migrate = ".\$target\database\Migrate.exe"

        $migrationsAssembly = $config.fluentmigrator.assembly
        If(-not $migrationsAssembly) {
            $migrationsCsProj = Get-Item $config.fluentmigrator.msbuild
            $name = $migrationsCsProj | Select-Object -expand basename

            $migrationsAssembly = "$name.dll"
        }

        # derive assembly name from name of csproj and check whether it exists
        $assembly = ".\$target\database\$migrationsAssembly" 

        If(-not (Test-Path $assembly)) {
            throw "Migration error: unable to locate migration assembly"
        }

        $provider = $config.fluentmigrator.provider
        If(-not $provider) {
            $provider = "sqlserver"
        }

        Exec {
            &$migrate --task=migrate --a="$assembly" --db=$provider
        }
    }
}

# Only if explicitely disabled automigrate
# we don't hookup to the migrations task
If($config.automigrate -ne $false) {
    Set-BeforeTask setupiis runmigrations
}

