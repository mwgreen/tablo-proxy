#!/bin/bash
# Start tablo-proxy and open the browser

cd "$(dirname "$0")"

PORT=$(grep '^PORT=' .env 2>/dev/null | cut -d= -f2)
PORT=${PORT:-9480}

npm start &
SERVER_PID=$!

echo "Waiting for server to be ready (this may take a minute)..."
for i in $(seq 1 120); do
  if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
    echo "Server is ready!"
    open "http://localhost:$PORT"
    break
  fi
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server exited unexpectedly."
    exit 1
  fi
  sleep 1
done

wait $SERVER_PID
