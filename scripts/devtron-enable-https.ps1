param(
    [string]$Context = "gitops-aks-admin",
    [string]$Namespace = "devtroncd",
    [string]$PublicHost,
    [string]$ManifestPath = ".\gitops\apps\devtron-https\devtron-https-proxy.yaml"
)

$ErrorActionPreference = "Stop"

if (-not $PublicHost) {
    $PublicHost = kubectl --context $Context -n $Namespace get service devtron-service -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
}

if (-not $PublicHost) {
    throw "Could not determine Devtron public host from service devtron-service. Pass -PublicHost explicitly."
}

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$subject = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new("CN=$PublicHost")
$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    $subject,
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

$serverAuthOid = [System.Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.1")
$enhancedKeyUsages = [System.Security.Cryptography.OidCollection]::new()
$enhancedKeyUsages.Add($serverAuthOid) | Out-Null
$request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
        $enhancedKeyUsages,
        $false
    )
)
$request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,
        $false
    )
)

$san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
$ip = $null
if ([System.Net.IPAddress]::TryParse($PublicHost, [ref]$ip)) {
    $san.AddIpAddress($ip)
} else {
    $san.AddDnsName($PublicHost)
}
$san.AddDnsName("devtron-service.$Namespace.svc.cluster.local")
$request.CertificateExtensions.Add($san.Build())

$notBefore = [System.DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter = $notBefore.AddDays(90)
$cert = $request.CreateSelfSigned($notBefore, $notAfter)

function ConvertTo-PemBlock {
    param(
        [string]$Label,
        [byte[]]$Bytes
    )
    $base64 = [System.Convert]::ToBase64String($Bytes)
    $lines = for ($index = 0; $index -lt $base64.Length; $index += 64) {
        $base64.Substring($index, [System.Math]::Min(64, $base64.Length - $index))
    }
    "-----BEGIN $Label-----`n$($lines -join "`n")`n-----END $Label-----`n"
}

function Export-PrivateKeyBytes {
    param([System.Security.Cryptography.RSA]$Key)

    if ($Key.GetType().GetMethod("ExportPkcs8PrivateKey", [System.Type[]]@())) {
        return $Key.ExportPkcs8PrivateKey()
    }

    if ($Key -is [System.Security.Cryptography.RSACng]) {
        return $Key.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
    }

    throw "This PowerShell runtime cannot export the generated RSA key as PKCS#8."
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("devtron-https-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir | Out-Null

try {
    $certPath = Join-Path $workDir "tls.crt"
    $keyPath = Join-Path $workDir "tls.key"
    Set-Content -Path $certPath -Value (ConvertTo-PemBlock -Label "CERTIFICATE" -Bytes $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)) -NoNewline
    Set-Content -Path $keyPath -Value (ConvertTo-PemBlock -Label "PRIVATE KEY" -Bytes (Export-PrivateKeyBytes -Key $rsa)) -NoNewline

    kubectl --context $Context -n $Namespace create secret tls devtron-https-tls `
        --cert $certPath `
        --key $keyPath `
        --dry-run=client `
        -o yaml | kubectl --context $Context apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create or update devtron-https-tls."
    }

    kubectl --context $Context apply -f $ManifestPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply Devtron HTTPS proxy manifest."
    }

    $patchPath = Join-Path $workDir "service-patch.json"
    Set-Content -Path $patchPath -Value '[{"op":"replace","path":"/spec/ports","value":[{"name":"https","port":443,"protocol":"TCP","targetPort":"https"}]}]'
    kubectl --context $Context -n $Namespace patch service devtron-service --type=json --patch-file $patchPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to make devtron-service HTTPS-only."
    }

    $secretJson = kubectl --context $Context -n $Namespace get secret devtron-secret -o json | ConvertFrom-Json
    $secretPatch = @()
    foreach ($key in @("url", "dex.config")) {
        if ($secretJson.data.PSObject.Properties.Name -notcontains $key) {
            continue
        }

        $currentValue = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($secretJson.data.$key))
        $updatedValue = $currentValue -replace "http://$([regex]::Escape($PublicHost))", "https://$PublicHost"
        if ($key -eq "dex.config") {
            $updatedValue = $updatedValue -replace "(?m)^\s*-\s*groups\s*\r?\n", ""
            if ($updatedValue -notmatch "(?m)^\s*claimMapping:\s*$") {
                $claimMapping = "`$1getUserInfo: true`n`$1claimMapping:`n`$1  email: preferred_username`n`$1  preferred_username: preferred_username"
                $updatedValue = $updatedValue -replace "(?m)^(\s*)getUserInfo:\s*true\s*$", $claimMapping
            }
            if ($updatedValue -notmatch "(?m)^\s*insecureSkipEmailVerified:\s*true\s*$") {
                $skipEmailVerified = "`$1insecureEnableGroups: true`n`$1insecureSkipEmailVerified: true"
                $updatedValue = $updatedValue -replace "(?m)^(\s*)insecureEnableGroups:\s*true\s*$", $skipEmailVerified
            }
        }
        if ($updatedValue -ne $currentValue) {
            $secretPatch += @{
                op    = "replace"
                path  = "/data/$key"
                value = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($updatedValue))
            }
        }
    }

    if ($secretPatch.Count -gt 0) {
        $secretPatchPath = Join-Path $workDir "devtron-secret-patch.json"
        $secretPatch | ConvertTo-Json -Compress | Set-Content -Path $secretPatchPath
        kubectl --context $Context -n $Namespace patch secret devtron-secret --type=json --patch-file $secretPatchPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to patch Devtron OIDC URL values in devtron-secret."
        }

        kubectl --context $Context -n $Namespace rollout restart deployment/devtron deployment/argocd-dex-server
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restart Devtron and Dex after OIDC URL update."
        }
    }

    kubectl --context $Context -n $Namespace rollout status deployment/devtron-https-proxy --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        throw "Devtron HTTPS proxy rollout did not complete."
    }

    kubectl --context $Context -n $Namespace rollout status deployment/devtron --timeout=240s
    if ($LASTEXITCODE -ne 0) {
        throw "Devtron rollout did not complete."
    }

    kubectl --context $Context -n $Namespace rollout status deployment/argocd-dex-server --timeout=240s
    if ($LASTEXITCODE -ne 0) {
        throw "Dex rollout did not complete."
    }

    Write-Host "Devtron HTTPS enabled at https://$PublicHost/dashboard/"
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
