using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
});

var dbPath = Environment.GetEnvironmentVariable("DOTNET_TODO_DB") ?? "/tmp/dotnet_todo.db";
var portText = Environment.GetEnvironmentVariable("PORT");
var port = int.TryParse(portText, out var parsedPort) ? parsedPort : 3010;
var enableRequestLog = ParseOnOff(Environment.GetEnvironmentVariable("TODO_LOG"));

var csBuilder = new SqliteConnectionStringBuilder
{
    DataSource = dbPath,
    Mode = SqliteOpenMode.ReadWriteCreate,
    Cache = SqliteCacheMode.Shared,
    Pooling = true
};
var connectionString = csBuilder.ToString();

InitDb(connectionString);
var templates = TodoTemplateSet.Load();

var app = builder.Build();
app.Urls.Add($"http://0.0.0.0:{port}");

// CORS + body parser + helmet equivalents (matching nim_express todo app).
app.Use(async (ctx, next) =>
{
    ctx.Response.Headers["Access-Control-Allow-Origin"] = "*";
    ctx.Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS";
    ctx.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, HX-Request, HX-Trigger, HX-Target";

    ctx.Response.Headers["X-Content-Type-Options"] = "nosniff";
    ctx.Response.Headers["X-Frame-Options"] = "SAMEORIGIN";
    ctx.Response.Headers["X-XSS-Protection"] = "1; mode=block";
    ctx.Response.Headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains";
    ctx.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";

    if (HttpMethods.IsOptions(ctx.Request.Method))
    {
        ctx.Response.StatusCode = StatusCodes.Status204NoContent;
        return;
    }

    if (!HttpMethods.IsGet(ctx.Request.Method) &&
        !HttpMethods.IsHead(ctx.Request.Method) &&
        ctx.Request.HasFormContentType)
    {
        _ = await ctx.Request.ReadFormAsync();
    }

    if (enableRequestLog)
    {
        var started = DateTime.UtcNow;
        await next();
        Console.WriteLine($"{ctx.Request.Method} {ctx.Request.Path} => {ctx.Response.StatusCode} {(DateTime.UtcNow - started).TotalMilliseconds:F1}ms");
        return;
    }

    await next();
});

app.MapGet("/", () =>
{
    var html = templates.Index.Render2("title", "Todo MVC + SQLite", "unused", "");
    return Results.Text(html, "text/html; charset=utf-8");
});

app.MapGet("/todos/fragment", async () =>
{
    await using var conn = new SqliteConnection(connectionString);
    await conn.OpenAsync();

    await using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT id, title, completed FROM todos ORDER BY id DESC;";

    await using var reader = await cmd.ExecuteReaderAsync();

    var itemsBuilder = StringBuilderPool.Rent(512 * 1024);
    try
    {
        var remaining = 0;
        var count = 0;

        while (await reader.ReadAsync())
        {
            var id = reader.GetInt64(0);
            var title = HtmlEscape(reader.GetString(1));
            var completed = reader.GetInt64(2) != 0;
            count++;
            if (!completed)
            {
                remaining++;
            }

            var idText = id.ToString(CultureInfo.InvariantCulture);
            var checkedAttr = completed ? " checked" : "";
            var doneClass = completed ? "done" : "";
            templates.Item.Append4(
                itemsBuilder,
                "id", idText,
                "title", title,
                "checked", checkedAttr,
                "done_class", doneClass
            );
        }

        if (count == 0)
        {
            itemsBuilder.Append(templates.EmptyItem);
        }

        var countHtml = templates.Count.Render2(
            "remaining", remaining.ToString(CultureInfo.InvariantCulture),
            "oob", " hx-swap-oob=\"true\""
        );

        var fragment = templates.List.Render2(
            "items", itemsBuilder.ToString(),
            "count_oob", countHtml
        );

        return Results.Text(fragment, "text/html; charset=utf-8");
    }
    finally
    {
        StringBuilderPool.Return(itemsBuilder);
    }
});

app.Run();

static void InitDb(string connectionString)
{
    using var conn = new SqliteConnection(connectionString);
    conn.Open();

    Exec(conn, "PRAGMA journal_mode=WAL;");
    Exec(conn, "PRAGMA synchronous=NORMAL;");
    Exec(conn, "PRAGMA temp_store=MEMORY;");
    Exec(conn, "PRAGMA cache_size=-64000;");
    Exec(conn, "PRAGMA mmap_size=268435456;");
    Exec(conn, "PRAGMA journal_size_limit=67108864;");
    Exec(conn, "PRAGMA wal_autocheckpoint=1000;");
    Exec(conn, "PRAGMA busy_timeout=2000;");

    Exec(conn, """
    CREATE TABLE IF NOT EXISTS todos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    """);
    Exec(conn, "CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(completed);");

    using var countCmd = conn.CreateCommand();
    countCmd.CommandText = "SELECT COUNT(*) FROM todos;";
    var existing = (long)(countCmd.ExecuteScalar() ?? 0L);

    if (existing < 1000)
    {
        using var tx = conn.BeginTransaction();
        using var insertCmd = conn.CreateCommand();
        insertCmd.Transaction = tx;
        insertCmd.CommandText = "INSERT INTO todos(title, completed) VALUES ($title, 0);";
        var titleParam = insertCmd.CreateParameter();
        titleParam.ParameterName = "$title";
        insertCmd.Parameters.Add(titleParam);

        for (var i = existing + 1; i <= 1000; i++)
        {
            titleParam.Value = $"seed-{i}";
            insertCmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    Exec(conn, "PRAGMA optimize;");
}

static void Exec(SqliteConnection conn, string sql)
{
    using var cmd = conn.CreateCommand();
    cmd.CommandText = sql;
    cmd.ExecuteNonQuery();
}

static bool ParseOnOff(string? raw)
{
    if (string.IsNullOrWhiteSpace(raw)) return false;
    return raw.Equals("1", StringComparison.OrdinalIgnoreCase) ||
           raw.Equals("true", StringComparison.OrdinalIgnoreCase) ||
           raw.Equals("yes", StringComparison.OrdinalIgnoreCase) ||
           raw.Equals("on", StringComparison.OrdinalIgnoreCase);
}

static string HtmlEscape(string text)
{
    var needsEscape = false;
    for (var i = 0; i < text.Length; i++)
    {
        var c = text[i];
        if (c is '&' or '<' or '>' or '"' or '\'')
        {
            needsEscape = true;
            break;
        }
    }

    if (!needsEscape)
    {
        return text;
    }

    var sb = new StringBuilder(text.Length + 8);
    foreach (var c in text)
    {
        switch (c)
        {
            case '&': sb.Append("&amp;"); break;
            case '<': sb.Append("&lt;"); break;
            case '>': sb.Append("&gt;"); break;
            case '"': sb.Append("&quot;"); break;
            case '\'': sb.Append("&#39;"); break;
            default: sb.Append(c); break;
        }
    }

    return sb.ToString();
}

file sealed class TodoTemplateSet
{
    public required CompiledTemplate Index { get; init; }
    public required CompiledTemplate List { get; init; }
    public required CompiledTemplate Item { get; init; }
    public required CompiledTemplate Count { get; init; }
    public required string EmptyItem { get; init; }

    public static TodoTemplateSet Load()
    {
        var viewsDir = ResolveViewsDir();
        return new TodoTemplateSet
        {
            Index = CompiledTemplate.Parse(File.ReadAllText(Path.Combine(viewsDir, "index.html"))),
            List = CompiledTemplate.Parse(File.ReadAllText(Path.Combine(viewsDir, "list.html"))),
            Item = CompiledTemplate.Parse(File.ReadAllText(Path.Combine(viewsDir, "item.html"))),
            Count = CompiledTemplate.Parse(File.ReadAllText(Path.Combine(viewsDir, "count.html"))),
            EmptyItem = File.ReadAllText(Path.Combine(viewsDir, "empty_item.html"))
        };
    }

    private static string ResolveViewsDir()
    {
        var baseDir = AppContext.BaseDirectory;
        var cwd = Directory.GetCurrentDirectory();
        var candidates = new[]
        {
            Path.Combine(baseDir, "Views", "todo"),
            Path.GetFullPath(Path.Combine(baseDir, "..", "Views", "todo")),
            Path.Combine(cwd, "Views", "todo"),
            Path.Combine(cwd, "benchmark", "dotnet_todo", "dotnet_todo", "Views", "todo")
        };

        foreach (var candidate in candidates)
        {
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new DirectoryNotFoundException("Could not locate Views/todo directory for dotnet_todo templates.");
    }
}

file sealed class CompiledTemplate
{
    private readonly string[] _parts;
    private readonly string[] _keys;

    private CompiledTemplate(string[] parts, string[] keys)
    {
        _parts = parts;
        _keys = keys;
    }

    public static CompiledTemplate Parse(string templateText)
    {
        var parts = new List<string>();
        var keys = new List<string>();

        var literalStart = 0;
        var i = 0;
        while (i + 1 < templateText.Length)
        {
            if (templateText[i] == '{' && templateText[i + 1] == '{')
            {
                var j = i + 2;
                while (j + 1 < templateText.Length && !(templateText[j] == '}' && templateText[j + 1] == '}'))
                {
                    j++;
                }

                if (j + 1 >= templateText.Length)
                {
                    break;
                }

                parts.Add(templateText[literalStart..i]);

                var keyStart = i + 2;
                var keyEnd = j;
                while (keyStart < keyEnd && char.IsWhiteSpace(templateText[keyStart])) keyStart++;
                while (keyEnd > keyStart && char.IsWhiteSpace(templateText[keyEnd - 1])) keyEnd--;
                keys.Add(templateText[keyStart..keyEnd]);

                i = j + 2;
                literalStart = i;
                continue;
            }

            i++;
        }

        parts.Add(templateText.Length == 0 ? "" : templateText[literalStart..]);
        return new CompiledTemplate(parts.ToArray(), keys.ToArray());
    }

    public void Append4(
        StringBuilder sb,
        string k1, string v1,
        string k2, string v2,
        string k3, string v3,
        string k4, string v4)
    {
        for (var i = 0; i < _keys.Length; i++)
        {
            sb.Append(_parts[i]);
            sb.Append(Resolve4(_keys[i], k1, v1, k2, v2, k3, v3, k4, v4));
        }

        sb.Append(_parts[^1]);
    }

    public string Render2(string k1, string v1, string k2, string v2)
    {
        var sb = new StringBuilder(256);
        for (var i = 0; i < _keys.Length; i++)
        {
            sb.Append(_parts[i]);
            sb.Append(Resolve2(_keys[i], k1, v1, k2, v2));
        }

        sb.Append(_parts[^1]);
        return sb.ToString();
    }

    private static string Resolve2(string key, string k1, string v1, string k2, string v2)
    {
        if (key == k1) return v1;
        if (key == k2) return v2;
        return "";
    }

    private static string Resolve4(
        string key,
        string k1, string v1,
        string k2, string v2,
        string k3, string v3,
        string k4, string v4)
    {
        if (key == k1) return v1;
        if (key == k2) return v2;
        if (key == k3) return v3;
        if (key == k4) return v4;
        return "";
    }
}

file static class StringBuilderPool
{
    [ThreadStatic]
    private static StringBuilder? _cached;

    public static StringBuilder Rent(int capacity)
    {
        var sb = _cached;
        if (sb is null)
        {
            return new StringBuilder(capacity);
        }

        _cached = null;
        sb.Clear();
        if (sb.Capacity < capacity)
        {
            sb.EnsureCapacity(capacity);
        }
        return sb;
    }

    public static void Return(StringBuilder sb)
    {
        if (sb.Capacity > 1024 * 1024)
        {
            return;
        }

        sb.Clear();
        _cached = sb;
    }
}
