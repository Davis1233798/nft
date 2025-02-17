#!/bin/bash
set -eo pipefail

# 配置區
MODEL_NAME="mistral:7b"
TEST_PROMPT="請用繁體中文回答：如何優化生產線效率？"
OUTPUT_DIR="$(pwd)/ollama_test_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$OUTPUT_DIR/report.txt"
DIALOG_FILE="$OUTPUT_DIR/dialogue.log"
PERF_DATA="$OUTPUT_DIR/perf.csv"

# 初始化輸出目錄
mkdir -p "$OUTPUT_DIR"
exec > >(tee -a "$OUTPUT_DIR/script.log") 2>&1

# 獲取硬體規格函式
get_hardware_spec() {
  echo "=== 硬體規格 ==="
  echo "CPU型號: $(lscpu | awk -F': +' '/Model name/ {print $2}' | xargs)"
  echo "CPU核心數: $(nproc)"
  echo "記憶體總量: $(free -h | awk '/Mem/ {print $2}')"
  echo "儲存空間: $(df -h / | awk 'NR==2 {print $2}')"
  
  if command -v nvidia-smi &> /dev/null; then
    echo -e "\nGPU資訊:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | awk -F',' '{
      gsub(/ /, "", $1); 
      printf "%-20s 驅動: %-8s 顯存: %s\n", $1, $2, $3
    }'
  else
    echo -e "\nGPU資訊: 未檢測到NVIDIA GPU"
  fi
}

# 安裝依賴
install_dependencies() {
  echo "安裝必要套件..."
  apt-get update >/dev/null && apt-get install -y --no-install-recommends \
      curl ca-certificates pciutils bc moreutils \
      && rm -rf /var/lib/apt/lists/*
}

# 下載Ollama
download_ollama() {
  echo "下載主程式..."
  OLLAMA_PATH="$OUTPUT_DIR/ollama"
  curl -#L "https://github.com/ollama/ollama/releases/download/v0.1.33/ollama-linux-amd64" -o "$OLLAMA_PATH"
  chmod +x "$OLLAMA_PATH"
}

# 啟動服務
start_service() {
  echo "啟動服務..."
  export OLLAMA_MODELS="$OUTPUT_DIR/models"
  mkdir -p "$OLLAMA_MODELS"
  nohup "$OLLAMA_PATH" serve > "$OUTPUT_DIR/service.log" 2>&1 &
  OLLAMA_PID=$!
  trap "kill -TERM $OLLAMA_PID" EXIT
}

# 效能監控
start_monitoring() {
  echo "時間戳,CPU(%),記憶體(MB),GPU(%),GPU記憶體(MB)" > "$PERF_DATA"
  {
    while sleep 0.2; do
      TS=$(date +%s.%N)
      CPU=$(top -bn1 | awk '/Cpu\(s\)/ {print $2 + $4}')
      MEM=$(free -m | awk '/Mem/ {print $3}')
      GPU_STATS=$(timeout 2 nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null || echo "0,0")
      echo "$TS,$CPU,$MEM,${GPU_STATS//, /,}"
    done >> "$PERF_DATA" &
  } 2>/dev/null
  MONITOR_PID=$!
}

# 主流程
main() {
  # 收集硬體資訊
  get_hardware_spec > "$REPORT_FILE"
  
  # 安裝流程
  install_dependencies
  download_ollama
  start_service
  
  # 等待服務啟動
  echo "等待服務就緒..."
  timeout 30 bash -c 'until curl -s http://localhost:11434 >/dev/null; do sleep 1; done' || {
    echo "啟動超時！檢查日誌：$OUTPUT_DIR/service.log"
    exit 1
  }

  # 下載模型
  echo "下載模型 $MODEL_NAME..."
  "$OLLAMA_PATH" pull "$MODEL_NAME" || {
    echo "模型下載失敗！錯誤日誌："
    tail -n 20 "$OUTPUT_DIR/service.log"
    exit 1
  }

  # 啟動監控
  start_monitoring

  # 執行測試
  echo -e "\n=== 測試開始 ===" | tee -a "$DIALOG_FILE"
  {
    echo "輸入提示詞: $TEST_PROMPT"
    START_TIME=$(date +%s.%N)
    RESPONSE=$("$OLLAMA_PATH" run "$MODEL_NAME" "$TEST_PROMPT")
    END_TIME=$(date +%s.%N)
    echo -e "\n模型輸出:\n$RESPONSE"
    ELAPSED=$(awk -v s=$START_TIME -v e=$END_TIME 'BEGIN {printf "%.3f", e - s}')
    echo -e "\n執行時間: ${ELAPSED}秒"
  } | ts '[%Y-%m-%d %H:%M:%S]' | tee -a "$DIALOG_FILE"

  # 生成報告
  echo -e "\n=== 測試結果 ===" >> "$REPORT_FILE"
  awk -F',' -v elapsed="$ELAPSED" -v prompt="$TEST_PROMPT" '
  BEGIN {
    print "提示詞: " prompt
    print "執行時間: " elapsed " 秒"
    print "\n資源使用統計:"
  }
  NR>1 {
    count++
    cpu+=$2
    mem+=$3
    gpu_use+=$4
    gpu_mem+=$5
  }
  END {
    printf "CPU平均: %.1f%%\n", cpu/count
    printf "記憶體平均: %.1f MB\n", mem/count
    printf "GPU使用率平均: %.1f%%\n", gpu_use/count
    printf "GPU記憶體平均: %.1f MB\n", gpu_mem/count
  }' "$PERF_DATA" >> "$REPORT_FILE"

  # 附加完整輸出
  echo -e "\n=== 完整模型輸出 ===" >> "$REPORT_FILE"
  cat "$DIALOG_FILE" >> "$REPORT_FILE"

  echo -e "\n=== 測試完成 ==="
  echo "報告文件: $REPORT_FILE"
  echo "其他輸出: $OUTPUT_DIR/"
}

main
