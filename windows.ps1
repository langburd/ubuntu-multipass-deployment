<#
.SYNOPSIS
    Launches multiple Multipass instances on Windows with bridged networking using Hyper-V, reading configuration from config.yaml.

.DESCRIPTION
    This script reads configuration variables from a YAML file named "config.yaml" located in the same directory as the script.
    The configuration file contains:
      - git_username: GitHub username for SSH key import.
      - windows_switch_name: The name of the Hyper-V virtual switch to use.
      - instances: A list of instance configurations (name, static IP, gateway, and DNS servers).

    The script performs the following steps:
      1. Checks for Multipass installation.
      2. Loads the configuration from config.yaml.
      3. Checks if the Hyper-V switch (windows_switch_name) exists. If not, it displays available network adapters,
         asks for the adapter to use, and creates the switch.
      4. For each instance in the configuration, it purges any existing instance, creates a cloud-init file (using the GitHub username),
         launches the Multipass instance with bridged networking via the specified switch, and then cleans up.
      5. Finally, it lists all Multipass instances.

.HOW TO RUN
    1. Ensure that Multipass and Hyper-V are installed.
    2. Place this script and the config.yaml file (see sample below) in the same directory.
    3. Open an elevated PowerShell prompt and navigate to the directory containing the script.
    4. Run the script:
           .\YourScriptName.ps1

.EXECUTION POLICY ISSUE
    If you encounter an error about script execution being disabled, run:
           Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    or
           Set-ExecutionPolicy Bypass -Scope CurrentUser
    For more details, refer to Microsoft's documentation on PowerShell execution policies.

.SAMPLE config.yaml
    ---
    git_username: langburd
    windows_switch_name: MultipassExternalSwitch
    instances:
      - name: pihole1
        ip: 192.168.8.53/23
        gateway: 192.168.8.1
        dns:
          - 8.8.8.8
          - 8.8.4.4
      - name: pihole2
        ip: 192.168.8.153/23
        gateway: 192.168.8.1
        dns:
          - 8.8.8.8
          - 8.8.4.4

.NOTES
    - This script requires PowerShell 7 (or later) to use ConvertFrom-Yaml.
    - Run PowerShell as an Administrator if required.
#>

# Get the directory of this script and load config.yaml
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "config.yaml"
if (-not (Test-Path $configPath)) {
    Write-Host "Configuration file config.yaml not found in $scriptDir. Exiting."
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Yaml

# Extract configuration variables
$ghName    = $config.git_username
$SwitchName = $config.windows_switch_name
$instances  = $config.instances

# Check if Multipass is installed
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
    Write-Host "Multipass is not installed. Exiting."
    exit 1
}

# Check if the Hyper-V virtual switch exists. If not, create it.
try {
    $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
} catch {
    $existingSwitch = $null
}

if (-not $existingSwitch) {
    Write-Host "VMSwitch '$SwitchName' does not exist."
    Write-Host "Available network adapters:"
    Get-NetAdapter | Format-Table -AutoSize

    $netAdapterName = Read-Host "Enter the name of the network adapter to use for creating the VMSwitch '$SwitchName'"
    try {
        New-VMSwitch -Name $SwitchName -NetAdapterName $netAdapterName -AllowManagementOS $true | Out-Null
        Write-Host "Created VMSwitch '$SwitchName' using adapter '$netAdapterName'."
    } catch {
        Write-Host "Error creating VMSwitch. Please ensure Hyper-V is installed and try again."
        exit 1
    }
} else {
    Write-Host "VMSwitch '$SwitchName' already exists. Using it for Multipass instances."
}

function Multipass-Purge {
    param(
        [string]$InstanceName
    )
    Write-Host "Deleting instance $InstanceName if it exists..."
    & multipass delete $InstanceName --purge
}

function Create-CloudInit {
    param(
        [string]$InstanceName,
        [string]$StaticIP,
        [string]$GatewayIP,
        [string]$DNSServers
    )

    $cloudInitContent = @"
#cloud-config
hostname: $InstanceName
package_update: true
package_upgrade: true
packages:
  - net-tools
  - ca-certificates
  - curl
ssh_import_id:
  - gh:$ghName
write_files:
  - path: /etc/netplan/10-netcfg.yaml
    owner: root:root
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            dhcp4: false
            addresses: [$StaticIP]
            nameservers:
              addresses: [$DNSServers]
            routes:
              - to: default
                via: $GatewayIP
runcmd:
  - netplan apply
"@

    $fileName = "$InstanceName-cloud-init.yaml"
    $cloudInitContent | Out-File -FilePath $fileName -Encoding utf8
    Write-Host "Created cloud-init file: $fileName"
}

function Launch-Instance {
    param(
        [string]$InstanceName
    )
    $fileName = "$InstanceName-cloud-init.yaml"
    Write-Host "Launching instance $InstanceName..."
    # Launch using the designated VMSwitch
    & multipass launch --name $InstanceName --memory "1G" --network "$SwitchName" --cloud-init $fileName --timeout 600
    Remove-Item $fileName -ErrorAction SilentlyContinue
    Write-Host "Instance $InstanceName launched and cloud-init file removed."
}

function Create-AndLaunchInstance {
    param(
        [string]$InstanceName,
        [string]$StaticIP,
        [string]$GatewayIP,
        [string]$DNSServers
    )
    Multipass-Purge -InstanceName $InstanceName
    Create-CloudInit -InstanceName $InstanceName -StaticIP $StaticIP -GatewayIP $GatewayIP -DNSServers $DNSServers
    Launch-Instance -InstanceName $InstanceName
}

# Iterate over each instance in the configuration and create it
foreach ($instance in $instances) {
    $name    = $instance.name
    $ip      = $instance.ip
    $gateway = $instance.gateway
    # Join the list of DNS servers with commas
    $dns     = ($instance.dns) -join ","

    Create-AndLaunchInstance -InstanceName $name -StaticIP $ip -GatewayIP $gateway -DNSServers $dns
}

# List all Multipass instances
Write-Host "Listing all Multipass instances:"
& multipass list
