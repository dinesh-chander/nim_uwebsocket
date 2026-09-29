using System.Diagnostics;
using System.Text.Json;

const int WarmupPasses = 10;

static (double ops, double ns) Bench(int iterations, Action action)
{
    var sw = Stopwatch.StartNew();
    for (var i = 0; i < iterations; i++) action();
    sw.Stop();
    var elapsedNs = sw.Elapsed.TotalMilliseconds * 1_000_000.0;
    return (iterations / (elapsedNs / 1_000_000_000.0), elapsedNs / iterations);
}

static (double ops, double ns) BenchSecondPass(int iterations, Action action)
{
    for (var i = 0; i < WarmupPasses; i++) Bench(iterations, action);
    return Bench(iterations, action);
}

static int ChooseIterations(int payloadBytes)
{
    if (payloadBytes < 64 * 1024) return 300;
    if (payloadBytes < 512 * 1024) return 120;
    if (payloadBytes < 2 * 1024 * 1024) return 40;
    return 12;
}

var dataDir = args.Length > 0 && Directory.Exists(args[0]) ? args[0] : Path.Combine("benchmark", "data");
var files = new[]
{
    (dataset: "twitter", file: "twitter.json"),
    (dataset: "citm", file: "citm_catalog.json"),
    (dataset: "canada", file: "canada.json"),
    (dataset: "historical", file: "historical_events.json")
};

foreach (var (dataset, file) in files)
{
    var payload = File.ReadAllText(Path.Combine(dataDir, file));
    var payloadBytes = System.Text.Encoding.UTF8.GetByteCount(payload);
    var iterations = ChooseIterations(payloadBytes);
    var parsed = JsonSerializer.Deserialize<JsonElement>(payload);
    var deser = BenchSecondPass(iterations, () => { JsonSerializer.Deserialize<JsonElement>(payload); });
    var ser = BenchSecondPass(iterations, () => { JsonSerializer.Serialize(parsed); });
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        dataset,
        payload_bytes = payloadBytes,
        iterations,
        deserialize_ops = deser.ops,
        deserialize_ns = deser.ns,
        serialize_ops = ser.ops,
        serialize_ns = ser.ns
    }));
}
