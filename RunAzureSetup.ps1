###########################################################################################################################
#  Powershell script to run steps 1 and 2 from https://docs.pivotal.io/pivotalcf/2-0/customizing/azure-arm-template.html  #
###########################################################################################################################

Write-Host "Download the latest release of the PCF Azure ARM Templates. For PCF v1.11 and later"
Write-Host "https://github.com/pivotal-cf/pcf-azure-arm-templates/releases/tag/1.11%2B"
Write-Host ""
Write-Host "Run this powershell file from within the same folder as ARM template json files"
Write-Host "Highly recommend to install Ubuntu Bash on Windows from the Windows 10 store for public key generation if you don't have keys already"
Write-Host ""

do{
	$UserInput = Read-Host "Are you ready to continue? Y or N"
	if (("Y","N") -notcontains $UserInput) {
		$UserInput = $null
		Write-Warning "Please input either Y or N"
	}
	if (("N") -contains $UserInput) {
		Write-Host "exiting..."
		exit
	}     
	if (("Y") -contains $UserInput) {
        Write-Host "You must enter at least one value for either PCF_prefix or PCF_suffix. 1 - 5 characters numbers and lower-case letters only"
	}
}
until ($UserInput -ne $null)

$PCF_prefix = Read-Host "Prefix for resource names"
$PCF_suffix = Read-Host "Suffix for resources names"

if ([string]::IsNullOrEmpty($PCF_prefix) -and [string]::IsNullOrEmpty($PCF_suffix)){
    Write-Warning "You must have at least one value for either Prefix or Suffix."
    Write-Host "exiting... please restart"
}

$RESOURCE_GROUP = $PCF_prefix.ToLower() + "resources" + $PCF_suffix.ToLower()
Write-Host "Resource Group: " $RESOURCE_GROUP

$STORAGE_NAME = $PCF_prefix.ToLower() + "storage" + $PCF_suffix.ToLower()
Write-Host "Storage Name: " $STORAGE_NAME

#Choose location from cli command: az account list-locations -o table
az account list-locations -o table
$LOCATION = Read-Host 'Type name of Region from the Name column, example: eastus'

az group create --name $RESOURCE_GROUP --location $LOCATION


Write-Host '#Retrieve the connection string for your BOSH storage account:'
az storage account create --name $STORAGE_NAME --resource-group $RESOURCE_GROUP --sku Standard_LRS --kind Storage --location $LOCATION

$storage_connection = az storage account show-connection-string --name $STORAGE_NAME --resource-group $RESOURCE_GROUP
$storage_conn_str_json = $storage_connection  | ConvertFrom-Json

Write-Host '#Export the connection string:'
$CONNECTION_STRING = $storage_conn_str_json.connectionString

Write-Host '#Create a container for the Ops Manager image:'
az storage container create --name opsman-image --connection-string $CONNECTION_STRING

Write-Host '#Create a container for the Ops Manager VM:'
az storage container create --name opsmanager --connection-string $CONNECTION_STRING

Write-Host '#Create a container for Ops Manager:'
az storage container create --name opsmanager --connection-string $CONNECTION_STRING

Write-Host '#Create a container for BOSH:'
az storage container create --name bosh --connection-string $CONNECTION_STRING

Write-Host '#Create a container for the stemcell:'
az storage container create --name stemcell --public-access blob --connection-string $CONNECTION_STRING

Write-Host '#Create a table for stemcell data:'
az storage table create --name stemcells --connection-string $CONNECTION_STRING

Write-Host 'Navigate to https://network.pivotal.io/products/ops-manager, download latest release of PCF Ops Manager for Azure PDF, copy and paste here the Ops Manager image URL for your region'
$OPS_MAN_IMAGE_URL = Read-Host 'Ops Manager Image URL:'
#example: PCF 2.1 East US: https://opsmanagereastus.blob.core.windows.net/images/ops-manager-2.1-build.178.vhd

Write-Host '#Copy the Ops Manager image into your storage account:'
az storage blob copy start --source-uri $OPS_MAN_IMAGE_URL --connection-string $CONNECTION_STRING --destination-container opsman-image --destination-blob image.vhd 

do{
    $copy_status = az storage blob show --name image.vhd --container-name opsman-image --account-name $STORAGE_NAME
    $copy_upload = $copy_status | ConvertFrom-Json
    Write-Host 'Copy Image Status: ' $copy_upload.properties.copy.progress
    Sleep -Seconds 5
}
until ($copy_upload.properties.copy.status -eq "success")
Write-Host 'PCF Image Copy Succeeded'
Write-Host ''

## Get/Generate Valid Public Key File - OR Stop here and continue with manual steps
do{
    $UserInput = Read-Host "The following requires ssh private/public keys. Type Y if you have your key ready. 'r'n"
                           "If you have Windows 10 with BASH from the Windows Store installed, type WIN, and one will be generated for you."
	if (("Y","N","WIN") -notcontains $UserInput) {
		$UserInput = $null
		Write-Warning "Please input either Y or N"
	}
	if (("N") -contains $UserInput) {
		Write-Host "Please continue with Step 3 manually at https://docs.pivotal.io/pivotalcf/2-0/customizing/azure-arm-template.html#-step-3:-configure-the-arm-template"
		exit
    }
	if (("Y") -contains $UserInput) {
        do{
            $pub_prompt_path = Read-Host "Type in full path to the public key, excluding the keyname"
            $pub_prompt_file = Read-Host "Type key .pub file name"
            $pub_file = $pub_prompt_path + $pub_prompt_file
            $pub_exist = Test-Path $pub_file
            if ($pub_exist -ne $true){
                #False File Not Found
                Write-Host ".pub file not found at " $pub_file
            }else{
                $peek_pub = Get-Content $pub_file -Raw | Out-String
                if ($peek_pub -contains ("sha_rsa")){
                    $pub_good = $true
                }else{ 
                    $pub_good = $false
                }
            }   
        }
        until ($pub_good -eq $true)
        
        Copy-Item -Path $pub_file -Destination .\
        $pubkey = Get-Content ".\" $pub_prompt_file
    }
    if (("WIN") -contains $UserInput) {
        Write-Host "Do not put a passphrase for the key, simply press enter to confirm"
        bash -c "ssh-keygen -t rsa -f opsman -C ubuntu"
        $pubkey = Get-Content ".\opsman.pub" -Raw | Out-String
	}
}
until ($UserInput -ne $null)

$Environment_lbl = Read-Host 'Enter an Environment Label to tag template-created resources for assisting with resource management'

$azure_params = Get-Content ".\azure-deploy-parameters.json" -Raw | ConvertFrom-Json

$azure_params.parameters.OpsManVHDStorageAccount.value = $STORAGE_NAME
$azure_params.parameters.BlobStorageContainer.value = "opsman-image"
$azure_params.parameters.AdminSSHKey.value = $pubkey
$azure_params.parameters.Location.value = $LOCATION
$azure_params.parameters.Environment.value = $Environment_lbl
$azure_params_newfile = $PCF_prefix.ToLower() + "azure-deploy-parameters" + $PCF_suffix.ToLower() + ".json"

$azure_params | ConvertTo-Json | Add-Content -Path $azure_params_newfile

Write-Host "Parameters template written to directory with the following json payload at " $azure_params_newfile ":"

#Stop here, and deploy template manually, or continue
do{
	$UserInput = Read-Host "Please type Y to Continue to Deploy the Template, or N to stop here and continue manually"
	if (("Y","N") -notcontains $UserInput) {
		$UserInput = $null
		Write-Warning "Please input either Y or N"
	}
	if (("N") -contains $UserInput) {
		Write-Host "You may use the generated params file to deploy manually at .\" $azure_params_newfile
		exit
	}     
	if (("Y") -contains $UserInput) {
        Write-Host "Continuing now to deploy the ARM Template .\" $azure_params_newfile
	}
}
until ($UserInput -ne $null)

#Deploy the template:
az group deployment create --template-file azure-deploy.json --parameters $azure_params_newfile --resource-group $RESOURCE_GROUP --name cfdeploy

#Create a network security group named pcf-nsg.
az network nsg create --name pcf-nsg --resource-group $RESOURCE_GROUP --location $LOCATION

#Add a network security group rule to the pcf-nsg group to allow traffic from the public Internet.
az network nsg rule create --name internet-to-lb --nsg-name pcf-nsg --resource-group $RESOURCE_GROUP --protocol Tcp --priority 100 --destination-port-range '*'

Write-Host "Deployment Script Complete"
Write-Host "Navigate to your DNS provider, and create an entry that points a fully qualified domain name (FQDN) in your domain to the IP address of the Ops Manager VM"
Write-Host "Continue to the Configuring Ops Manager Director on Azure topic at"
Write-Host "https://docs.pivotal.io/pivotalcf/2-0/customizing/azure-om-config.html"