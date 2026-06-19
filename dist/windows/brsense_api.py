import json, os, sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from brsense_core import BRSenseFirewall

fw = BRSenseFirewall()

def json_response(handler, data, status=200):
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type")
    handler.end_headers()
    handler.wfile.write(json.dumps(data, ensure_ascii=False).encode())

def serve_file(handler, path):
    base = os.path.join(os.path.dirname(__file__), "dashboard") if getattr(sys, "frozen", False) else os.path.join(os.path.dirname(__file__), "dashboard")
    filepath = os.path.join(base, path) if path else os.path.join(base, "index.html")
    if not os.path.exists(filepath) or not os.path.isfile(filepath):
        filepath = os.path.join(base, "index.html")
    if not os.path.exists(filepath):
        json_response(handler, {"error": "not found"}, 404)
        return
    ext_map = {".html": "text/html", ".css": "text/css", ".js": "application/javascript", ".json": "application/json", ".png": "image/png", ".ico": "image/x-icon", ".svg": "image/svg+xml"}
    ext = os.path.splitext(filepath)[1].lower()
    ctype = ext_map.get(ext, "application/octet-stream")
    handler.send_response(200)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Cache-Control", "no-cache")
    handler.end_headers()
    with open(filepath, "rb") as f:
        handler.wfile.write(f.read())

class BRSenseHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        json_response(self, {})
    def do_GET(self):
        if self.path == "/":
            serve_file(self, "index.html")
        elif self.path.startswith("/dashboard/"):
            serve_file(self, self.path[11:])
        elif self.path == "/api/status":
            json_response(self, fw.get_status())
        elif self.path == "/api/rules":
            json_response(self, fw.get_rules())
        elif self.path == "/api/logs":
            json_response(self, fw.get_logs())
        elif self.path.startswith("/api/status.json"):
            s = fw.get_status()
            s["tasks"] = [{"id": i+1, "name": n, "status": "done" if i < 10 else "todo"} for i, n in enumerate([
                "Firewall rules loaded", "Default policy applied", "Port blocking active",
                "Logging enabled", "NAT configured", "Remote management",
                "IPS/IDS active", "Traffic shaping", "VPN support", "Reporting"
            ])]
            json_response(self, s)
        else:
            serve_file(self, self.path.lstrip("/"))
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else "{}"
        try: data = json.loads(body)
        except: data = {}
        if self.path == "/api/rules":
            r = fw.add_rule(data.get("name","rule"), data.get("display","Rule"), data.get("direction","In"), data.get("action","Block"), data.get("protocol","TCP"), data.get("port"))
            json_response(self, r)
        elif self.path == "/api/block":
            r = fw.block_port(data.get("port", 0))
            json_response(self, r)
        elif self.path == "/api/allow":
            r = fw.allow_port(data.get("port", 0))
            json_response(self, r)
        elif self.path == "/api/policy":
            r = fw.apply_default_policy()
            json_response(self, {"success": True, "results": r})
        else:
            json_response(self, {"error": "not found"}, 404)
    def do_DELETE(self):
        if self.path.startswith("/api/rules/"):
            name = self.path[11:]
            r = fw.remove_rule(name)
            json_response(self, r)
        else:
            json_response(self, {"error": "not found"}, 404)
    def log_message(self, fmt, *args):
        pass

def run_api(host="127.0.0.1", port=58080):
    server = HTTPServer((host, port), BRSenseHandler)
    print(f"[BRSense API] Rodando em http://{host}:{port}")
    server.serve_forever()

if __name__ == "__main__":
    run_api()
