import sys, os, threading, time, json, webbrowser

API_PORT = 58080
API_HOST = "127.0.0.1"

def main():
    from brsense_api import run_api
    from brsense_core import BRSenseFirewall

    fw = BRSenseFirewall()
    api_thread = threading.Thread(target=run_api, args=(API_HOST, API_PORT), daemon=True)
    api_thread.start()

    time.sleep(1.5)

    try:
        fw.apply_default_policy()
    except:
        pass

    url = f"http://{API_HOST}:{API_PORT}/"
    print(f"""
╔══════════════════════════════════════════════════════╗
║              BRSense Firewall v1.0.0                 ║
║        Firewall Corporativo para Windows             ║
╠══════════════════════════════════════════════════════╣
║  API:    {url}
║  Status: Rodando
╠══════════════════════════════════════════════════════╣
║  Abrindo navegador no painel de controle...          ║
╚══════════════════════════════════════════════════════╝
    """)

    try:
        webbrowser.open(url)
    except:
        pass

    try:
        while True:
            time.sleep(10)
    except KeyboardInterrupt:
        print("\n[BRSense] Encerrando...")

if __name__ == "__main__":
    main()
