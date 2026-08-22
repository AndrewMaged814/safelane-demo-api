var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Content("""
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>SafeLane Demo API</title></head>
    <body>
      <main>
        <h1>SafeLane Demo API</h1>
        <p>A tiny application for exercising safe, digest-bound releases.</p>
        <ul>
          <li><a href="/healthz">Health</a></li>
          <li><a href="/version">Version</a></li>
          <li><a href="/api/demo">Demo response</a></li>
        </ul>
      </main>
    </body>
    </html>
    """, "text/html"));

app.MapGet("/healthz", () => Results.Text("healthy"));
app.MapGet("/version", (IConfiguration configuration) => new
{
    service = "safelane-demo-api",
    version = configuration["APP_VERSION"] ?? "dev",
    commit = configuration["GIT_SHA"] ?? "unknown"
});

var servedRequests = 0L;
app.MapGet("/api/demo", async (IConfiguration configuration, CancellationToken cancellationToken) =>
{
    var requests = Interlocked.Increment(ref servedRequests);
    var configuredLatency = int.TryParse(configuration["DEMO_LATENCY_MS"], out var latency) ? latency : 0;
    var latencyMs = Math.Clamp(configuredLatency, 0, 30_000);
    var configuredRate = int.TryParse(configuration["DEMO_FAILURE_RATE"], out var rate) ? rate : 0;
    var failureRate = Math.Clamp(configuredRate, 0, 100);

    await Task.Delay(latencyMs, cancellationToken);

    IResult result = Random.Shared.Next(100) < failureRate
        ? Results.Json(new { status = "degraded", requests }, statusCode: StatusCodes.Status503ServiceUnavailable)
        : Results.Ok(new { status = "ok", requests });
    return result;
});

app.Run();
