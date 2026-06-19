#!/usr/bin/env bash
# Agente_20: Observador SRE / Site Reliability Engineer
# Monitoramento contínuo de infraestrutura FreeBSD + OpenCode

SRE_DIR="/home/cloudshell-user"
DASHBOARD="$SRE_DIR/sre-dashboard.txt"
LOG_DIR="$SRE_DIR/sre-logs"
LOG_FILE="$LOG_DIR/audit-$(date +%Y%m%d).log"
INTERVALO=15
SRE_BRANCH="sre-monitoring"
REPO_DIR="$SRE_DIR/repo-firewall-freebsd"

mkdir -p "$LOG_DIR"

check_ec2_instances() {
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress,InstanceType]' \
        --output text 2>/dev/null || echo "SEM_INSTANCIAS"
}

check_local_resources() {
    local mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    local mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
    local mem_avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    local cpu_load=$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null)
    local disk_used=$(df -h /home/cloudshell-user 2>/dev/null | awk 'NR==2{print $3}')
    local disk_avail=$(df -h /home/cloudshell-user 2>/dev/null | awk 'NR==2{print $4}')
    local disk_pct=$(df -h /home/cloudshell-user 2>/dev/null | awk 'NR==2{print $5}')
    echo "$mem_total|$mem_used|$mem_avail|$cpu_load|$disk_used|$disk_avail|$disk_pct"
}

check_opencode() {
    local pids=$(pgrep -f "opencode" 2>/dev/null | head -3 | tr '\n' ' ')
    local opencode_pid=""
    local rss_total=0
    for pid in $pids; do
        local name=$(ps -o comm= -p "$pid" 2>/dev/null || echo "")
        local ppid=$(ps -o ppid= -p "$pid" 2>/dev/null || echo "0")
        ppid=$((ppid))
        if [ "$ppid" -eq 1 ] || [ "$ppid" -eq 0 ]; then
            continue
        fi
        opencode_pid="$pid"
        local rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f", $1/1024}' || echo "0")
        rss_total=$((rss_total + rss))
    done
    if [ -n "$opencode_pid" ]; then
        echo "RUNNING|$opencode_pid|${rss_total}MB"
    else
        echo "STOPPED|0|0"
    fi
}

build_dashboard() {
    local counter=$1
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    local instance_data=$(check_ec2_instances)
    local local_res=$(check_local_resources)
    local opencode_data=$(check_opencode)

    local mem_total=$(echo "$local_res" | cut -d'|' -f1)
    local mem_used=$(echo "$local_res" | cut -d'|' -f2)
    local mem_avail=$(echo "$local_res" | cut -d'|' -f3)
    local cpu_load=$(echo "$local_res" | cut -d'|' -f4)
    local disk_used=$(echo "$local_res" | cut -d'|' -f5)
    local disk_avail=$(echo "$local_res" | cut -d'|' -f6)
    local disk_pct=$(echo "$local_res" | cut -d'|' -f7)

    local op_status=$(echo "$opencode_data" | cut -d'|' -f1)
    local op_pid=$(echo "$opencode_data" | cut -d'|' -f2)
    local op_rss=$(echo "$opencode_data" | cut -d'|' -f3)

    local alert="NORMAL"
    if [ "$op_status" = "STOPPED" ]; then
        alert="CRITICO - OpenCode OFFLINE"
    fi
    if [ -n "$op_rss" ] && [ "${op_rss%MB}" -gt 512 ] 2>/dev/null; then
        alert="ATENCAO - Memoria alta (${op_rss})"
    fi
    if [ -n "$mem_avail" ] && [ "$mem_avail" -lt 200 ] 2>/dev/null; then
        alert="ATENCAO - RAM disponivel baixa (${mem_avail}MB)"
    fi

    cat > "$DASHBOARD" <<- EOFF
╔══════════════════════════════════════════════════════╗
║     AGENTE_20 - OBSERVADOR SRE DASHBOARD             ║
║     Site Reliability Engineer - Modo Autônomo         ║
╠══════════════════════════════════════════════════════╣
║  Timestamp : $ts
║  Loop      : #$counter (intervalo: ${INTERVALO}s)
║  Alerta    : [$alert]
╠══════════════════════════════════════════════════════╣
║  RECURSOS LOCAIS (CloudShell us-east-2)
║  RAM  : ${mem_used}MB / ${mem_total}MB (livre: ${mem_avail}MB)
║  CPU  : load $cpu_load
║  Disco: ${disk_used} / ${disk_avail} (${disk_pct})
╠══════════════════════════════════════════════════════╣
║  PROCESSO OPENCODE
║  Status: $op_status  |  PID: $op_pid  |  RSS: $op_rss
EOFF

    if [ "$op_status" = "STOPPED" ]; then
        echo "║  >>> ATENCAO: OpenCode nao esta em execucao! <<<" >> "$DASHBOARD"
    fi

    printf "\n╠══════════════════════════════════════════════════════╣\n║  INSTANCIAS EC2 (FreeBSD)\n" >> "$DASHBOARD"

    local count=0
    while IFS=$'\t' read -r id nome state ip tipo; do
        [ -z "$id" ] || [ "$id" = "None" ] && continue
        local icone=""
        case "$state" in
            running) icone="▶ ATIVO" ;;
            stopped) icone="■ PARADO" ;;
            terminated) icone="✗ TERMIN" ;;
            *) icone="? $state" ;;
        esac
        if [ -n "$nome" ] && [ "$nome" != "None" ]; then
            printf "║  %s | %-30s %s\n" "$icone" "$id" "$nome" >> "$DASHBOARD"
        else
            printf "║  %s | %s\n" "$icone" "$id" >> "$DASHBOARD"
        fi
        count=$((count + 1))
    done <<< "$instance_data"

    if [ "$count" -eq 0 ]; then
        echo "║  (nenhuma instancia encontrada)" >> "$DASHBOARD"
    fi

    printf "╠══════════════════════════════════════════════════════╣\n║  GIT: branch ${SRE_BRANCH}\n" >> "$DASHBOARD"

    if [ -d "$REPO_DIR/.git" ]; then
        cd "$REPO_DIR"
        local git_log=$(git log --oneline -1 2>/dev/null || echo "sem commits")
        echo "║  Ultimo commit: $git_log" >> "$DASHBOARD"
    else
        echo "║  Repositorio nao inicializado" >> "$DASHBOARD"
    fi

    printf "╠══════════════════════════════════════════════════════╣\n║  ULTIMAS ACOES CORRETIVAS\n" >> "$DASHBOARD"
    if [ -f "$LOG_FILE" ]; then
        grep "ACO" "$LOG_FILE" | tail -3 | while IFS= read -r line; do
            echo "║  > $line" >> "$DASHBOARD"
        done
    else
        echo "║  Nenhuma acao registrada" >> "$DASHBOARD"
    fi

    cat >> "$DASHBOARD" <<- EOFF
╚══════════════════════════════════════════════════════╝
  Para acompanhar: watch -n 5 cat $DASHBOARD
  Log detalhado:   tail -f $LOG_FILE
  Monitore via:    ./ver-sre.sh
EOFF

    echo "[$ts] Loop #$counter | OpenCode=$op_status RAM=${mem_used}MB Alerta=[$alert]" >> "$LOG_FILE"
}

corrective_action() {
    local alert="$1"
    echo "=== ACO CORRETIVA AUTONOMA ===" >> "$LOG_FILE"
    echo "Alerta: $alert" >> "$LOG_FILE"
    echo "Data: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"

    case "$alert" in
        *"CRITICO"*|*"OpenCode OFFLINE"*)
            echo "[ACO] OpenCode offline. Limpando processos travados..." >> "$LOG_FILE"
            pkill -9 -f "opencode" 2>/dev/null || true
            sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            echo "[ACO] Memoria liberada. Pronto para restart manual." >> "$LOG_FILE"
            ;;
        *"ATENCAO"*)
            echo "[ACO] Alerta de recurso. Monitorando..." >> "$LOG_FILE"
            ;;
    esac
    echo "=== FIM ACO CORRETIVA ===" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     AGENTE_20 - OBSERVADOR SRE                          ║"
echo "║  Site Reliability Engineer - Modo Autonomo               ║"
echo "║  Inicializando monitoramento continuo...                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Dashboard: $DASHBOARD"
echo "Log:       $LOG_FILE"
echo "PID:       $$"
echo ""

counter=0
while true; do
    counter=$((counter + 1))
    build_dashboard "$counter"

    if grep -q "ALERTA" "$DASHBOARD" 2>/dev/null; then
        local alert_line=$(grep "Alerta" "$DASHBOARD" | head -1)
        corrective_action "$alert_line" &
    fi

    if [ $((counter % 4)) -eq 0 ] && [ -d "$REPO_DIR/.git" ]; then
        cd "$REPO_DIR"
        cp "$DASHBOARD" "$REPO_DIR/sre-dashboard.txt" 2>/dev/null || true
        cp "$LOG_FILE" "$REPO_DIR/sre-latest.log" 2>/dev/null || true
        git checkout "$SRE_BRANCH" 2>/dev/null || git checkout -b "$SRE_BRANCH" 2>/dev/null
        git add -A 2>/dev/null || true
        git commit -m "[SRE] Auditoria loop #$counter $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
    fi

    sleep "$INTERVALO"
done
