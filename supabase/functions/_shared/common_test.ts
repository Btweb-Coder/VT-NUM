import { decimalToCents, readJson } from "./common.ts";

Deno.test("provider USD prices convert with exact half-up cent rounding", () => {
  const cases: [unknown, number][] = [
    ["0.55", 55],
    ["1.005", 101],
    ["1.004", 100],
  ];
  for (const [input, expected] of cases) {
    if (decimalToCents(input) !== expected) {
      throw new Error(`rounding failed for ${input}`);
    }
  }
});

Deno.test("invalid or missing provider prices are rejected", () => {
  for (const input of [undefined, null, "", "-1", "NaN", "0"]) {
    let rejected = false;
    try {
      decimalToCents(input);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`accepted invalid provider price ${input}`);
  }
});

Deno.test("request bodies are size bounded and must be JSON objects", async () => {
  const parsed = await readJson(
    new Request("https://local", {
      method: "POST",
      body: JSON.stringify({ country_code: 7 }),
    }),
  );
  if (parsed.country_code !== 7) {
    throw new Error("valid request JSON was not parsed");
  }
  let rejected = false;
  try {
    await readJson(
      new Request("https://local", {
        method: "POST",
        body: JSON.stringify({ value: "a".repeat(20) }),
      }),
      10,
    );
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error("oversize body was not rejected");
});
