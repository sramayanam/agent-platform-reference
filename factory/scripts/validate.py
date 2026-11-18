"""Lint/validate stage: every factory/agents/*.yaml must match the schema, point at a buildable folder,
use a unique name, and (cpu, memory) must be a supported sandbox size."""
import glob, json, os, sys
import jsonschema, yaml

schema = json.load(open("factory/agent.schema.json"))
sizes = {("0.5", "1Gi"), ("1", "2Gi"), ("2", "4Gi")}
files = sys.argv[1:] or sorted(glob.glob("factory/agents/*.yaml"))
names, errors = {}, []
for f in files:
    try:
        d = yaml.safe_load(open(f))
        jsonschema.validate(d, schema)
        if not os.path.isfile(os.path.join(d["source"], "Dockerfile")):
            errors.append(f"{f}: source '{d['source']}' has no Dockerfile")
        if (d.get("cpu", "0.5"), d.get("memory", "1Gi")) not in sizes:
            errors.append(f"{f}: cpu/memory must be one of {sorted(sizes)}")
        if d["name"] in names:
            errors.append(f"{f}: duplicate name '{d['name']}' (also in {names[d['name']]})")
        names[d["name"]] = f
        if os.path.splitext(os.path.basename(f))[0] != d["name"]:
            errors.append(f"{f}: file name must equal agent name")
    except Exception as e:  # noqa: BLE001
        errors.append(f"{f}: {e}")
print("\n".join(errors) or f"OK: {len(files)} agent definition(s) valid")
sys.exit(1 if errors else 0)
