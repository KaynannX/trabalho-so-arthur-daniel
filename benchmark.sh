#!/usr/bin/env bash
# ==============================================================================
# Script de Benchmark de Cópia de Arquivos entre Sistemas de Arquivos
# Autores: Arthur e Daniel
# Disciplina: Sistemas Operacionais
# Configuração: Opção 3 (PA = EXT4 [bloco 1KB] | PB = NTFS [cluster 512B])
# ==============================================================================
set -euo pipefail

# Garante privilégios de root para montagem e limpeza de cache
if [ "$EUID" -ne 0 ]; then
  echo "[-] Este script requer privilégios de superusuário (execute com sudo)."
  exit 1
fi

# ================= CONFIGURAÇÕES PRINCIPAIS =================
# Partições de teste (lidas automaticamente do setup ou padrão /dev/loop0p*)
DEVICE_PA="${1:-$(cat /var/tmp/benchmark_pa.txt 2>/dev/null || echo "/dev/loop0p1")}"
DEVICE_PB="${2:-$(cat /var/tmp/benchmark_pb.txt 2>/dev/null || echo "/dev/loop0p2")}"

MOUNT_PA="/mnt/bench_pa"
MOUNT_PB="/mnt/bench_pb"

# Diretório base dos datasets no sistema de arquivos local nativo (evita gargalo do 9p)
DATASET_BASE="/var/tmp/benchmark_dataset"
DIR_GRANDE="$DATASET_BASE/grande"
DIR_PEQUENA="$DATASET_BASE/pequena"

# Parâmetros dos cenários de teste conforme enunciado
NUM_COPIAS_GRANDE=5       # Facilmente alterável para 10 cópias se desejado
TAMANHO_ARQUIVO_GRANDE=1  # 1 GB
NUM_COPIAS_PEQUENA=1000   # 1.000 cópias de 1 KB
REPETICOES=10             # 10 repetições para cálculo de média estatística

LOG_DIR="$(pwd)/logs"
mkdir -p "$LOG_DIR"
CSV_FILE="$LOG_DIR/benchmark_resultados.csv"
LOG_DETALHADO="$LOG_DIR/benchmark_execucao.log"

echo "timestamp,particao,sistema_arquivos,cluster_bloco,cenario,repeticao,tempo_segundos,tempo_ms" > "$CSV_FILE"
exec > >(tee -a "$LOG_DETALHADO") 2>&1

echo "=================================================================="
echo "    BENCHMARK DE SISTEMAS DE ARQUIVOS - ARTHUR E DANIEL"
echo "=================================================================="
echo "Início em: $(date)"
echo "Dispositivo PA: $DEVICE_PA (EXT4 - Bloco 1 KB)"
echo "Dispositivo PB: $DEVICE_PB (NTFS - Cluster 512 B)"
echo "Cenário Grande: $NUM_COPIAS_GRANDE arquivos de ${TAMANHO_ARQUIVO_GRANDE} GB"
echo "Cenário Pequeno: $NUM_COPIAS_PEQUENA arquivos de 1 KB"
echo "Número de Repetições por Teste: $REPETICOES"
echo "=================================================================="
echo ""

# ================= 1. GERAÇÃO DO DATASET =================
mkdir -p "$DIR_GRANDE" "$DIR_PEQUENA"

echo "[1/3] Verificando e gerando datasets de teste..."

# Cenário 1: Arquivos Grandes (1 GB cada, com cabeçalho de PDF e dados reais)
EXISTENTES_GRANDE=$(find "$DIR_GRANDE" -maxdepth 1 -name "*.pdf" | wc -l)
BLOCOS_ALOCADOS=$(stat -c "%b" "$DIR_GRANDE/documento_grande_1.pdf" 2>/dev/null || echo 0)

if [ "$EXISTENTES_GRANDE" -lt "$NUM_COPIAS_GRANDE" ] || [ "$BLOCOS_ALOCADOS" -lt 1000000 ]; then
  echo " -> Gerando arquivo base de 1 GB com dados reais (não-esparsos) e cabeçalho PDF..."
  BASE_PDF="$DATASET_BASE/base_template.pdf"
  rm -rf "$DIR_GRANDE"/*
  
  # Cria cabeçalho PDF
  printf "%%PDF-1.4\n" > "$BASE_PDF"
  # Preenche exatamente 1 GiB com blocos rápidos
  dd if=/dev/urandom of="$BASE_PDF" bs=4M count=256 status=none conv=notrunc oflag=append
  
  for i in $(seq 1 "$NUM_COPIAS_GRANDE"); do
    ARQ="$DIR_GRANDE/documento_grande_$i.pdf"
    echo "    Criando cópia $i de ${TAMANHO_ARQUIVO_GRANDE} GB..."
    cp --sparse=never "$BASE_PDF" "$ARQ"
  done
  rm -f "$BASE_PDF"
fi
echo " -> Dataset Grande pronto: $(du -sh "$DIR_GRANDE" | cut -f1) ($NUM_COPIAS_GRANDE arquivos de 1GB reais)"

# Cenário 2: Arquivos Pequenos (1.000 cópias de 1 KB)
EXISTENTES_PEQUENA=$(find "$DIR_PEQUENA" -maxdepth 1 -name "*.bin" | wc -l)
if [ "$EXISTENTES_PEQUENA" -lt "$NUM_COPIAS_PEQUENA" ]; then
  echo " -> Gerando $NUM_COPIAS_PEQUENA arquivos de 1 KB..."
  python3 -c "
import os
dest = '$DIR_PEQUENA'
os.makedirs(dest, exist_ok=True)
for i in range(1, $NUM_COPIAS_PEQUENA + 1):
    path = os.path.join(dest, f'arquivo_{i:04d}.bin')
    if not os.path.exists(path):
        with open(path, 'wb') as f:
            f.write(os.urandom(1024))
"
fi
echo " -> Dataset Pequeno pronto: $(du -sh "$DIR_PEQUENA" | cut -f1) ($NUM_COPIAS_PEQUENA arquivos)"

# ================= 2. PONTOS DE MONTAGEM =================
echo ""
echo "[2/3] Preparando pontos de montagem..."
mkdir -p "$MOUNT_PA" "$MOUNT_PB"

# Garante que não estavam montados anteriormente
umount "$MOUNT_PA" 2>/dev/null || true
umount "$MOUNT_PB" 2>/dev/null || true

mount "$DEVICE_PA" "$MOUNT_PA"
mount "$DEVICE_PB" "$MOUNT_PB"
echo " -> Partição PA montada em $MOUNT_PA"
echo " -> Partição PB montada em $MOUNT_PB"

# ================= 3. FUNÇÃO DE EXECUÇÃO DO BENCHMARK =================
executar_cenario() {
  local DESTINO="$1"
  local ORIGEM="$2"
  local NOME_PARTICAO="$3"
  local FS_TIPO="$4"
  local CLUSTER_TAM="$5"
  local ROTULO_CENARIO="$6"
  local VAR_RETORNO_MEDIA="$7"

  echo ""
  echo "------------------------------------------------------------------"
  echo ">>> EXECUTANDO: $ROTULO_CENARIO em $NOME_PARTICAO ($FS_TIPO, Bloco/Cluster: $CLUSTER_TAM)"
  echo "------------------------------------------------------------------"

  local SOMA_MS=0
  local TEMPOS_MS=()

  for rep in $(seq 1 "$REPETICOES"); do
    # 1. Garante limpeza completa do cache de disco e buffer da memória RAM
    sync
    echo 3 > /proc/sys/vm/drop_caches

    # 2. Início da contagem do tempo
    local T_START
    T_START=$(date +%s%N)

    # 3. Operação de cópia dos arquivos (forçando escrita física completa de todos os blocos)
    cp -r --sparse=never "$ORIGEM/." "$DESTINO/"

    # 4. Força commit de todos os buffers e metadados diretamente na partição
    sync

    # 5. Fim da contagem
    local T_END
    T_END=$(date +%s%N)

    local DELTA_NS=$(( T_END - T_START ))
    local DELTA_MS=$(( DELTA_NS / 1000000 ))
    local DELTA_SEG
    DELTA_SEG=$(awk -v ms="$DELTA_MS" 'BEGIN { printf "%.3f", ms / 1000 }')

    TEMPOS_MS+=("$DELTA_MS")
    SOMA_MS=$(( SOMA_MS + DELTA_MS ))

    # Grava no CSV
    echo "$(date +%T),$NOME_PARTICAO,$FS_TIPO,$CLUSTER_TAM,$ROTULO_CENARIO,$rep,$DELTA_SEG,$DELTA_MS" >> "$CSV_FILE"

    printf "  [Repetição %02d/%02d] Tempo: %8s s (%6d ms)\n" "$rep" "$REPETICOES" "$DELTA_SEG" "$DELTA_MS"

    # Limpeza para que a partição não lote e cada repetição comece em igualdade
    rm -rf "$DESTINO"/*
    sync
  done

  # Cálculo da Média e Desvio
  local MEDIA_MS=$(( SOMA_MS / REPETICOES ))
  local MEDIA_SEG
  MEDIA_SEG=$(awk -v ms="$MEDIA_MS" 'BEGIN { printf "%.3f", ms / 1000 }')

  echo "=> Média $ROTULO_CENARIO ($NOME_PARTICAO): $MEDIA_SEG s ($MEDIA_MS ms)"
  eval "$VAR_RETORNO_MEDIA='$MEDIA_SEG'"
}

# ================= 4. EXECUÇÃO DOS 4 TESTES =================
echo ""
echo "[3/3] Iniciando rodadas de benchmark..."

# Testes na Partição A (EXT4, Bloco 1 KB)
executar_cenario "$MOUNT_PA" "$DIR_GRANDE"  "PA" "EXT4" "1KB" "Grandes (5x1GB)" MEDIA_PA_GRANDE
executar_cenario "$MOUNT_PA" "$DIR_PEQUENA" "PA" "EXT4" "1KB" "Pequenos (1000x1KB)" MEDIA_PA_PEQUENA

# Testes na Partição B (NTFS, Cluster 512 B)
executar_cenario "$MOUNT_PB" "$DIR_GRANDE"  "PB" "NTFS" "512B" "Grandes (5x1GB)" MEDIA_PB_GRANDE
executar_cenario "$MOUNT_PB" "$DIR_PEQUENA" "PB" "NTFS" "512B" "Pequenos (1000x1KB)" MEDIA_PB_PEQUENA

# ================= 5. DESMONTAGEM E FINALIZAÇÃO =================
sync
umount "$MOUNT_PA"
umount "$MOUNT_PB"

echo ""
echo "=================================================================="
echo "                   TABELA FINAL DE RESULTADOS                     "
echo "              Média de Tempo por Cópia (10 Repetições)            "
echo "=================================================================="
printf "| %-22s | %-20s | %-20s |\n" "Cenário de Teste" "PA (EXT4 - Bloco 1KB)" "PB (NTFS - Cluster 512B)"
echo "|------------------------|----------------------|----------------------|"
printf "| %-22s | %17s s | %17s s |\n" "Grandes ($NUM_COPIAS_GRANDE x 1GB)" "$MEDIA_PA_GRANDE" "$MEDIA_PB_GRANDE"
printf "| %-22s | %17s s | %17s s |\n" "Pequenos (1000 x 1KB)" "$MEDIA_PA_PEQUENA" "$MEDIA_PB_PEQUENA"
echo "=================================================================="
echo ""
echo "[✓] Benchmark finalizado com sucesso em: $(date)"
echo "[✓] Dados brutos salvos em: $CSV_FILE"
echo "[✓] Log de execução salvo em: $LOG_DETALHADO"
