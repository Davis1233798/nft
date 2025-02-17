#!/bin/bash
set -eo pipefail

# 配置區
MODEL_NAME="mistral:7b"
TEST_PROMPT="請用繁體中文回答：如何優化生產線效率？"
OUTPUT_DIR="$(pwd)/ollama_test_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$OUTPUT_DIR/report.txt"
DIALOG_FILE="$OUTPUT_DIR/dialogue.log"
PERF_DATA="$OUTPUT_DIR/perf.csv"

# 進度顯示函數
show_progress() {
  local pid=$1
  local delay=0.5
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# 初始化輸出目錄
mkdir -p "$OUTPUT_DIR"
exec > >(tee -a "$OUTPUT_DIR/script.log") 2>&1

echo -e "\n=== 腳本啟動 ==="
echo "輸出目錄：$OUTPUT_DIR"

# 硬體規格檢測
echo -e "\n[1/6] 收集硬體資訊..."
{
  echo "=== 硬體規格 ==="
  echo "主機名稱: $(hostname)"
  echo "CPU型號: $(lscpu | awk -F': +' '/Model name/ {print $2}' | xargs || echo '未知')"
  echo "核心數/執行緒數: $(nproc) / $(lscpu | awk -F': +' '/^CPU\(s\)/ {print $2}')"
  echo "記憶體總量: $(free -h | awk '/Mem/ {print $2}')"
  echo "儲存空間: $(df -h / | awk 'NR==2 {print $2}')"
  echo "系統版本: $(lsb_release -ds 2>/dev/null || uname -a)"
} | tee -a "$REPORT_FILE"

# 安裝依賴
echo -e "\n[2/6] 安裝必要套件..."
{
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates bc moreutils
  rm -rf /var/lib/apt/lists/*
} 2>&1 | tee -a "$OUTPUT_DIR/install.log" || {
  echo "!! 套件安裝失敗！請檢查：$OUTPUT_DIR/install.log"
  exit 1
}

# 下載Ollama
echo -e "\n[3/6] 下載Ollama主程式..."
OLLAMA_PATH="$OUTPUT_DIR/ollama"
{
  curl -#L "https://github.com/ollama/ollama/releases/download/v0.1.33/ollama-linux-amd64" -o "$OLLAMA_PATH"
  chmod +x "$OLLAMA_PATH"
} 2>&1 | tee -a "$OUTPUT_DIR/download.log" || {
  echo "!! 下載失敗！請檢查：$OUTPUT_DIR/download.log"
  exit 1
}

# 啟動服務
echo -e "\n[4/6] 啟動Ollama服務..."
export OLLAMA_MODELS="$OUTPUT_DIR/models"
mkdir -p "$OLLAMA_MODELS"
nohup "$OLLAMA_PATH" serve > "$OUTPUT_DIR/service.log" 2>&1 &
OLLAMA_PID=$!

# 清理函數
cleanup() {
  echo -e "\n正在清理..."
  kill -TERM "$OLLAMA_PID" 2>/dev/null && wait "$OLLAMA_PID" 2>/dev/null
  echo "清理完成"
}
trap cleanup EXIT

# 等待服務啟動
echo -n "等待服務啟動（最長60秒）..."
timeout 60 bash -c 'until curl -s http://localhost:11434 >/dev/null; do
  echo -n "."; sleep 2
done' 2>&1 | tee -a "$OUTPUT_DIR/service.log" || {
  echo -e "\n!! 服務啟動超時！最後日誌："
  tail -n 20 "$OUTPUT_DIR/service.log"
  exit 1
}
echo -e "\n服務已就緒！"

# 下載模型
echo -e "\n[5/6] 下載模型 $MODEL_NAME..."
{
  echo "開始下載模型..." | tee -a "$OUTPUT_DIR/model_download.log"
  "$OLLAMA_PATH" pull "$MODEL_NAME" 2>&1 | tee -a "$OUTPUT_DIR/model_download.log"
} || {
  echo "!! 模型下載失敗！錯誤日誌："
  tail -n 20 "$OUTPUT_DIR/model_download.log"
  exit 1
}

# 執行測試
echo -e "\n[6/6] 執行效能測試..."
{
  echo -e "=== 測試開始 ===\n時間：$(date)"
  echo -e "提示詞：$TEST_PROMPT"
  START_TIME=$(date +%s.%N)
  echo -e "\n--- 模型輸出 ---"
  "$OLLAMA_PATH" run "$MODEL_NAME" "$TEST_PROMPT"
  END_TIME=$(date +%s.%N)
  ELAPSED=$(awk -v s=$START_TIME -v e=$END_TIME 'BEGIN {printf "%.3f", e - s}')
  echo -e "\n--- 測試結果 ---\n執行時間：${ELAPSED}秒"
} | tee "$DIALOG_FILE"

# 生成報告
echo -e "\n生成最終報告..."
{
  echo -e "\n=== 效能摘要 ==="
  echo "模型名稱: $MODEL_NAME"
  echo "提示詞: $TEST_PROMPT"
  echo "執行時間: ${ELAPSED}秒"
  echo -e "\n硬體規格摘要:"
  grep -A 10 "=== 硬體規格 ===" "$REPORT_FILE"
} | tee "$REPORT_FILE"

echo -e "\n=== 測試完成 ==="
echo "請檢查以下文件："
ls -lh "$OUTPUT_DIR"/*