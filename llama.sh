#!/bin/bash
set -e

# 容器友好設定
INSTALL_DIR="/usr/local/bin"
MODEL_DIR="/ollama/models"
LOG_DIR="/ollama/logs"

# 建立必要目錄
mkdir -p "$MODEL_DIR" "$LOG_DIR"

# 安裝必要套件
echo "安裝系統套件..."
apt-get update >/dev/null && apt-get install -y --no-install-recommends \
    curl ca-certificates pciutils \
    && rm -rf /var/lib/apt/lists/*

# 下載並安裝
echo "下載 Ollama..."
OLLAMA_URL="https://github.com/ollama/ollama/releases/download/v0.1.33/ollama-linux-amd64"
curl -#L "$OLLAMA_URL" -o "$INSTALL_DIR/ollama"
chmod +x "$INSTALL_DIR/ollama"

# 啟動服務 (容器專用方式)
echo "啟動服務..."
nohup "$INSTALL_DIR/ollama" serve > "$LOG_DIR/service.log" 2>&1 &
OLLAMA_PID=$!

# 等待服務就緒
timeout=30
while ! curl -s http://localhost:11434 >/dev/null; do
  sleep 1
  ((timeout--))
  if [ $timeout -eq 0 ]; then
    echo "啟動超時！檢查日誌：$LOG_DIR/service.log"
    exit 1
  fi
done

# 下載模型
echo "下載基礎模型..."
"$INSTALL_DIR/ollama" pull mistral:7b

# 效能監控
PERF_LOG="$LOG_DIR/perf-$(date +%s).csv"
echo "時間戳,CPU使用(%),記憶體使用(MB),GPU使用(%),GPU記憶體(MB),磁碟IO(kB/s),網路流量(kB)" > "$PERF_LOG"

# 背景監控
{
  while true; do
    TIMESTAMP=$(date +%T.%3N)
    CPU=$(top -bn1 | awk '/Cpu\(s\)/ {print $2 + $4}')
    MEM=$(free -m | awk '/Mem/ {print $3}')
    GPU=$(timeout 2 nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null | awk -F', ' '{printf "%d,%d", $1, $2}' || echo "0,0")
    IO=$(awk '/sda / {print ($10+$11)*512/1024}' /proc/diskstats)
    NET=$(awk 'BEGIN {rx=0; tx=0} {rx+=$2; tx+=$10} END {printf "%.1f", (rx+tx)/1024}' /proc/net/dev)
    echo "$TIMESTAMP,$CPU,$MEM,$GPU,$IO,$NET" >> "$PERF_LOG"
    sleep 0.2
  done
} &

# 執行測試
echo "=== 開始效能測試 ==="
START=$(date +%s.%N)
"$INSTALL_DIR/ollama" run mistral:7b "請用繁體中文回答：请问英文 I have not received the package 
yet. 的意思"
END=$(date +%s.%N)

# 生成報告
REPORT_FILE="$LOG_DIR/report.txt"
ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN {printf "%.3f", e - s}')
awk -F',' -v elapsed="$ELAPSED" '
BEGIN {
  print "Ollama 效能測試報告"
  print "===================="
  print "測試時間: $(date)"
  print "總耗時: " elapsed " 秒"
  print "\n資源使用統計:"
}
NR>1 {
  count++
  cpu+=$2
  mem+=$3
  gpu_use+=$4
  gpu_mem+=$5
  io+=$6
  net+=$7
}
END {
  printf "CPU 平均使用率: %.1f%%\n", cpu/count
  printf "記憶體平均使用: %.1f MB\n", mem/count
  printf "GPU 平均使用率: %.1f%%\n", gpu_use/count
  printf "GPU 記憶體平均: %.1f MB\n", gpu_mem/count
  printf "磁碟 IO 平均: %.1f kB/s\n", io/count
  printf "網路流量平均: %.1f kB/s\n", net/count
}' "$PERF_LOG" > "$REPORT_FILE"

echo "測試完成！輸出文件："
echo "- 服務日誌: $LOG_DIR/service.log"
echo "- 效能數據: $PERF_LOG"
echo "- 分析報告: $REPORT_FILE"

# 清理背景進程
kill %1 %2