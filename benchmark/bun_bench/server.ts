import { Database } from "bun:sqlite";

type JsonResponse = {
  message: string;
  timestamp: number;
  id: number;
  success: boolean;
};

type TodoRow = {
  id: number;
  title: string;
  completed: number;
  created_at: string;
};

type TemplateLocals = {
  title: string;
  heading: string;
  description: string;
};

const PORT = Number(Bun.env.BUN_PORT ?? "3004");
const TODO_DB_PATH = Bun.env.BUN_TODO_DB_PATH ?? "/tmp/bun_uwebsocket_endpoint_bench.db";
const TODO_SEED = Number(Bun.env.BUN_TODO_SEED ?? "1000");

const TEXT_HEADERS = {
  "Content-Type": "text/plain; charset=utf-8"
};

const HTML_HEADERS = {
  "Content-Type": "text/html; charset=utf-8"
};

const JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8"
};

const HOME_TEMPLATE = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{{title}}</title>
  </head>
  <body>
    <main>
      <h1>{{heading}}</h1>
      <p>{{description}}</p>
    </main>
  </body>
</html>`;

const TODO_TEMPLATE = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Todo Fragment</title>
  </head>
  <body>
    <main>
      <header>
        <h1>Todos</h1>
        <p>Total: {{count}}</p>
      </header>
      <section>
        <ul>
          {{items}}
        </ul>
      </section>
    </main>
  </body>
</html>`;

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderTemplate(template: string, values: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key: string) => values[key] ?? "");
}

function renderHomePage(): string {
  const locals: TemplateLocals = {
    title: "bun_bench",
    heading: "Welcome to bun_bench!",
    description: "Comparable endpoint benchmark for Bun."
  };

  return renderTemplate(HOME_TEMPLATE, {
    title: escapeHtml(locals.title),
    heading: escapeHtml(locals.heading),
    description: escapeHtml(locals.description)
  });
}

function renderTodoItem(todo: TodoRow): string {
  const checked = todo.completed ? "checked" : "";
  return `<li data-id="${todo.id}">
    <label>
      <input type="checkbox" ${checked} disabled />
      <span>${escapeHtml(todo.title)}</span>
    </label>
    <small>${escapeHtml(todo.created_at)}</small>
  </li>`;
}

function renderTodoPage(todos: TodoRow[], mode: string): string {
  const items = todos.map(renderTodoItem).join("\n");
  if (mode === "fragment") {
    return `<ul>${items}</ul>`;
  }
  return renderTemplate(TODO_TEMPLATE, {
    count: String(todos.length),
    items
  });
}

function seedTodos(db: Database, count: number): void {
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA temp_store = MEMORY;
    PRAGMA cache_size = -64000;
    PRAGMA mmap_size = 268435456;
    PRAGMA journal_size_limit = 67108864;
    PRAGMA wal_autocheckpoint = 1000;

    CREATE TABLE IF NOT EXISTS todos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    DELETE FROM todos;
  `);

  const insert = db.query(
    "INSERT INTO todos(title, completed, created_at) VALUES (?, ?, ?)"
  );

  db.exec("BEGIN");
  for (let i = 1; i <= count; i += 1) {
    insert.run(`seed-${i}`, 0, new Date().toISOString());
  }
  db.exec("COMMIT");
}

function createJsonResponse(): JsonResponse {
  return {
    message: "Hello, World!",
    timestamp: Math.floor(Date.now() / 1000),
    id: Math.floor(Math.random() * 999999) + 1,
    success: true
  };
}

const db = new Database(TODO_DB_PATH);
seedTodos(db, TODO_SEED);
const todoListQuery = db.query(
  "SELECT id, title, completed, created_at FROM todos ORDER BY id DESC"
);

function handleTodos(url: URL): Response {
  const mode = url.searchParams.get("mode") ?? "full";
  const todos = todoListQuery.all() as TodoRow[];
  return new Response(renderTodoPage(todos, mode), {
    headers: HTML_HEADERS
  });
}

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/plaintext") {
      return new Response("Hello, World!", { headers: TEXT_HEADERS });
    }

    if (url.pathname === "/json") {
      return new Response(JSON.stringify(createJsonResponse()), {
        headers: JSON_HEADERS
      });
    }

    if (url.pathname === "/get") {
      return new Response("Hello, World!", { headers: TEXT_HEADERS });
    }

    if (url.pathname === "/getasync") {
      return (async () => {
        await Promise.resolve();
        return new Response("Hello, World!", { headers: TEXT_HEADERS });
      })();
    }

    if (url.pathname === "/") {
      return new Response(renderHomePage(), { headers: HTML_HEADERS });
    }

    if (url.pathname === "/todos/fragment") {
      return handleTodos(url);
    }

    return new Response("Not Found", {
      status: 404,
      headers: TEXT_HEADERS
    });
  }
});

console.log(
  `bun benchmark running on http://127.0.0.1:${PORT} using ${TODO_DB_PATH} (${TODO_SEED} todos)`
);
