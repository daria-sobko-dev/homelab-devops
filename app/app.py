"""Small demo web service for the homelab stack.

Endpoints:
  /         HTML status page
  /health   JSON health check (Docker HEALTHCHECK, deploy script, CI smoke test)
  /metrics  Prometheus metrics (blocked from the internet by Traefik)
"""
import os
import socket
import time

from flask import Flask, Response, g, jsonify, render_template_string, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
START_TIME = time.time()

REQUESTS = Counter(
    "app_requests_total", "Total HTTP requests", ["method", "endpoint", "status"]
)
LATENCY = Histogram(
    "app_request_duration_seconds", "HTTP request latency in seconds", ["endpoint"]
)

PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Homelab app</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; color: #222; }
    code { background: #f2f2f2; padding: .1rem .3rem; border-radius: 4px; }
    dt { font-weight: 600; margin-top: .75rem; }
  </style>
</head>
<body>
  <h1>Homelab app is running</h1>
  <p>Deployed automatically by GitHub Actions, served through Traefik with a Let's Encrypt certificate.</p>
  <dl>
    <dt>Version</dt><dd><code>{{ version }}</code></dd>
    <dt>Container</dt><dd><code>{{ hostname }}</code></dd>
    <dt>Uptime</dt><dd>{{ uptime }} s</dd>
  </dl>
</body>
</html>
"""

app = Flask(__name__)


def uptime_seconds() -> int:
    return int(time.time() - START_TIME)


@app.before_request
def start_timer():
    g.start = time.perf_counter()


@app.after_request
def record_metrics(response):
    endpoint = request.url_rule.rule if request.url_rule else "unmatched"
    if endpoint != "/metrics":
        REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
        started = g.get("start", time.perf_counter())
        LATENCY.labels(endpoint).observe(time.perf_counter() - started)
    return response


@app.get("/")
def index():
    return render_template_string(
        PAGE, version=APP_VERSION, hostname=socket.gethostname(), uptime=uptime_seconds()
    )


@app.get("/health")
def health():
    return jsonify(status="ok", version=APP_VERSION, uptime_seconds=uptime_seconds())


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), content_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
