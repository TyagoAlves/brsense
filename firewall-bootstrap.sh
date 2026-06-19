#!/bin/sh
#===============================================================================
# Firewall Corporativo FreeBSD - Bootstrap Script (Plug & Play)
# Uso: sudo sh firewall-bootstrap.sh [WAN_IF] [LAN_IF] [LAN_NET]
# Exemplo: sudo sh firewall-bootstrap.sh em0 em1 192.168.1.0/24
# Defaults: ena0 (WAN), ena1 (LAN), 192.168.1.0/24
#===============================================================================

WAN_IF="${1:-ena0}"
LAN_IF="${2:-ena1}"
LAN_NET="${3:-192.168.1.0/24}"

set -e

echo "=========================================="
echo " Firewall Corporativo FreeBSD - Bootstrap"
echo "=========================================="
echo "WAN: $WAN_IF  LAN: $LAN_IF  Rede Interna: $LAN_NET"
echo ""

# Verifica root
if [ "$(id -u)" != "0" ]; then
  echo "Execute como root: sudo sh $0"
  exit 1
fi

# 1. Instalar pacotes
echo "[01/10] Instalando pacotes..."
export ASSUME_ALWAYS_YES=YES
pkg install -y git py311-awscli bash curl 2>/dev/null

# 2. Git repo
echo "[02/10] Clonando repositorio..."
cd /root
rm -rf firewall-corp
git clone https://github.com/seu-usuario/firewall-corp.git /root/firewall-corp 2>/dev/null || {
  echo "Git clone falhou, usando configuracao local"
  mkdir -p /root/firewall-corp
  cd /root/firewall-corp
  git init
}

# 3. Kernel modules
echo "[03/10] Carregando modulos PF..."
kldload pf 2>/dev/null || true
kldload pflog 2>/dev/null || true
grep -q 'pf_load="YES"' /boot/loader.conf 2>/dev/null || \
  echo 'pf_load="YES"' >> /boot/loader.conf

# 4. PF config
echo "[04/10] Gerando /etc/pf.conf..."

cat > /etc/pf.conf << EOF
#===============================================================================
# Firewall Corporativo FreeBSD - Gerado por bootstrap.sh
#===============================================================================

# Interfaces
WAN = "$WAN_IF"
LAN = "$LAN_IF"
LAN_NET = "$LAN_NET"

# Tabelas dinamicas
table <bloqueados> persist
table <liberados> persist

# Config globais
set block-policy drop
set loginterface \$WAN
set skip on lo0
set require-order yes
set optimization normal

# Limpeza de regras anteriores
flush

# NAT - Mascaramento da LAN para WAN
nat on \$WAN from \$LAN_NET to any -> (\$WAN)

# Roteamento - direcionar trafego LAN para roteadores corporativos
# Descomente e ajuste os IPs dos roteadores conforme necessario:
# pass in on \$LAN from \$LAN_NET to 10.0.0.0/8 route-to \$LAN
# pass in on \$LAN from \$LAN_NET to 172.16.0.0/12 route-to \$LAN

# RDR - Redirecionamento de portas (ex: HTTP para servidor interno)
# rdr on \$WAN proto tcp to port 80 -> 192.168.1.100 port 80
# rdr on \$WAN proto tcp to port 443 -> 192.168.1.100 port 443

# REGRAS DE FILTRO ============================================================

# Loopback - tudo permitido
pass quick on lo0 all

# LAN - confiavel, tudo liberado
pass quick on \$LAN from \$LAN_NET to any keep state

# WAN - BLOQUEIO TOTAL POR PADRAO
block log all

# Saida - liberacao seletiva
pass out on \$WAN proto tcp to port { 22, 80, 443, 53, 587, 993, 8443 } modulate state
pass out on \$WAN proto udp to port { 53, 123, 443 } keep state
pass out on \$WAN proto { icmp, tcp } to port 1194 keep state  # VPN OpenVPN
pass out on \$WAN inet proto icmp icmp-type { echoreq, unreach, timex } keep state

# Entrada - apenas servicos explicitos
pass in on \$WAN proto tcp to port 22 keep state         # SSH
pass in on \$WAN proto tcp to port 1194 keep state       # OpenVPN

# Estado - manutencao de conexoes estabelecidas
pass in on \$WAN proto tcp from any to any flags S/SA modulate state
pass in on \$WAN proto { udp, icmp } from any to any keep state

# Bloqueios especificos
block in log quick on \$WAN proto tcp from any to any port { 135, 139, 445, 1433, 3389 }
block in log quick on \$WAN proto udp from any to any port { 135, 139, 445, 1433, 3389 }
block quick from <bloqueados> to any
block quick from any to <bloqueados>
EOF

# 5. Habilitar PF
echo "[05/10] Ativando PF..."
sysrc pf_enable=YES
sysrc pflog_enable=YES
pfctl -f /etc/pf.conf
pfctl -e
echo "Regras carregadas:"
pfctl -sr 2>/dev/null | head -5

# 6. AWS CLI e S3
echo "[06/10] Configurando S3..."
BUCKET="firewall-logs-$(hostname -s)-$(date +%s)"
aws s3 mb "s3://$BUCKET" --region us-east-2 2>/dev/null || BUCKET="firewall-logs-$(date +%s)"
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"ExpireLogs","Filter":{"Prefix":""},"Status":"Enabled","Expiration":{"Days":90}}]}' \
  --region us-east-2 2>/dev/null

# 7. Script de exportacao de logs
echo "[07/10] Criando script de exportacao de logs..."
cat > /usr/local/bin/export-pf-logs.sh << 'SCRIPT'
#!/bin/sh
BUCKET=$(aws s3 ls 2>/dev/null | grep firewall-logs | head -1 | awk '{print $3}')
[ -z "$BUCKET" ] && exit 0
DATE=$(date +%Y%m%d%H%M)
HOST=$(hostname)
tcpdump -ne -c 2000 -i pflog0 2>/dev/null | \
  gzip | \
  aws s3 cp - "s3://$BUCKET/pflogs/pf-$HOST-$DATE.log.gz" 2>/dev/null
SCRIPT
chmod +x /usr/local/bin/export-pf-logs.sh
grep -q 'export-pf-logs' /etc/crontab 2>/dev/null || \
  echo "*/5 * * * * root /usr/local/bin/export-pf-logs.sh" >> /etc/crontab

# 8. Script de setup completo (regeneravel)
echo "[08/10] Salvando configuracao para auto-restore..."
cat > /root/firewall-corp/apply-config.sh << 'APPLY'
#!/bin/sh
echo "Aplicando configuracao do firewall..."
pfctl -f /etc/pf.conf
pfctl -e
pfctl -sr
APPLY
chmod +x /root/firewall-corp/apply-config.sh

# 9. Testes
echo "[09/10] Executando verificacao..."
echo "  - PF ativo: $(pfctl -si 2>/dev/null | head -1)"
echo "  - Interfaces: $(ifconfig -l)"
echo "  - Tabela NAT:"
pfctl -sn 2>/dev/null | head -5

# 10. Git commit
echo "[10/10] Commitando configuracao no Git..."
cd /root/firewall-corp
cp /etc/pf.conf .
cp /usr/local/bin/export-pf-logs.sh .
git add -A 2>/dev/null
git commit -m "Firewall configurado - $(date)" 2>/dev/null || true
git tag -f "v$(date +%Y%m%d%H%M)" 2>/dev/null || true

echo ""
echo "=========================================="
echo " Firewall pronto!"
echo "=========================================="
echo "WAN: $WAN_IF  ->  Internet"
echo "LAN: $LAN_IF  ->  $LAN_NET (roteadores corporativos)"
echo "S3:  s3://$BUCKET"
echo "SSH: Liberado na porta 22"
echo ""
echo "Comandos uteis:"
echo "  Ver regras:        pfctl -sr"
echo "  Ver NAT:           pfctl -sn"
echo "  Ver estado:        pfctl -si"
echo "  Ver logs:          tcpdump -i pflog0"
echo "  Testar bloqueio:   nc -zv <IP_EXTERNO> 80"
echo "  Reaplicar config:  sh /root/firewall-corp/apply-config.sh"
echo "=========================================="
