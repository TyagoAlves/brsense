#!/bin/sh
echo "=== BRSense Firewall - Restore Completo ==="
echo "Restaurando PF..."
pfctl -f /etc/pf.conf 2>/dev/null
pfctl -e 2>/dev/null
echo "Verificando S3..."
aws s3 ls s3://firewall-logs-160940204014-1781898493/ 2>/dev/null || \
  echo "Bucket S3 indisponivel"
echo "Regras ativas:"
pfctl -sr | head -5
echo "NAT:"
pfctl -sn | head -3
