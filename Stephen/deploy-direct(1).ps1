param()

$ErrorActionPreference = 'Stop'

function Read-RequiredValue {
  param(
    [string]$PromptText,
    [string]$ValidationMessage
  )

  while ($true) {
    $providedValue = Read-Host $PromptText
    if (-not [string]::IsNullOrWhiteSpace($providedValue)) {
      return $providedValue.Trim()
    }

    Write-Host $ValidationMessage -ForegroundColor Yellow
  }
}

function Read-YesNoValue {
  param(
    [string]$PromptText,
    [bool]$DefaultValue
  )

  $defaultToken = if ($DefaultValue) { 'Y/n' } else { 'y/N' }

  while ($true) {
    $rawResponse = Read-Host "$PromptText [$defaultToken]"
    if ([string]::IsNullOrWhiteSpace($rawResponse)) {
      return $DefaultValue
    }

    $normalizedResponse = $rawResponse.Trim().ToLowerInvariant()
    if ($normalizedResponse -in @('y', 'yes')) {
      return $true
    }

    if ($normalizedResponse -in @('n', 'no')) {
      return $false
    }

    Write-Host 'Please answer yes or no.' -ForegroundColor Yellow
  }
}

function Read-ChoiceValue {
  param(
    [string]$PromptText,
    [string[]]$AllowedValues,
    [string]$DefaultValue
  )

  $allowedDisplay = ($AllowedValues -join '/')

  while ($true) {
    $rawResponse = Read-Host "$PromptText [$allowedDisplay] (default: $DefaultValue)"
    if ([string]::IsNullOrWhiteSpace($rawResponse)) {
      return $DefaultValue
    }

    $normalizedResponse = $rawResponse.Trim().ToLowerInvariant()
    if ($AllowedValues -contains $normalizedResponse) {
      return $normalizedResponse
    }

    Write-Host "Choose one of: $allowedDisplay" -ForegroundColor Yellow
  }
}

function Ensure-CommandExists {
  param(
    [string]$CommandName,
    [string]$InstallHint
  )

  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "Required command '$CommandName' was not found. $InstallHint"
  }
}

function Get-DomainList {
  param(
    [string]$PrimaryDomain,
    [bool]$IncludeWwwAlias
  )

  $domainValues = [System.Collections.Generic.List[string]]::new()
  $domainValues.Add($PrimaryDomain)

  if ($IncludeWwwAlias -and -not $PrimaryDomain.StartsWith('www.')) {
    $domainValues.Add("www.$PrimaryDomain")
  }

  return $domainValues
}

function Build-NginxServerNameValue {
  param(
    [string[]]$Domains
  )

  return ($Domains -join ' ')
}

function Build-HttpsConfigContent {
  param(
    [string]$ServerNameValue
  )

  @"
server {
    listen 80;
    server_name $ServerNameValue;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://`$host`$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $ServerNameValue;

    ssl_certificate /etc/letsencrypt/live/${($ServerNameValue.Split(' ')[0])}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${($ServerNameValue.Split(' ')[0])}/privkey.pem;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files `$uri `$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files `$uri =404;
    }
}
"@
}

function Build-HttpOnlyConfigContent {
  param(
    [string]$ServerNameValue
  )

  @"
server {
    listen 80;
    server_name $ServerNameValue;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files `$uri `$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|svg|webp|ico)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
        try_files `$uri =404;
    }
}
"@
}

function Build-ComposeContent {
  param(
    [string]$ProjectName,
    [string]$HttpPort,
    [bool]$EnableSsl
  )

  $composeLines = [System.Collections.Generic.List[string]]::new()
  $composeLines.Add("services:")
  $composeLines.Add("  $ProjectName:")
  $composeLines.Add("    build:")
  $composeLines.Add("      context: .")
  $composeLines.Add("      dockerfile: Dockerfile")
  $composeLines.Add("    container_name: $ProjectName")
  $composeLines.Add("    ports:")
  $composeLines.Add("      - `"${HttpPort}:80`"")

  if ($EnableSsl) {
    $composeLines.Add("      - `"443:443`"")
    $composeLines.Add("    volumes:")
    $composeLines.Add("      - ./nginx.generated.conf:/etc/nginx/conf.d/default.conf:ro")
    $composeLines.Add("      - ./certbot/www:/var/www/certbot")
    $composeLines.Add("      - ./certbot/conf:/etc/letsencrypt")
  } else {
    $composeLines.Add("    volumes:")
    $composeLines.Add("      - ./nginx.generated.conf:/etc/nginx/conf.d/default.conf:ro")
  }

  $composeLines.Add("    restart: unless-stopped")

  return ($composeLines -join [Environment]::NewLine)
}

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projectRoot

Ensure-CommandExists -CommandName 'docker' -InstallHint 'Install Docker Desktop or Docker Engine first.'
Ensure-CommandExists -CommandName 'docker' -InstallHint 'Docker must be on PATH.'

$projectNameInput = Read-RequiredValue -PromptText 'Container/project name' -ValidationMessage 'A project name is required.'
$projectName = ($projectNameInput -replace '[^a-zA-Z0-9_-]', '-').ToLowerInvariant()
$primaryDomain = Read-RequiredValue -PromptText 'Primary domain (example: example.com)' -ValidationMessage 'A domain is required.'
$includeWwwAlias = Read-YesNoValue -PromptText 'Also configure the www alias?' -DefaultValue $true
$enableSsl = Read-YesNoValue -PromptText 'Enable SSL with Let’s Encrypt?' -DefaultValue $true
$httpPort = Read-RequiredValue -PromptText 'Host HTTP port to expose' -ValidationMessage 'A host port is required.'

$sslMode = 'none'
$emailAddress = ''
$stagingCertificates = $false

if ($enableSsl) {
  $sslMode = Read-ChoiceValue -PromptText 'SSL mode' -AllowedValues @('staging', 'production') -DefaultValue 'staging'
  $emailAddress = Read-RequiredValue -PromptText 'Email for Let’s Encrypt notices' -ValidationMessage 'An email address is required for SSL setup.'
  $stagingCertificates = $sslMode -eq 'staging'
}

$domains = Get-DomainList -PrimaryDomain $primaryDomain -IncludeWwwAlias $includeWwwAlias
$serverNameValue = Build-NginxServerNameValue -Domains $domains
$generatedNginxPath = Join-Path $projectRoot 'nginx.generated.conf'
$generatedComposePath = Join-Path $projectRoot 'docker-compose.direct.yml'

if ($enableSsl) {
  New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'certbot') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'certbot\www') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'certbot\conf') | Out-Null
  $nginxConfigContent = Build-HttpsConfigContent -ServerNameValue $serverNameValue
} else {
  $nginxConfigContent = Build-HttpOnlyConfigContent -ServerNameValue $serverNameValue
}

$composeContent = Build-ComposeContent -ProjectName $projectName -HttpPort $httpPort -EnableSsl $enableSsl

Set-Content -Path $generatedNginxPath -Value $nginxConfigContent -Encoding UTF8
Set-Content -Path $generatedComposePath -Value $composeContent -Encoding UTF8

Write-Host ''
Write-Host 'Deployment summary' -ForegroundColor Cyan
Write-Host "- Project name: $projectName"
Write-Host "- Domains: $($domains -join ', ')"
Write-Host "- HTTP port: $httpPort"
Write-Host "- SSL enabled: $enableSsl"
if ($enableSsl) {
  Write-Host "- SSL mode: $sslMode"
  Write-Host "- SSL email: $emailAddress"
}
Write-Host ''
Write-Host 'DNS requirements' -ForegroundColor Cyan
Write-Host '- Point your domain(s) to this server before requesting SSL certificates.'
Write-Host '- Use A records for the apex domain and www if enabled.'
Write-Host ''

if (-not (Read-YesNoValue -PromptText 'Generate files and start deployment now?' -DefaultValue $true)) {
  Write-Host 'Generated files are ready. Start deployment later with docker compose -f docker-compose.direct.yml up -d --build' -ForegroundColor Yellow
  exit 0
}

docker compose -f $generatedComposePath up -d --build

if ($enableSsl) {
  Ensure-CommandExists -CommandName 'docker' -InstallHint 'Docker must be installed for the certbot flow.'

  $domainArguments = @()
  foreach ($singleDomain in $domains) {
    $domainArguments += '-d'
    $domainArguments += $singleDomain
  }

  $certbotArguments = @(
    'run', '--rm',
    '-v', "${projectRoot}\certbot\conf:/etc/letsencrypt",
    '-v', "${projectRoot}\certbot\www:/var/www/certbot",
    'certbot/certbot', 'certonly', '--webroot', '-w', '/var/www/certbot'
  )

  if ($stagingCertificates) {
    $certbotArguments += '--staging'
  }

  $certbotArguments += '--email'
  $certbotArguments += $emailAddress
  $certbotArguments += '--agree-tos'
  $certbotArguments += '--no-eff-email'
  $certbotArguments += $domainArguments

  Write-Host ''
  Write-Host 'Requesting SSL certificates...' -ForegroundColor Cyan
  & docker @certbotArguments

  Write-Host 'Restarting nginx with SSL config...' -ForegroundColor Cyan
  docker compose -f $generatedComposePath restart
}

Write-Host ''
Write-Host 'Direct deployment completed.' -ForegroundColor Green
Write-Host "Use this compose file for future updates: $generatedComposePath"
