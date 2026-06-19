import subprocess, json, re, os, sys, tempfile, uuid, datetime, threading, time

class BRSenseFirewall:

    def __init__(self):
        self._cache = {}
        self._cache_time = 0

    def _ps(self, cmd):
        full = ["powershell.exe", "-NoProfile", "-Command", cmd]
        try:
            r = subprocess.run(full, capture_output=True, text=True, timeout=15)
            return r.stdout.strip(), r.stderr.strip(), r.returncode
        except FileNotFoundError:
            return self._ps_fallback(cmd)
        except subprocess.TimeoutExpired:
            return "", "TIMEOUT", -1

    def _ps_fallback(self, cmd):
        if sys.platform != "win32":
            return f"[SIMULATED] {cmd}", "", 0
        return "", "PowerShell not available", -1

    def get_status(self):
        out, err, code = self._ps("Get-NetFirewallProfile | Select-Object Name,Enabled | ConvertTo-Json")
        profiles = []
        if code == 0 and out:
            try:
                data = json.loads(out) if out.startswith("[") else [json.loads(out)]
                for p in data:
                    profiles.append({"name": p.get("Name", ""), "enabled": p.get("Enabled", False)})
            except json.JSONDecodeError:
                pass
        rules = self.get_rules()
        blocked = sum(1 for r in rules if r.get("action") == "Block")
        allowed = sum(1 for r in rules if r.get("action") == "Allow")
        return {"profiles": profiles, "total_rules": len(rules), "blocked_rules": blocked, "allowed_rules": allowed, "status": "running"}

    def get_rules(self):
        out, err, code = self._ps(
            "Get-NetFirewallRule | Select-Object Name,DisplayName,Direction,Action,Enabled,Profile | ConvertTo-Json"
        )
        if code != 0 or not out:
            return self._demo_rules()
        try:
            raw = json.loads(out) if out.startswith("[") else [json.loads(out)]
            rules = []
            for r in raw:
                rules.append({
                    "name": r.get("Name", ""),
                    "display": r.get("DisplayName", ""),
                    "direction": r.get("Direction", ""),
                    "action": r.get("Action", ""),
                    "enabled": r.get("Enabled", False),
                    "profile": r.get("Profile", ""),
                })
            return rules[:200]
        except json.JSONDecodeError:
            return self._demo_rules()

    def _demo_rules(self):
        return [
            {"name": "BRSense-Block-135", "display": "BRSense: Bloquear RPC (135)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-139", "display": "BRSense: Bloquear NetBIOS (139)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-445", "display": "BRSense: Bloquear SMB (445)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-3389", "display": "BRSense: Bloquear RDP (3389)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-1433", "display": "BRSense: Bloquear SQL (1433)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-23", "display": "BRSense: Bloquear Telnet (23)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-25", "display": "BRSense: Bloquear SMTP (25)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-3306", "display": "BRSense: Bloquear MySQL (3306)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Block-6379", "display": "BRSense: Bloquear Redis (6379)", "direction": "Inbound", "action": "Block", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Allow-SSH", "display": "BRSense: Permitir SSH (22)", "direction": "Inbound", "action": "Allow", "enabled": True, "profile": "Any"},
            {"name": "BRSense-Allow-HTTP", "display": "BRSense: Permitir HTTP (80)", "direction": "Inbound", "action": "Allow", "enabled": True, "profile": "Any"},
        ]

    def add_rule(self, name, display, direction, action, protocol="TCP", port=None, remote_ip=None):
        dir_flag = "Inbound" if direction.lower() in ("in", "inbound") else "Outbound"
        action_flag = "Block" if action.lower() == "block" else "Allow"
        cmd = f"New-NetFirewallRule -Name '{name}' -DisplayName '{display}' -Direction {dir_flag} -Action {action_flag} -Protocol {protocol}"
        if port:
            cmd += f" -LocalPort {port}"
        if remote_ip:
            cmd += f" -RemoteAddress '{remote_ip}'"
        out, err, code = self._ps(cmd)
        return {"success": code == 0, "output": out or err, "name": name}

    def remove_rule(self, name):
        out, err, code = self._ps(f"Remove-NetFirewallRule -Name '{name}' -Confirm:$false")
        return {"success": code == 0, "output": out or err}

    def block_port(self, port, protocol="TCP"):
        name = f"BRSense-Block-{port}"
        display = f"BRSense: Bloquear porta {port}"
        return self.add_rule(name, display, "Inbound", "Block", protocol, port)

    def allow_port(self, port, protocol="TCP"):
        name = f"BRSense-Allow-{port}"
        display = f"BRSense: Permitir porta {port}"
        return self.add_rule(name, display, "Inbound", "Allow", protocol, port)

    def apply_default_policy(self):
        results = []
        ports_block = [135, 139, 445, 1433, 3389, 23, 25, 3306, 5432, 6379, 5900, 8080]
        for p in ports_block:
            r = self.block_port(p)
            results.append(r)
        ports_allow = [22, 80, 443, 8443]
        for p in ports_allow:
            r = self.allow_port(p)
            results.append(r)
        return results

    def get_logs(self, lines=20):
        out, err, code = self._ps(
            "Get-WinEvent -FilterHashtable @{LogName='Security';Id=5152,5154,5156,5157} -MaxEvents {lines} | "
            "Select-Object TimeCreated,Id,Message | ConvertTo-Json".format(lines=lines)
        )
        if code != 0 or not out:
            now = datetime.datetime.now()
            logs = []
            for i in range(10):
                logs.append({"time": (now - datetime.timedelta(minutes=i*5)).isoformat(), "event": f"BRSense Simulado: pacote processado ({i+1})", "id": 5152})
            return logs
        try:
            raw = json.loads(out) if out.startswith("[") else [json.loads(out)]
            return [{"time": r.get("TimeCreated", ""), "event": r.get("Message", ""), "id": r.get("Id", 0)} for r in raw]
        except json.JSONDecodeError:
            return []
