# Demo infrastructure bootstrap

This directory contains the one-time, operator-run infrastructure bootstrap for the SafeLane demo.
It is intentionally separate from SafeLane itself: SafeLane validates and uses these pre-provisioned
identities; it does not create cluster namespaces, RBAC, or credentials.

## Bootstrap

Run this from the repository root with a cluster-operator kubeconfig context and an immutable image
reference that has already been published by CI:

```powershell
.\infra\bootstrap-safelane-demo-api.ps1 `
  -AdminContext safelane-admin `
  -ImageReference ghcr.io/andrewmaged814/safelane-demo-api@sha256:<digest>
```

The script creates the `safelane-demo-api` namespace, the baseline Argo Rollout and Services,
namespace-scoped caller/controller RBAC, a caller context in the default kubeconfig, and the
controller kubeconfig expected by SafeLane. It asks for `APPLY` before changing anything.

The generated service-account tokens default to a 24-hour lifetime. For a longer-lived hackathon
session, pass an explicit duration supported by the cluster, for example `-TokenDuration 8h` or
`-TokenDuration 24h`.

Use `-WhatIf` to validate the inputs and print the planned actions without applying them.
