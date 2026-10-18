"""Create a Direct Upload Pages project without provisioning paid services."""
import json
import os
import re
import urllib.error
import urllib.request

channel = os.environ["CHANNEL"]
if channel not in ("canary", "stable"):
    raise SystemExit("Unknown release channel")
project = f"tensamin-{channel}"
account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
token = os.environ["CLOUDFLARE_API_TOKEN"]
if not re.fullmatch(r"[0-9a-fA-F]{32}", account):
    raise SystemExit("CLOUDFLARE_ACCOUNT_ID must be a Cloudflare account ID")
base = f"https://api.cloudflare.com/client/v4/accounts/{account}/pages/projects"
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def request(url, data=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers, data=data), timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and data is None:
            return None
        raise SystemExit(f"Cloudflare Pages API returned HTTP {error.code}; credentials have not been displayed.") from None
    except urllib.error.URLError:
        raise SystemExit("Could not reach the Cloudflare Pages API") from None
    if not result.get("success"):
        raise SystemExit("Cloudflare rejected the Pages request; credentials have not been displayed.")
    return result["result"]

settings = request(f"{base}/{project}")
if settings is None:
    settings = request(base, json.dumps({"name": project, "production_branch": "main"}).encode())
if settings.get("source") or settings.get("production_branch") != "main":
    raise SystemExit("The channel project must use Direct Upload with production branch main")
print(f"Pages project ready: {project}. Static-only deployment; no paid Worker or subscription is created.")
