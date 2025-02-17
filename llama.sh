#!/bin/bash

# 建立監控記錄檔
LOG_FILE="ollama_perf_$(date +%F_%H-%M-%S).log"
echo "開始監控，記錄檔: $LOG_FILE"

# 啟動背景監控
{
  echo "時間戳,CPU使用(%),記憶體使用(MB),GPU使用(%),GPU記憶體(MB),磁碟IO(kB/s),網路流量(kB)" > "$LOG_FILE"
  while true; do
    TIMESTAMP=$(date +%T.%3N)
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    MEM=$(free -m | awk '/Mem/{print $3}')
    GPU=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits | awk -F', ' '{printf "%d,%d", $1, $2}')
    IO=$(cat /proc/diskstats | awk '/sda / {print ($10+$11)*512/1024}')  # 轉換為 kB/s
    NET=$(awk 'BEGIN {rx=0; tx=0} {rx+=$2; tx+=$10} END {printf "%.1f", (rx+tx)/1024}' /proc/net/dev)
    echo "$TIMESTAMP,$CPU,$MEM,$GPU,$IO,$NET" >> "$LOG_FILE"
    sleep 0.2
  done
} &

MONITOR_PID=$!

# 執行 Ollama 並計時
echo "=== 開始 Ollama 請求 ==="
START=$(date +%s.%N)
ollama run mistral:7b "請用繁體中文回答問題"
END=$(date +%s.%N)

# 停止監控
kill $MONITOR_PID

# 計算耗時
ELAPSED=$(echo "$END - $START" | bc -l | awk '{printf "%.3f", $0}')
echo "=== 請求完成 ==="
echo "總耗時: ${ELAPSED} 秒"
echo "完整記錄已儲存到 $LOG_FILE"

# 生成統計摘要
awk -F',' -v start="$START" -v end="$END" '
NR==1 {header=$0}
NR>1 && $1 >= start && $1 <= end {
  count++
  cpu_sum += $2
  mem_sum += $3
  gpu_use_sum += $4
  gpu_mem_sum += $5
  io_sum += $6
  net_sum += $7
}
END {
  print "效能摘要："
  print "平均 CPU 使用率: " cpu_sum/count "%"
  print "平均記憶體使用: " mem_sum/count " MB"
  print "平均 GPU 使用率: " gpu_use_sum/count "%"
  print "平均 GPU 記憶體: " gpu_mem_sum/count " MB"
  print "平均磁碟 IO: " io_sum/count " kB/s"
  print "平均網路流量: " net_sum/count " kB/s"
}' "$LOG_FILE" > "${LOG_FILE}.summary"

cat "${LOG_FILE}.summary"