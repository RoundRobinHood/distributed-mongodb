#!/bin/bash

set -euo pipefail

wait_for_primary() {
  local servers=("$@")

  while true; do
    for server in "${servers[@]}"; do
      if mongosh --host "$server" --quiet --eval 'db.hello().isWritablePrimary' | grep -q true; then
        echo "Primary found on $server"
        return 0
      fi
    done
    sleep 1
  done
}

wait_for_hosts() {
  local hosts=("$@")
  local pids=()

  for host in "${hosts[@]}"; do
    (
      until mongosh --host "$host" \
        --eval "db.adminCommand('ping')" >/dev/null 2>&1; do
        sleep 2
      done
      echo "$host is up."
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done
}

echo "Waiting for config hosts..."
CONFIG_HOSTS=("config1" "config2" "config3")

wait_for_hosts "${CONFIG_HOSTS[@]}"

echo "Config servers are up, connecting to config1..."

mongosh --eval 'rs.status().ok' --host config1 2>/dev/null || mongosh --host config1 \
  --eval '
  console.log("Setting up config servers...");
  rs.initiate({
    _id: "cfgrs",
    configsvr: true,
    members: [
      { _id: 0, host: "config1:27017" },
      { _id: 1, host: "config2:27017" },
      { _id: 2, host: "config3:27017" }
    ]
  });
'

echo "Finished checking configs"

echo "Waiting for shard1 servers..."
SHARD1_HOSTS=("shard1s1" "shard1s2" "shard1s3")

wait_for_hosts "${SHARD1_HOSTS[@]}"

echo "Shard1 servers are up, connecting..."

mongosh --eval 'rs.status().ok' --host shard1s1 2>/dev/null || mongosh --host shard1s1 \
  --eval '
  console.log("Setting up shard1 servers...");
  rs.initiate({
    _id: "shard1rs",
    members: [
      { _id: 0, host: "shard1s1:27017" },
      { _id: 1, host: "shard1s2:27017" },
      { _id: 2, host: "shard1s3:27017" }
    ]
  });
'

echo "Waiting for shard2 servers..."
SHARD2_HOSTS=("shard2s1" "shard2s2" "shard2s3")

wait_for_hosts "${SHARD2_HOSTS[@]}"

echo "Shard2 servers are up, connecting..."

mongosh --eval 'rs.status().ok' --host shard2s1 2>/dev/null || mongosh --host shard2s1 \
  --eval '
  console.log("Setting up shard2 servers...");
  rs.initiate({
    _id: "shard2rs",
    members: [
      { _id: 0, host: "shard2s1:27017" },
      { _id: 1, host: "shard2s2:27017" },
      { _id: 2, host: "shard2s3:27017" }
    ]
  });
'

echo "All shards and config server setup executed."

echo "Waiting for replica set primaries..."

echo "Waiting for cfgrs primary..."

wait_for_primary "${CONFIG_HOSTS[@]}"

echo "Waiting for shard1rs primary..."

wait_for_primary "${SHARD1_HOSTS[@]}"

echo "Waiting for shard2rs primary..."

wait_for_primary "${SHARD2_HOSTS[@]}"

echo "Temporarily starting mongos..."

touch /mongos.log

mongos --configdb cfgrs/config1:27017,config2:27017,config3:27017 --logpath /mongos.log --port 27018 >/dev/null &
MONGOS_PID=$!

until mongosh --port 27018 --eval "sh.status()" --quiet; do
  echo "Waiting for mongos to become available..."
  sleep 1
done

echo "Checking if shards exist..."

SH_STATUS=$(mongosh --quiet --port 27018 --eval "sh.status()")

if ! echo "$SH_STATUS" | grep -q "shard1rs"; then
  echo "Missing shard1rs, adding shard..."
  mongosh --quiet --port 27018 --eval '
    sh.addShard("shard1rs/shard1s1:27017,shard1s2:27017,shard1s3:27017")
  '
else
  echo "shard1rs is present"
fi

if ! echo "$SH_STATUS" | grep -q "shard2rs"; then
  echo "Missing shard2rs, adding shard..."
  mongosh --quiet --port 27018 --eval '
    sh.addShard("shard2rs/shard2s1:27017,shard2s2:27017,shard2s3:27017")
  '
else
  echo "shard2rs is present"
fi

echo "Checking if testing data is present..."

if ! mongosh --quiet --port 27018 --eval "show databases;" | grep -q "testing_db"; then
  echo "No testing data. Initializing shard configurations..."

  mongosh --quiet --port 27018 --eval '
    console.log("Enabling sharding on testing_db...");
    sh.enableSharding("testing_db");
    
    console.log("Sharding orders collection...");
    sh.shardCollection("testing_db.orders", { address: "hashed" });
  '

  echo "Shards configured. Importing testing data..."

  mongoimport --uri mongodb://127.0.0.1:27018 --db testing_db \
    --collection products --file /testing_data/products.json --jsonArray
  mongoimport --uri mongodb://127.0.0.1:27018 --db testing_db \
    --collection orders --file /testing_data/orders.json --jsonArray
  mongoimport --uri mongodb://127.0.0.1:27018 --db testing_db \
    --collection reviews --file /testing_data/reviews.json --jsonArray

  echo "Successfully added testing data to database."

fi

echo "Running performance tests on mongos..."

TEST_SCRIPT=$(cat <<'EOF'
const db = connect("mongodb://localhost:27018/testing_db");

function hrtimeMs(hr) {
  return (hr[0] * 1000) + (hr[1] / 1e6);
}

function benchmark(opName, fn) {
  const start = process.hrtime();
  const result = fn();
  const duration = hrtimeMs(process.hrtime(start));
  console.log(`${opName} took ${duration.toFixed(2)}ms`);
  return result;
}

console.log("=== Collection Stats ===");
["products", "orders", "reviews"].forEach(col => {
  const stats = db.getCollection(col).stats();
  console.log({
    collection: col,
    count: stats.count,
    sizeMB: (stats.size / (1024*1024)).toFixed(2),
    storageMB: (stats.storageSize / (1024*1024)).toFixed(2),
    indexMB: (stats.totalIndexSize / (1024*1024)).toFixed(2)
  });
});

console.log("=== Benchmarks ===");

// Read latency
benchmark("Simple read", () => db.products.findOne());

// Write latency
benchmark("Simple write", () => db.reviews.insertOne({
  product: db.products.findOne()._id,
  email: "test@example.com",
  rating: 4,
  reviewText: "Load test entry"
}));

// Find + Sort
benchmark("Sorted read", () => db.products.find().sort({ averageRating: -1 }).limit(10).toArray());

// Count documents
benchmark("Count documents in orders", () => db.orders.countDocuments());

// Optional: Index usage info (might be empty if not used yet)
console.log("=== Index Stats ===");
["products", "orders", "reviews"].forEach(col => {
  console.log(`${col} index stats:`);
  try {
    const stats = db.getCollection(col).aggregate([
      { $indexStats: {} }
    ]);
    stats.forEach(stat => console.log(stat));
  } catch (e) {
    console.log(`  Error collecting indexStats: ${e.message}`);
  }
});
EOF
)

mongosh --quiet --port 27018 --eval "$TEST_SCRIPT"

echo "Restarting mongos on public port..."
kill $MONGOS_PID
wait $MONGOS_PID 2>/dev/null || true

exec mongos --configdb cfgrs/config1:27017,config2:27017,config3:27017 \
  --port 27017 \
  --bind_ip_all
