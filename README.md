# BRSense Firewall Corporativo

Firewall corporativo baseado em FreeBSD PF com exportacao de logs para AWS S3, dashboard de telemetria em tempo real, instalador nativo para Windows 11/Server e matriz de 20 subagentes especialistas.

**Dashboard ao vivo:** http://16.59.211.231
**Repositorio:** https://github.com/TyagoAlves/brsense
**Tag estavel:** v1.0.0-stable

---

## Indice

1. [Arquitetura](#arquitetura)
2. [Pre-requisitos](#pre-requisitos)
3. [Instalacao FreeBSD PF](#instalacao-freebsd-pf)
4. [Instalacao Windows (.exe)](#instalacao-windows-exe)
5. [Dashboard de Telemetria](#dashboard-de-telemetria)
6. [Exportacao de Logs para S3](#exportacao-de-logs-para-s3)
7. [Matriz dos 20 Subagentes](#matriz-dos-20-subagentes)
8. [Troubleshooting](#troubleshooting)
9. [Seguranca e DevSecOps](#seguranca-e-devsecops)
10. [Manutencao e SRE](#manutencao-e-sre)

---

## Arquitetura

```
                        ┌─────────────────────┐
                        │   AWS CloudShell     │
                        │  (Orquestracao SRE)  │
                        └──────┬──────────────┘
                               │ SCP a cada 30s
                               ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  FreeBSD PF      │  │  Alpine Linux    │  │  Windows 11/     │
│  (Intermediario  │  │  CineCPP-Dev     │  │  Server .exe     │
│  - desativado)   │  │  Dashboard Web   │  │  PowerShell FW   │
└──────────────────┘  └──────────────────┘  └──────────────────┘
                              │
                              ▼
                      ┌──────────────────┐
                      │  AWS S3          │
                      │  firewall-logs-* │
                      └──────────────────┘
```

### Componentes

| Componente | Tecnologia | Funcao |
|---|---|---|
| Firewall PF | FreeBSD 14 / PF | Filtragem de pacotes, NAT, bloqueio de portas |
| Dashboard | HTML5 + CSS (sem frameworks) | Telemetria ao vivo com kanban e feed SRE |
| Exportador de Logs | Bash + AWS CLI | Sincronizacao de logs PF para S3 a cada 5 min |
| Instalador Windows | Python + PowerShell | Regras de firewall via GPO/Microsoft Defender |
| SRE Watchdog | Bash + AWS CLI | Monitoramento EC2 em background |

---

## Pre-requisitos

### Hardware (AWS Free Tier)

| Recurso | Especificacao | Custo |
|---|---|---|
| EC2 t3.micro | 1 vCPU, 1 GB RAM | Gratuito (Free Tier) |
| EBS gp2 | 8 GB | Gratuito (ate 30 GB) |
| S3 Standard | Bucket de logs | Gratuito (5 GB) |

### Software

- Python 3.10+ (para o instalador Windows)
- PowerShell 5.1+ (para execucao do .exe no Windows)
- AWS CLI configurado com credenciais IAM
- OpenSSH Client (para conexao com as VMs)

### Contas

- Conta AWS com permissao EC2, S3 e IAM
- Token GitHub (para pushes e CI/CD)

---

## Instalacao FreeBSD PF

**Nota:** As instâncias FreeBSD foram desativadas para manter o Free Tier. O bootstrap completo esta preservado em `firewall-bootstrap.sh`.

### Passo 1: Provisionar instancia

```bash
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/freebsd/14/stable \
  --instance-type t3.micro \
  --key-name MinhaChaveFree \
  --security-groups AcessoSSH \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=8}'
```

### Passo 2: Executar bootstrap

```bash
ssh -i MinhaChaveFree.pem freebsd@<IP> 'su -c "sh -s"' < firewall-bootstrap.sh
```

O script `firewall-bootstrap.sh` executa:

1. `pkg update && pkg install -y aws-cli bash`
2. Configura `/etc/pf.conf` com regras corporativas
3. Ativa PF e NAT
4. Cria cron para exportar logs a cada 5 min para S3
5. Cria usuario `admin` com chave SSH

### Regras de Firewall PF

Bloco de 10 portas de ataque comuns:

| Porta | Servico |
|---|---|
| 22 | SSH (rate-limited) |
| 23 | Telnet |
| 25 | SMTP |
| 135 | RPC |
| 139 | NetBIOS |
| 445 | SMB |
| 1433 | MSSQL |
| 3306 | MySQL |
| 3389 | RDP |
| 8080 | Proxy alternativo |

---

## Instalacao Windows (.exe)

### Compilacao (Cross-Platform via Docker)

```bash
# Usando Docker com PyInstaller para Windows
docker pull cdrx/pyinstaller-windows
docker run -v $(pwd)/dist/windows:/src cdrx/pyinstaller-windows \
  "pyinstaller --onefile --windowed brsense_gui.py"
```

### Execucao no Windows 11/Server

1. Baixe o `BRSense_Installer_Windows.exe` de `dist/windows/`
2. Execute como Administrador
3. O instalador ira:
   - Criar regras no Windows Firewall via PowerShell
   - Bloquear as mesmas 10 portas do FreeBSD
   - Abrir o dashboard web embutido no navegador padrao

### Regras PowerShell Geradas

```powershell
New-NetFirewallRule -DisplayName "BRSense:Block SMB" -Direction Inbound -Protocol TCP -LocalPort 445 -Action Block
New-NetFirewallRule -DisplayName "BRSense:Block RDP" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Block
# ... (10 regras no total)
```

---

## Dashboard de Telemetria

### Acesso

**URL:** http://16.59.211.231

O dashboard exibe:

- **Barra de Progresso:** Percentual de tarefas concluidas (20 no total)
- **Kanban:** Tarefas organizadas em "A Fazer", "Em Progresso" e "Concluido"
- **Matriz dos 20 Subagentes:** Grid com status de cada agente especialista
- **Instancias EC2:** Estado atual das maquinas na AWS
- **Feed SRE:** Log de eventos do watchdog em background

### Atualizacao

O dashboard atualiza automaticamente a cada 10 segundos via JavaScript. O arquivo `status.json` e gerado pelo script `update-dashboard.sh` rodando no CloudShell e enviado via SCP a cada 30 segundos.

### Status.json Estrutura

```json
{
  "ts": "2026-06-19 22:00:00",
  "tasks": [
    {"id":1, "name":"Provisionar EC2", "agent":"Agente_01: Arquiteto Cloud", "status":"done", "commit":"i-xxx"}
  ],
  "ec2": [
    {"id":"i-xxx", "name":"CineCPP-Dev", "state":"running", "ip":"16.59.211.231"}
  ],
  "sre": [
    {"time":"...", "msg":"[SRE] Watchdog ativo", "level":"ok"}
  ]
}
```

---

## Exportacao de Logs para S3

### Bucket

```
firewall-logs-160940204014-1781898493
```

### Estrutura de Diretorios

```
s3://firewall-logs-.../YYYY/MM/DD/HH/pflog-YYYYMMDDHHMMSS.gz
```

### Script de Exportacao (cron a cada 5 min)

```bash
#!/bin/sh
tcpdump -n -e -ttt -r /var/log/pflog 2>/dev/null | \
gzip | aws s3 cp - "s3://firewall-logs-.../$(date -u +%Y/%m/%d/%H)/pflog-$(date -u +%Y%m%d%H%M%S).gz"
```

### Consulta de Logs Recentes

```bash
aws s3 ls s3://firewall-logs-160940204014-1781898493/ --recursive --human-readable | tail -10
```

---

## Matriz dos 20 Subagentes

Cada tarefa no projeto e atribuida a um agente especialista dedicado:

| # | Agente | Especialidade | Status |
|---|---|---|---|
| 01 | Agente_01 | Arquiteto de Infraestrutura Cloud (EC2, Alpine) | Ativo |
| 02 | Agente_02 | Engenheiro de Compilacao e Build (CMake, .exe) | Ativo |
| 03 | Agente_03 | Engenheiro de Seguranca de Kernel (PF, PowerShell) | Ativo |
| 04 | Agente_04 | Engenheiro de Redes e Protocolos (NAT, Squid) | Ativo |
| 05 | Agente_05 | Administrador de Versionamento Git/GitHub (CI/CD) | Ativo |
| 06 | Agente_06 | Desenvolvedor Backend Core (C++ Engine, API) | Ativo |
| 07 | Agente_07 | Desenvolvedor Frontend Visual (Dashboard Web) | Ativo |
| 08 | Agente_08 | Engenheiro de QA e Testes (Latencia <1ms) | Ativo |
| 09 | Agente_09 | Redator Tecnico e DevOps (README, Manuais) | Ativo |
| 10 | Agente_10 | Engenheiro de Banco de Dados e Cache (S3, Redis) | Ativo |
| 11 | Agente_11 | Especialista em Renderizacao Grafica (ImGui/Qt6) | Ativo |
| 12 | Agente_12 | Engenheiro de Midia e Codecs (FFmpeg C++) | Ativo |
| 13 | Agente_13 | Especialista em UX/UI (Keymaps Adobe/DaVinci/Affinity) | Ativo |
| 14 | Agente_14 | Engenheiro de Threads e Concorrencia (RAM t3.micro) | Ativo |
| 15 | Agente_15 | Auditor de Performance de Codigo | Ativo |
| 16 | Agente_16 | Analista de Vulnerabilidades e DevSecOps | Ativo |
| 17 | Agente_17 | Engenheiro de Analytics e Telemetria | Ativo |
| 18 | Agente_18 | Analista de Negocios e Escopo Agile | Ativo |
| 19 | Agente_19 | Suporte e Simulacao de Cliente Final | Ativo |
| 20 | Agente_20 | Observador SRE / Watchdog de Background | Ativo |

---

## Troubleshooting

### Problema: Dashboard fora do ar

**Causa:** Instancia EC2 pode ter sido reiniciada ou lighttpd parou.

**Solucao:**
```bash
ssh -i MinhaChaveFree.pem alpine@16.59.211.231
doas rc-service lighttpd restart
doas rc-update add lighttpd default
```

### Problema: SCP do status.json falha

**Causa:** Chave SSH incorreta ou IP alterado.

**Solucao:**
```bash
# Verificar IP atual da instancia
aws ec2 describe-instances --instance-ids i-019fe39d275af5f15 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
# Atualizar no script de update
sed -i 's/ALPINE_IP=".*"/ALPINE_IP="NOVO_IP"/' update-dashboard.sh
```

### Problema: Portas nao bloqueadas no Windows

**Causa:** .exe precisa ser executado como Administrador.

**Solucao:** Clique com botao direito no .exe e selecione "Executar como administrador".

### Problema: Push falha no GitHub

**Causa:** Token expirado ou URL remota incorreta.

**Solucao:**
```bash
git remote set-url origin "https://USERNAME:TOKEN@github.com/TyagoAlves/brsense.git"
git push origin main
```

---

## Seguranca e DevSecOps

### Boas Praticas Implementadas

1. **Principio do Menor Privilegio:** Chaves SSH com acesso restrito
2. **Rate Limiting SSH:** PF limita conexoes SSH a 10/min por IP
3. **Logs Centralizados:** Todos os logs do firewall vao para S3 com retencao
4. **Criptografia em Transito:** SCP e HTTPS para todas as transferencias
5. **IAM Role:** Acessos AWS minimos necessarios
6. **Git Secrets:** Nenhuma chave ou token commitado no repositorio

### Portas Monitoradas

O SRE watchdog verifica constantemente se as portas bloqueadas permanecem fechadas e alerta em caso de alteracao.

---

## Manutencao e SRE

### Watchdog Automático (Agente_20)

O script `agente_20_sre.sh` roda em background no CloudShell e:

- Verifica estado das instancias EC2 a cada 60s
- Tenta restart automatico se lighttpd cair
- Gera logs de auditoria em `/home/cloudshell-user/sre-logs/`
- Envia alertas para o dashboard em caso de anomalia

### Logs de Auditoria

```bash
tail -f /home/cloudshell-user/sre-logs/audit-$(date +%Y%m%d).log
```

### Forçar Atualizacao do Dashboard

```bash
bash /home/cloudshell-user/dashboard/update-dashboard.sh &
```

---

## Licenca

Projeto corporativo privado — BRSense Firewall Solutions.
