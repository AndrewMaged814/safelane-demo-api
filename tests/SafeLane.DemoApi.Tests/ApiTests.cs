using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;

namespace SafeLane.DemoApi.Tests;

public sealed class ApiTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> factory;
    private readonly HttpClient client;

    public ApiTests(WebApplicationFactory<Program> factory)
    {
        this.factory = factory;
        client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            AllowAutoRedirect = false
        });
}
    [Fact]
    public async Task Landing_page_introduces_the_demo_api()
    {
        var response = await client.GetAsync("/");
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/html", response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("SafeLane Demo API", body);
    }

    [Fact]
    public async Task Health_endpoint_reports_healthy()
    {
        var response = await client.GetAsync("/healthz");
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("healthy", body);
    }

    [Fact]
    public async Task Version_endpoint_identifies_a_local_build()
    {
        var response = await client.GetFromJsonAsync<VersionResponse>("/version");

        Assert.NotNull(response);
        Assert.Equal("dev", response.Version);
        Assert.Equal("unknown", response.Commit);
    }

    [Fact]
    public async Task Demo_endpoint_succeeds_with_safe_defaults()
    {
        var response = await client.GetAsync("/api/demo");
        var body = await response.Content.ReadFromJsonAsync<DemoResponse>();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("ok", body?.Status);
    }

    [Fact]
    public async Task Demo_endpoint_returns_service_unavailable_at_full_failure_rate()
    {
        using var failingFactory = factory.WithWebHostBuilder(builder =>
            builder.UseSetting("DEMO_FAILURE_RATE", "100"));
        using var failingClient = failingFactory.CreateClient();

        var response = await failingClient.GetAsync("/api/demo");
        var body = await response.Content.ReadFromJsonAsync<DemoResponse>();

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("degraded", body?.Status);
    }

    [Fact]
    public async Task Demo_endpoint_honors_configured_latency()
    {
        using var slowFactory = factory.WithWebHostBuilder(builder =>
            builder.UseSetting("DEMO_LATENCY_MS", "100"));
        using var slowClient = slowFactory.CreateClient();
        var stopwatch = Stopwatch.StartNew();

        var response = await slowClient.GetAsync("/api/demo");

        stopwatch.Stop();
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(stopwatch.ElapsedMilliseconds >= 90,
            $"Expected at least 90 ms of latency, observed {stopwatch.ElapsedMilliseconds} ms.");
    }

    private sealed record VersionResponse(string Version, string Commit);
    private sealed record DemoResponse(string Status);
}
