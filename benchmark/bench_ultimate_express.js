// Benchmark: ultimate-express (uWebSockets.js backend)
// Endpoints: /json, /plaintext
// JSON is constructed dynamically each request

const express = require("ultimate-express");
const app = express();

app.get("/json", (req, res) => {
  // Construct response dynamically each request
  const response = {
    message: "Hello, World!",
    timestamp: Math.floor(Date.now() / 1000),
    id: Math.floor(Math.random() * 999999) + 1,
    success: true
  };
  res.json(response);
});

app.get("/plaintext", (req, res) => {
  res.type("text/plain").send("Hello, World!");
});

app.listen(3003, () => {
  console.log("ultimate-express running on http://localhost:3003");
});
