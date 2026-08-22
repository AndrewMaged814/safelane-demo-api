using System.Diagnostics;
using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SafeLane.DemoProbe;

public sealed record ProbeConfiguration(Uri BaseUri, string ExpectedCommit, int RequestCount, double MinimumSuccessRate, double MaximumP95Milliseconds)
{
    public static ProbeConfiguration FromEnvironment()
    {
        var baseUrl = Environment.GetEnvironmentVariable("TARGET_BASE_URL") ?? throw new InvalidOperationException("TARGET_BASE_URL is required");
        var expectedCommit = Environment.GetEnvironmentVariable("EXPECTED_COMMIT") ?? throw new InvalidOperationException("EXPECTED_COMMIT is required");
        return new ProbeConfiguration(
            new Uri(baseUrl.TrimEnd('/') + "/"),
            expectedCommit,
            ParseInt("REQUEST_COUNT", 20),
            ParseDouble("MIN_SUCCESS_RATE", 0.95),
            ParseDouble("MAX_P95_MS", 500));
    }

    private static int ParseInt(string name, int fallback) => int.TryParse(Environment.GetEnvironmentVariable(name), out var value) ? value : fallback;
    private static double ParseDouble(string name, double fallback) => double.TryParse(Environment.GetEnvironmentVariable(name), out var value) ? value : fallback;
}

public sealed record AssertionResult(string Id, bool Passed, string Observed, string Expected);
public sealed record ProbeResult(bool Passed, string Target, int Requests, int Successful, double SuccessRate, double P95Milliseconds, IReadOnlyList<AssertionResult> Assertions);

public static class ProbeRunner
{
    public static async Task<ProbeResult> RunAsync(HttpClient client, ProbeConfiguration configuration, CancellationToken cancellationToken)
    {
        var assertions = new List<AssertionResult>();
        var versionResponse = await client.GetAsync("version", cancellationToken);
        var observedCommit = versionResponse.IsSuccessStatusCode ? await ReadStringProperty(versionResponse, "commit", cancellationToken) : $"HTTP {(int)versionResponse.StatusCode}";
        assertions.Add(new("canary-identity", versionResponse.IsSuccessStatusCode && observedCommit == configuration.ExpectedCommit, observedCommit, configuration.ExpectedCommit));

        var successful = 0;
        var semanticSuccess = 0;
        var latencies = new List<double>(configuration.RequestCount);
        for (var request = 0; request < configuration.RequestCount; request++)
        {
            var started = Stopwatch.GetTimestamp();
            using var response = await client.GetAsync("api/demo", cancellationToken);
            latencies.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
            if (response.StatusCode == HttpStatusCode.OK) successful++;
            if (response.StatusCode == HttpStatusCode.OK && await ReadStringProperty(response, "status", cancellationToken) == "ok") semanticSuccess++;
        }

        latencies.Sort();
        var p95Index = Math.Clamp((int)Math.Ceiling(latencies.Count * 0.95) - 1, 0, latencies.Count - 1);
        var p95 = latencies.Count == 0 ? double.PositiveInfinity : latencies[p95Index];
        var successRate = configuration.RequestCount == 0 ? 0 : (double)successful / configuration.RequestCount;
        assertions.Add(new("demo-response", semanticSuccess == configuration.RequestCount, $"{semanticSuccess}/{configuration.RequestCount} HTTP 200 responses with status=ok", $"{configuration.RequestCount}/{configuration.RequestCount}"));
        assertions.Add(new("demo-success-rate", successRate >= configuration.MinimumSuccessRate, successRate.ToString("P1"), $">= {configuration.MinimumSuccessRate:P1}"));
        assertions.Add(new("demo-latency", p95 <= configuration.MaximumP95Milliseconds, $"{p95:F1}ms", $"<= {configuration.MaximumP95Milliseconds:F1}ms"));

        return new ProbeResult(assertions.All(assertion => assertion.Passed), client.BaseAddress?.ToString() ?? "", configuration.RequestCount, successful, successRate, p95, assertions);
    }

    private static async Task<string> ReadStringProperty(HttpResponseMessage response, string name, CancellationToken cancellationToken)
    {
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            return document.RootElement.TryGetProperty(name, out var value) ? value.GetString() ?? "" : "missing";
        }
        catch (JsonException) { return "invalid-json"; }
    }
}

[JsonSerializable(typeof(ProbeResult))]
public partial class ProbeJsonContext : JsonSerializerContext;
