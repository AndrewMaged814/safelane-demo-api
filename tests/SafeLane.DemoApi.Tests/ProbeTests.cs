using System.Net;
using System.Text;
using SafeLane.DemoProbe;

namespace SafeLane.DemoApi.Tests;

public sealed class ProbeTests
{
    [Fact]
    public async Task HealthyCanaryPassesEveryAssertion()
    {
        var result = await RunProbe(_ => Demo(HttpStatusCode.OK, "ok"));
        Assert.True(result.Passed);
        Assert.All(result.Assertions, assertion => Assert.True(assertion.Passed, assertion.Id));
    }

    [Fact]
    public async Task GreenHealthCannotHideBrokenDemoSemantics()
    {
        var result = await RunProbe(_ => Demo(HttpStatusCode.OK, "degraded"));
        Assert.False(result.Passed);
        Assert.False(result.Assertions.Single(assertion => assertion.Id == "demo-response").Passed);
    }

    [Fact]
    public async Task FailureRateAboveFivePercentFails()
    {
        var result = await RunProbe(request => request < 18 ? Demo(HttpStatusCode.OK, "ok") : Demo(HttpStatusCode.ServiceUnavailable, "degraded"));
        Assert.False(result.Assertions.Single(assertion => assertion.Id == "demo-success-rate").Passed);
    }

    [Fact]
    public async Task WrongCanaryCommitFailsIdentity()
    {
        var result = await RunProbe(_ => Demo(HttpStatusCode.OK, "ok"), actualCommit: "different");
        Assert.False(result.Assertions.Single(assertion => assertion.Id == "canary-identity").Passed);
    }

    [Fact]
    public async Task SlowCanaryFailsP95Latency()
    {
        var result = await RunProbe(async _ => { await Task.Delay(15); return Demo(HttpStatusCode.OK, "ok"); }, maxP95: 1);
        Assert.False(result.Assertions.Single(assertion => assertion.Id == "demo-latency").Passed);
    }

    private static async Task<ProbeResult> RunProbe(Func<int, HttpResponseMessage> demo, string actualCommit = "expected", double maxP95 = 500) =>
        await RunProbe(request => Task.FromResult(demo(request)), actualCommit, maxP95);

    private static async Task<ProbeResult> RunProbe(Func<int, Task<HttpResponseMessage>> demo, string actualCommit = "expected", double maxP95 = 500)
    {
        var demoRequest = 0;
        var handler = new StubHandler(async request =>
            request.RequestUri!.AbsolutePath == "/version"
                ? Json(HttpStatusCode.OK, $$"""{"commit":"{{actualCommit}}"}""")
                : await demo(demoRequest++));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://canary/") };
        return await ProbeRunner.RunAsync(client, new ProbeConfiguration(client.BaseAddress, "expected", 20, 0.95, maxP95), CancellationToken.None);
    }

    private static HttpResponseMessage Demo(HttpStatusCode code, string status) => Json(code, $$"""{"status":"{{status}}"}""");
    private static HttpResponseMessage Json(HttpStatusCode code, string body) => new(code) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private sealed class StubHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }
}
