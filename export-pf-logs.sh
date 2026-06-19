#!/bin/sh
BUCKET="firewall-logs-160940204014-1781898493"
DATE=$(date +%Y%m%d%H%M)
HOST=$(hostname -s)
tcpdump -ne -c 5000 -i pflog0 2>/dev/null | \
  gzip | \
  /usr/local/bin/aws s3 cp - "s3://$BUCKET/pflogs/pf-$HOST-$DATE.log.gz" 2>/dev/null
echo "[$(date)] Exportado pf-$HOST-$DATE.log.gz" >> /var/log/pf-s3-sync.log
