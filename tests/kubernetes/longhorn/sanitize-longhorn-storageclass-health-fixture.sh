#!/usr/bin/env bash
set -euo pipefail

INPUT_DIR=""
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: sanitize-longhorn-storageclass-health-fixture.sh --input-dir DIR --output-dir DIR

Sanitize a captured longhorn-storageclass-health fixture by replacing environment
names with neutral example values while preserving the relationships needed by
the fixture replay test.

Required input files:
  pvcs.json
  pvs.json
  storageclasses.json
  volumes.json
  replicas.json
  events.json

Safety:
  This is a best-effort sanitizer for fixture minimization. Review sanitized
  output before committing it. Do not treat this as proof that data is safe to
  publish.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-dir)
      INPUT_DIR="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$INPUT_DIR" ]] || { echo "ERROR: --input-dir is required." >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: --output-dir is required." >&2; exit 2; }
[[ -d "$INPUT_DIR" ]] || { echo "ERROR: input directory not found: $INPUT_DIR" >&2; exit 2; }

for fixture in pvcs.json pvs.json storageclasses.json volumes.json replicas.json events.json; do
  [[ -f "$INPUT_DIR/$fixture" ]] || { echo "ERROR: missing input fixture file: $INPUT_DIR/$fixture" >&2; exit 2; }
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

jq -n \
  --slurpfile pvc "$INPUT_DIR/pvcs.json" \
  --slurpfile pv "$INPUT_DIR/pvs.json" \
  --slurpfile sc "$INPUT_DIR/storageclasses.json" \
  --slurpfile volumes "$INPUT_DIR/volumes.json" \
  --slurpfile replicas "$INPUT_DIR/replicas.json" \
  --slurpfile events "$INPUT_DIR/events.json" '
  def map_values($values; $prefix):
    ($values | unique | sort) as $items
    | reduce range(0; $items | length) as $i ({}; . + {($items[$i]): ($prefix + (($i + 1) | tostring))});
  def map_storageclasses($classes):
    reduce ($classes | sort_by(.metadata.name // "") | to_entries[]) as $entry ({};
      . + {($entry.value.metadata.name):
        (if (($entry.value.provisioner // "") == "driver.longhorn.io") then
          (if (($entry.value.metadata.name // "") == "longhorn") then "longhorn" else "longhorn-example" end)
        else
          "example-storageclass-" + (($entry.key + 1) | tostring)
        end)});
  ($pvc[0].items // []) as $pvc_items
  | ($pv[0].items // []) as $pv_items
  | ($sc[0].items // []) as $sc_items
  | ($volumes[0].items // []) as $volume_items
  | ($replicas[0].items // []) as $replica_items
  | ($events[0].items // []) as $event_items
  | map_values(([$pvc_items[].metadata.namespace?, $event_items[].metadata.namespace?] | map(select(. != null and . != ""))); "example-namespace-") as $namespace_map
  | map_values(([$pvc_items[].metadata.name?] | map(select(. != null and . != ""))); "example-pvc-") as $pvc_map
  | map_values(([$pv_items[].metadata.name?, $pvc_items[].spec.volumeName?] | map(select(. != null and . != ""))); "example-pv-") as $pv_map
  | map_storageclasses($sc_items) as $sc_map
  | map_values(([$volume_items[].metadata.name?] | map(select(. != null and . != ""))); "example-longhorn-volume-") as $volume_fallback_map
  | map_values(([$replica_items[].metadata.name?] | map(select(. != null and . != ""))); "example-replica-") as $replica_map
  | map_values(([$replica_items[].spec.nodeID?, $replica_items[].status.currentNodeID?, $volume_items[].status.currentNodeID?] | map(select(. != null and . != ""))); "example-node-") as $node_map
  | {
      namespace_map: $namespace_map,
      pvc_map: $pvc_map,
      pv_map: $pv_map,
      sc_map: $sc_map,
      volume_fallback_map: $volume_fallback_map,
      replica_map: $replica_map,
      node_map: $node_map
    }' > "$tmp_dir/maps.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000001"
    | .metadata.resourceVersion = "1000"
    | .metadata.generation = 1
    | .metadata.labels = {"app.kubernetes.io/name": "example-app", "app.kubernetes.io/part-of": "example-platform"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = [{"apiVersion": "apps/v1", "kind": "StatefulSet", "name": "example-owner", "uid": "00000000-0000-4000-8000-000000000002"}]
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "v1", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  .items |= map(
    .metadata.namespace = (m.namespace_map[.metadata.namespace] // .metadata.namespace // "example-namespace-1")
    | .metadata.name = (m.pvc_map[.metadata.name] // .metadata.name)
    | if .spec.storageClassName? then .spec.storageClassName = (m.sc_map[.spec.storageClassName] // .spec.storageClassName) else . end
    | if .spec.volumeName? then .spec.volumeName = (m.pv_map[.spec.volumeName] // .spec.volumeName) else . end
    | neutral_meta("PersistentVolumeClaim")
  )' "$INPUT_DIR/pvcs.json" > "$OUTPUT_DIR/pvcs.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000003"
    | .metadata.resourceVersion = "1000"
    | .metadata.labels = {"app.kubernetes.io/name": "example-storage", "app.kubernetes.io/part-of": "example-platform"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = []
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "v1", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  .items |= map(.metadata.name = (m.pv_map[.metadata.name] // .metadata.name) | neutral_meta("PersistentVolume"))' \
  "$INPUT_DIR/pvs.json" > "$OUTPUT_DIR/pvs.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000004"
    | .metadata.resourceVersion = "1000"
    | .metadata.labels = {"app.kubernetes.io/name": "example-storageclass", "app.kubernetes.io/part-of": "example-platform"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = []
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "storage.k8s.io/v1", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  .items |= map(.metadata.name = (m.sc_map[.metadata.name] // .metadata.name) | neutral_meta("StorageClass"))' \
  "$INPUT_DIR/storageclasses.json" > "$OUTPUT_DIR/storageclasses.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000005"
    | .metadata.resourceVersion = "1000"
    | .metadata.generation = 1
    | .metadata.labels = {"longhornvolume": .metadata.name, "app.kubernetes.io/part-of": "longhorn-example"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = []
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "longhorn.io/v1beta2", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  def volume_name($name): m.pv_map[$name] // m.volume_fallback_map[$name] // $name;
  .items |= map(
    .metadata.name = volume_name(.metadata.name)
    | if .status.kubernetesStatus.pvName? then .status.kubernetesStatus.pvName = (m.pv_map[.status.kubernetesStatus.pvName] // .status.kubernetesStatus.pvName) else . end
    | if .status.currentNodeID? then .status.currentNodeID = (m.node_map[.status.currentNodeID] // .status.currentNodeID) else . end
    | neutral_meta("Volume")
  )' "$INPUT_DIR/volumes.json" > "$OUTPUT_DIR/volumes.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000006"
    | .metadata.resourceVersion = "1000"
    | .metadata.generation = 1
    | .metadata.labels = {"longhornreplica": .metadata.name, "app.kubernetes.io/part-of": "longhorn-example"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = []
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "longhorn.io/v1beta2", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  def volume_name($name): m.pv_map[$name] // m.volume_fallback_map[$name] // $name;
  .items |= map(
    .metadata.name = (m.replica_map[.metadata.name] // .metadata.name)
    | if .spec.volumeName? then .spec.volumeName = volume_name(.spec.volumeName) else . end
    | if .status.volumeName? then .status.volumeName = volume_name(.status.volumeName) else . end
    | if .spec.nodeID? then .spec.nodeID = (m.node_map[.spec.nodeID] // .spec.nodeID) else . end
    | if .status.currentNodeID? then .status.currentNodeID = (m.node_map[.status.currentNodeID] // .status.currentNodeID) else . end
    | neutral_meta("Replica")
  )' "$INPUT_DIR/replicas.json" > "$OUTPUT_DIR/replicas.json"

jq --slurpfile maps "$tmp_dir/maps.json" '
  def m: $maps[0];
  def neutral_meta($kind):
    .metadata.uid = "00000000-0000-4000-8000-000000000007"
    | .metadata.resourceVersion = "1000"
    | .metadata.labels = {"app.kubernetes.io/name": "example-event", "app.kubernetes.io/part-of": "example-platform"}
    | .metadata.annotations = {"example.com/sanitized": "true"}
    | .metadata.ownerReferences = []
    | .metadata.managedFields = [{"manager": "example-manager", "operation": "Update", "apiVersion": "v1", "fieldsType": "FieldsV1"}]
    | .metadata.sanitizedKind = $kind;
  def mapped_object($name): m.pvc_map[$name] // m.pv_map[$name] // m.volume_fallback_map[$name] // $name;
  .items |= map(
    .metadata.namespace = (m.namespace_map[.metadata.namespace] // .metadata.namespace // "example-namespace-1")
    | .metadata.name = "example-event-" + ((.metadata.name // "1") | tostring | gsub("[^A-Za-z0-9-]"; "-"))
    | if .involvedObject.name? then .involvedObject.name = mapped_object(.involvedObject.name) else . end
    | .message = ("Sanitized " + (.reason // "Kubernetes") + " event for " + (.involvedObject.kind // "object") + "/" + (.involvedObject.name // "example-object"))
    | neutral_meta("Event")
  )' "$INPUT_DIR/events.json" > "$OUTPUT_DIR/events.json"

cat > "$OUTPUT_DIR/README.md" <<'EOF'
# Sanitized Longhorn StorageClass Health Fixture

This fixture was generated by `sanitize-longhorn-storageclass-health-fixture.sh`.

Review before committing. The sanitizer preserves Longhorn health semantics and
object relationships, but publication safety still requires human review.
EOF

printf 'Sanitized fixture files in: %s\n' "$OUTPUT_DIR"
printf 'Replay with:\n'
printf '  tests/kubernetes/longhorn/run-longhorn-storageclass-health-fixture.sh --fixture-dir %q --output json\n' "$OUTPUT_DIR"
