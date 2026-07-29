"use strict";

jest.mock("../db/pool", () => ({
  query: jest.fn(),
}));

const express = require("express");
const request = require("supertest");
const pool = require("../db/pool");
const healthRouter = require("./health");

const app = express();
app.use("/health", healthRouter);

describe("GET /health", () => {
  it("returns liveness status without touching the database", async () => {
    const res = await request(app).get("/health").expect(200);
    expect(res.body.status).toBe("ok");
    expect(pool.query).not.toHaveBeenCalled();
  });
});

describe("GET /health/ready", () => {
  afterEach(() => {
    pool.query.mockReset();
  });

  it("returns 200 when the database is reachable", async () => {
    pool.query.mockResolvedValueOnce({ rows: [{ "?column?": 1 }] });

    const res = await request(app).get("/health/ready").expect(200);
    expect(res.body).toEqual(
      expect.objectContaining({ status: "ready", database: "reachable" })
    );
  });

  it("returns 503 when the database is unreachable", async () => {
    pool.query.mockRejectedValueOnce(new Error("connection terminated"));

    const res = await request(app).get("/health/ready").expect(503);
    expect(res.body).toEqual(
      expect.objectContaining({ status: "not_ready", database: "unreachable" })
    );
  });
});
