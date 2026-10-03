import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ["GRAFANA_URL"].rstrip("/")
TOKEN = os.environ["GRAFANA_TOKEN"]


def request(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def ensure_folder(uid, title):
    # POST creates; 412 means the folder already exists.
    code, body = request("POST", "/api/folders", {"uid": uid, "title": title})
    if code in (200, 201, 412):
        print(f"folder {uid}: ok ({code})")
    else:
        print(f"folder {uid}: FAILED {code} {body}")
        sys.exit(1)


def upsert_rule(rule):
    uid = rule["uid"]
    code, body = request("PUT", f"/api/v1/provisioning/alert-rules/{uid}", rule)
    if code == 404:
        code, body = request("POST", "/api/v1/provisioning/alert-rules", rule)
    if code in (200, 201):
        print(f"rule {uid}: ok ({code})")
    else:
        print(f"rule {uid}: FAILED {code} {body}")
        sys.exit(1)


ensure_folder("riko", "riko")
with open("/config/rules.json") as f:
    for rule in json.load(f):
        upsert_rule(rule)
print("done")
