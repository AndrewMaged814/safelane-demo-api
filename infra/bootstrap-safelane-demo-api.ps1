[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$AdminContext = 'safelane-admin',
    [string]$Namespace = 'safelane-demo-api',
    [string]$Application = 'safelane-demo-api',
    [string]$ImageReference,
    [string]$TokenDuration = '24h',
    [string]$ControllerKubeconfig
)

$ErrorActionPreference = 'Stop'

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Local
    )

    $commandArguments = if ($Local) { $Arguments } else { @('--context', $AdminContext) + $Arguments }
    $output = & kubectl @commandArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($commandArguments -join ' ') failed:`n$($output -join "`n")"
    }
    return @($output)
}

function Test-KubectlResource {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & kubectl --context $AdminContext @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if (($output -join "`n") -match 'NotFound|not found') {
        return $false
    }
    throw "kubectl --context $AdminContext $($Arguments -join ' ') failed:`n$($output -join "`n")"
}

function Get-KubectlResource {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & kubectl --context $AdminContext @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        return ($output | Out-String | ConvertFrom-Json)
    }
    if (($output -join "`n") -match 'NotFound|not found') {
        return $null
    }
    throw "kubectl --context $AdminContext $($Arguments -join ' ') failed:`n$($output -join "`n")"
}

function Apply-Yaml {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [Parameter(Mandatory)][string]$Description
    )

    if ($WhatIfPreference) {
        Write-Host "WHATIF: apply $Description"
        return
    }

    $temporaryFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $temporaryFile -Value $Yaml -Encoding utf8
        Invoke-Kubectl @('apply', '-f', $temporaryFile) | Write-Host
    }
    finally {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-ControllerKubeconfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$CertificateAuthorityData,
        [Parameter(Mandatory)][string]$Token
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $yaml = @"
apiVersion: v1
kind: Config
clusters:
- name: $ClusterName
  cluster:
    server: $Server
    certificate-authority-data: $CertificateAuthorityData
contexts:
- name: safelane-controller
  context:
    cluster: $ClusterName
    namespace: $Namespace
    user: safelane-controller
current-context: safelane-controller
users:
- name: safelane-controller
  user:
    token: $Token
"@

    if ($WhatIfPreference) {
        Write-Host "WHATIF: write controller kubeconfig $Path"
        return
    }

    Set-Content -LiteralPath $Path -Value $yaml -Encoding utf8 -NoNewline
    Write-Host "Wrote controller kubeconfig: $Path"
}

Require-Command 'kubectl'

if (-not $ControllerKubeconfig) {
    $safeLaneHome = if ($env:SAFELANE_HOME) { $env:SAFELANE_HOME } else { Join-Path $HOME '.safelane' }
    $ControllerKubeconfig = Join-Path $safeLaneHome "apps\$Application\controller.kubeconfig"
}

if (-not $ImageReference) {
    $ImageReference = Read-Host 'Immutable image reference (for example ghcr.io/owner/app@sha256:...)'
}
if ($ImageReference -notmatch '@sha256:[0-9a-fA-F]{64}$') {
    throw "ImageReference must be immutable and end with @sha256:<64 hexadecimal characters>."
}
if ($Namespace -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
    throw "Namespace must be a lowercase Kubernetes DNS label."
}
if ($Application -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
    throw "Application must be a lowercase Kubernetes DNS label."
}

Write-Host 'SafeLane demo infrastructure bootstrap'
Write-Host "  admin context       $AdminContext"
Write-Host "  namespace           $Namespace"
Write-Host "  rollout             $Application"
Write-Host "  image               $ImageReference"
Write-Host "  controller config   $ControllerKubeconfig"
Write-Host ''

$adminIdentity = (Invoke-Kubectl @('auth', 'whoami') | Out-String).Trim()
Write-Host "Admin identity: $adminIdentity"
if ($adminIdentity -match '^system:serviceaccount:') {
    throw 'The admin context resolves to a service account. Use a cluster-operator context for bootstrap.'
}

if (-not (Test-KubectlResource @('get', 'crd', 'rollouts.argoproj.io', '-o', 'name'))) {
    throw 'The Argo Rollouts CRD is not installed in the target cluster.'
}

$clusterView = (Invoke-Kubectl @('config', 'view', '--raw', '-o', 'json') -Local | Out-String | ConvertFrom-Json)
$adminContextEntry = @($clusterView.contexts | Where-Object { $_.name -eq $AdminContext }) | Select-Object -First 1
if (-not $adminContextEntry) {
    throw "Kubeconfig context '$AdminContext' was not found."
}
$clusterName = $adminContextEntry.context.cluster
$clusterEntry = @($clusterView.clusters | Where-Object { $_.name -eq $clusterName }) | Select-Object -First 1
if (-not $clusterEntry) {
    throw "Cluster entry '$clusterName' was not found in the kubeconfig."
}
$server = $clusterEntry.cluster.server
$certificateAuthorityData = $clusterEntry.cluster.'certificate-authority-data'
if (-not $server -or -not $certificateAuthorityData) {
    throw "Cluster '$clusterName' must provide an embedded server and certificate-authority-data."
}

$namespaceExists = Test-KubectlResource @('get', 'namespace', $Namespace, '-o', 'name')
if ($namespaceExists) {
    $namespaceObject = Invoke-Kubectl @('get', 'namespace', $Namespace, '-o', 'json') | Out-String | ConvertFrom-Json
    if ($namespaceObject.metadata.labels.'safelane.dev/managed-by' -ne 'demo-bootstrap') {
        throw "Namespace '$Namespace' already exists without the SafeLane demo bootstrap label; refusing to modify it."
    }
    Write-Host "Namespace '$Namespace' already belongs to this bootstrap; keeping it."
}

$stableServiceName = "$Application-stable"
$canaryServiceName = "$Application-canary"
$existingStableService = Get-KubectlResource @('get', 'service', $stableServiceName, '-n', $Namespace, '-o', 'json')
$existingCanaryService = Get-KubectlResource @('get', 'service', $canaryServiceName, '-n', $Namespace, '-o', 'json')
$existingRollout = Get-KubectlResource @('get', 'rollout', $Application, '-n', $Namespace, '-o', 'json')
$adoptExistingRollout = $false
foreach ($existing in @(
        @{ Kind = 'Service'; Name = $stableServiceName; Object = $existingStableService },
        @{ Kind = 'Service'; Name = $canaryServiceName; Object = $existingCanaryService },
        @{ Kind = 'Rollout'; Name = $Application; Object = $existingRollout }
    )) {
    if ($null -ne $existing.Object -and $existing.Object.metadata.labels.'safelane.dev/managed-by' -ne 'demo-bootstrap') {
        if ($existing.Kind -eq 'Rollout' -and
            $existing.Object.spec.template.spec.containers[0].image -eq $ImageReference) {
            $adoptExistingRollout = $true
            Write-Warning "Rollout '$($existing.Name)' matches this demo image but lacks the bootstrap label; it will be adopted."
            continue
        }
        throw "$($existing.Kind) '$($existing.Name)' already exists without the SafeLane demo bootstrap label; refusing to modify it."
    }
}

$callerContext = "$Application-caller"
$callerUser = "$Application-caller"
$previousContext = (Invoke-Kubectl @('config', 'current-context') -Local | Out-String).Trim()

Write-Host ''
Write-Host 'The following changes will be made:'
if (-not $namespaceExists) { Write-Host "  - create namespace $Namespace" }
Write-Host '  - create/update namespace-scoped caller and controller RBAC'
if ($adoptExistingRollout) { Write-Host "  - adopt existing Rollout $Application (image matches)" }
Write-Host '  - create the baseline Services and Argo Rollout if absent'
Write-Host "  - create a caller context '$callerContext' and make it current"
Write-Host "  - write the controller kubeconfig at $ControllerKubeconfig"
Write-Host ''

if (-not $WhatIfPreference) {
    $confirmation = Read-Host "Type APPLY to continue (current context '$previousContext' will be replaced)"
    if ($confirmation -cne 'APPLY') {
        throw 'Bootstrap cancelled; no changes were applied.'
    }
}

if (-not $namespaceExists) {
    Apply-Yaml -Description "namespace $Namespace" -Yaml @"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
    safelane.dev/application: $Application
"@
}

Apply-Yaml -Description 'SafeLane service accounts and namespace-scoped RBAC' -Yaml @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: safelane-caller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: safelane-controller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: safelane-caller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
rules:
- apiGroups: [argoproj.io]
  resources: [rollouts]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: safelane-caller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
subjects:
- kind: ServiceAccount
  name: safelane-caller
  namespace: $Namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: safelane-caller
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: safelane-controller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
rules:
- apiGroups: [argoproj.io]
  resources: [rollouts, rollouts/status]
  verbs: [get, list, watch, patch]
- apiGroups: ['']
  resources: [services]
  verbs: [get, list, watch, create, update, patch]
- apiGroups: [argoproj.io]
  resources: [analysistemplates]
  verbs: [get, create, update, patch]
- apiGroups: [argoproj.io]
  resources: [analysisruns]
  verbs: [get]
- apiGroups: [networking.k8s.io]
  resources: [ingresses]
  verbs: [get, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: safelane-controller
  namespace: $Namespace
  labels:
    safelane.dev/managed-by: demo-bootstrap
subjects:
- kind: ServiceAccount
  name: safelane-controller
  namespace: $Namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: safelane-controller
"@

if ($adoptExistingRollout) {
    if ($WhatIfPreference) {
        Write-Host "WHATIF: label rollout $Application as managed by demo-bootstrap"
    }
    else {
        Invoke-Kubectl @('label', 'rollout', $Application, 'safelane.dev/managed-by=demo-bootstrap', '--overwrite', '-n', $Namespace) | Write-Host
    }
}

$rolloutExists = $null -ne $existingRollout
if (-not $rolloutExists) {
    Apply-Yaml -Description "baseline Services and Rollout $Application" -Yaml @"
apiVersion: v1
kind: Service
metadata:
  name: $Application-stable
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: $Application
    safelane.dev/managed-by: demo-bootstrap
spec:
  selector:
    app.kubernetes.io/name: $Application
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: $Application-canary
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: $Application
    safelane.dev/managed-by: demo-bootstrap
spec:
  selector:
    app.kubernetes.io/name: $Application
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: $Application
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: $Application
    safelane.dev/managed-by: demo-bootstrap
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: $Application
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $Application
    spec:
      containers:
      - name: $Application
        image: $ImageReference
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
  strategy:
    canary:
      stableService: $Application-stable
      canaryService: $Application-canary
      steps: []
"@
}
else {
    Write-Host "Rollout '$Application' already exists; refusing to replace its image."
}

$callerToken = if ($WhatIfPreference) { '<what-if-token>' } else { (Invoke-Kubectl @('-n', $Namespace, 'create', 'token', 'safelane-caller', '--duration', $TokenDuration) | Out-String).Trim() }
$controllerToken = if ($WhatIfPreference) { '<what-if-token>' } else { (Invoke-Kubectl @('-n', $Namespace, 'create', 'token', 'safelane-controller', '--duration', $TokenDuration) | Out-String).Trim() }

if ($WhatIfPreference) {
    Write-Host "WHATIF: create kubeconfig credentials '$callerUser' and context '$callerContext'"
}
else {
    Invoke-Kubectl @('config', 'set-credentials', $callerUser, "--token=$callerToken") -Local | Write-Host
    Invoke-Kubectl @('config', 'set-context', $callerContext, "--cluster=$clusterName", "--namespace=$Namespace", "--user=$callerUser") -Local | Write-Host
    Invoke-Kubectl @('config', 'use-context', $callerContext) -Local | Write-Host
}

Write-ControllerKubeconfig -Path $ControllerKubeconfig -ClusterName $clusterName -Server $server -CertificateAuthorityData $certificateAuthorityData -Token $controllerToken

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Bootstrap complete. Validating SafeLane...'
    if (Get-Command safelane -ErrorAction SilentlyContinue) {
        & safelane doctor
        if ($LASTEXITCODE -ne 0) {
            throw 'safelane doctor reported a failure; review the output above.'
        }
    }
    else {
        Write-Warning 'SafeLane was not found on PATH; run safelane doctor after installing it.'
    }
    Write-Host ''
    Write-Host "To restore your previous kubeconfig context: kubectl config use-context $previousContext"
    Write-Host "Controller token duration: $TokenDuration"
}
