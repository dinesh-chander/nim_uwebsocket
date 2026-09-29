// Benchmark: Standard Express.js
// Endpoints: /json, /plaintext
// Matches the same endpoints as ultimate-express benchmark for comparison

const express = require("express");
const app = express();

app.get("/json", (req, res) => {
  const response = {
    message: "Hello, World!",
    timestamp: Math.floor(Date.now() / 1000),
    id: Math.floor(Math.random() * 999999) + 1,
    success: true,
  };
  res.json(response);
});

app.get("/plaintext", (req, res) => {
  res.type("text/plain").send("Hello, World!");
});

const port = process.env.PORT || 3005;
app.listen(port, () => {
  console.log(`Express running on http://localhost:${port}`);
});
