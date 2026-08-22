using System.Text.Json;
using SafeLane.DemoProbe;

var configuration = ProbeConfiguration.FromEnvironment();
using var client = new HttpClient { BaseAddress = configuration.BaseUri, Timeout = TimeSpan.FromSeconds(5) };
var result = await ProbeRunner.RunAsync(client, configuration, CancellationToken.None);
Console.WriteLine(JsonSerializer.Serialize(result, ProbeJsonContext.Default.ProbeResult));
return result.Passed ? 0 : 1;
