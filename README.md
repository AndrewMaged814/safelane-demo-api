# SafeLane Demo API

A deliberately small .NET API for exercising container release workflows. It has a visible landing
page, stable health and version endpoints, and controllable application failures and latency.

## Run locally

```powershell
dotnet run --project src/SafeLane.DemoApi
```

Open <http://localhost:5091> or call the endpoints directly:

| Endpoint | Purpose |
| --- | --- |
| `GET /` | Landing page and endpoint links |
| `GET /healthz` | Stable liveness/readiness signal |
| `GET /version` | Service name, image version, and source commit |
| `GET /api/demo` | Controllable application response, with the count of requests this instance has served |

## Control demo behavior

| Environment variable | Default | Allowed behavior |
| --- | ---: | --- |
| `DEMO_FAILURE_RATE` | `0` | Percentage of `/api/demo` requests that return HTTP 503; clamped to 0–100 |
| `DEMO_LATENCY_MS` | `0` | Delay applied to `/api/demo`; clamped to 0–30,000 ms |
| `APP_VERSION` | `dev` | Version returned by `/version` |
| `GIT_SHA` | `unknown` | Commit returned by `/version` |

For a deterministic unhealthy application response while the health endpoint remains healthy:

```powershell
$env:DEMO_FAILURE_RATE = '100'
dotnet run --project src/SafeLane.DemoApi
```

## Test and build the container

```powershell
dotnet test
docker build --build-arg APP_VERSION=local --build-arg GIT_SHA=$(git rev-parse HEAD) -t safelane-demo-api .
docker run --rm -p 8080:8080 safelane-demo-api
```

Every push to `main` runs the tests and publishes the normal API, the external probe, and named
`healthy-redesign`, `broken-demo`, and `final-healthy` fixture variants. Each fixture receives a
commit-qualified tag, and the workflow summary prints its canonical immutable digest. The original
healthy baseline remains the historical `sha-726662d2c396b54cfc047721a41bc67e77643924` image.

## One-time demo infrastructure

The Kubernetes namespace, Argo Rollout, namespace-scoped RBAC, and SafeLane controller credentials
are infrastructure prerequisites rather than SafeLane configuration. A cluster operator can bootstrap
them once with [`infra/bootstrap-safelane-demo-api.ps1`](infra/bootstrap-safelane-demo-api.ps1),
using an immutable image digest from the publish workflow. See [`infra/README.md`](infra/README.md)
for the command and safety notes.
