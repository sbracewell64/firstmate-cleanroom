#!/usr/bin/env bash
# Parse a workflow YAML mapping as JSON using one qualified capability owner.
# Prefer the validation Python's PyYAML; Ruby/Psych is a compatible fallback.
# --probe prints backend<TAB>library-version<TAB>executable on stdout.
# A missing capability is ENVIRONMENT_UNREADY (exit 1); invalid YAML also fails.
# This owner observes and parses only: it never installs or changes PATH.
# Usage: fm-workflow-yaml.sh --probe | <workflow-file>
set -u
[ "$#" -eq 1 ] || { printf 'usage: fm-workflow-yaml.sh --probe | <workflow-file>\n' >&2; exit 2; }
backend='' version='' parser=''
if parser=$(command -v python3 2>/dev/null) && version=$("$parser" -c 'import yaml,json; d=yaml.safe_load("jobs: {probe: {timeout-minutes: 20}}"); assert d["jobs"]["probe"]["timeout-minutes"] == 20; json.dumps(d); print(yaml.__version__)' 2>/dev/null); then
  backend=python3
elif parser=$(command -v ruby 2>/dev/null) && version=$("$parser" -ryaml -rjson -e 'd=YAML.safe_load("jobs: {probe: {timeout-minutes: 20}}"); raise "capability" unless d.fetch("jobs").fetch("probe").fetch("timeout-minutes")==20; JSON.generate(d); puts Psych::VERSION' 2>/dev/null); then
  backend=ruby
else
  printf 'ENVIRONMENT_UNREADY: workflow-yaml CAPABILITY_MISSING; owner: provision PyYAML in the validation Python environment (or Ruby with YAML/JSON), then run bin/fm-workflow-yaml.sh --probe from the actual gate shell.\n' >&2
  exit 1
fi
if [ "$1" = --probe ]; then
  printf '%s\t%s\t%s\n' "$backend" "$version" "$parser"
  exit 0
fi
case "$backend" in
  python3)
    exec "$parser" -c 'import json,sys,yaml
with open(sys.argv[1], encoding="utf-8") as f: doc=yaml.safe_load(f)
if not isinstance(doc, dict): raise ValueError("workflow root must be a mapping")
print(json.dumps(doc))' "$1"
    ;;
  ruby)
    exec "$parser" -ryaml -rjson -e 'doc=YAML.safe_load(File.read(ARGV[0]), aliases: true); raise "workflow root must be a mapping" unless doc.is_a?(Hash); puts JSON.generate(doc)' "$1"
    ;;
esac
