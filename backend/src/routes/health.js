/**
 * src/routes/health.js
 */
"use strict";
const express = require("express");
const router  = express.Router();
const indexerService = require("../services/indexerService");
const pool = require("../db/pool");

router.get("/", (req, res) => res.json({
  status: "ok",
  service: "stellar-greenpay-api",
  network: process.env.STELLAR_NETWORK || "testnet",
  timestamp: new Date().toISOString(),
  indexer: indexerService.getStatus()
}));

// Deep readiness check for GSLB/failover health checks and k8s readiness
// probes: unlike "/", this verifies the database is actually reachable so a
// cluster whose backend pods are alive but DB-cut-off is not routed traffic.
router.get("/ready", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ready", database: "reachable", timestamp: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: "not_ready", database: "unreachable", error: err.message });
  }
});

module.exports = router;
