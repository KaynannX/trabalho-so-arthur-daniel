#!/usr/bin/env bash
# ==============================================================================
# Script de Configuração de Disco Virtual e Partições (Opção 3)
# Autores: Arthur e Daniel
# Disciplina: Sistemas Operacionais
# ==============================================================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] Este script precisa ser executado como root."
  exit 1
fi

IMG_FILE="/var/tmp/benchmark_disk.img"
IMG_SIZE="25G"

echo "[1/4] Criando imagem de disco de $IMG_SIZE em $IMG_FILE..."
truncate -s "$IMG_SIZE" "$IMG_FILE"

echo "[2/4] Associando imagem a um dispositivo de loop com suporte a partições..."
# Desassocia loops antigos se existirem para o mesmo arquivo
for l in $(losetup -j "$IMG_FILE" -O NAME --noheadings 2>/dev/null); do
  echo "Desassociando loop anterior: $l"
  losetup -d "$l" || true
done

LOOP_DEV=$(losetup -fP --show "$IMG_FILE")
echo " -> Dispositivo criado: $LOOP_DEV"

echo "[3/4] Criando tabela de partições GPT e dividindo em 50% (PA) e 50% (PB)..."
parted -s "$LOOP_DEV" mklabel gpt
parted -s "$LOOP_DEV" mkpart PA 1MiB 50%
parted -s "$LOOP_DEV" mkpart PB 50% 100%

# Força atualização da tabela de partição no kernel
udevadm settle 2>/dev/null || sleep 1
partprobe "$LOOP_DEV"
sleep 1

PA="${LOOP_DEV}p1"
PB="${LOOP_DEV}p2"

if [ ! -b "$PA" ] || [ ! -b "$PB" ]; then
  echo "[-] Erro: As partições $PA e $PB não foram encontradas."
  exit 1
fi

echo " -> Partição A (PA): $PA"
echo " -> Partição B (PB): $PB"

echo "[4/4] Formatando partições conforme Opção 3:"
echo " -> Formatando PA com EXT4 (bloco mínimo de 1024 bytes)..."
mkfs.ext4 -F -b 1024 "$PA"

echo " -> Formatando PB com NTFS (cluster mínimo de 512 bytes)..."
mkfs.ntfs -f -c 512 "$PB"

echo ""
echo "=== VERIFICAÇÃO DOS PARÂMETROS DE FORMATAÇÃO ==="
echo "[*] Bloco EXT4 em $PA:"
tune2fs -l "$PA" | grep "Block size:"

echo "[*] Cluster NTFS em $PB:"
ntfsinfo -m "$PB" | grep -E "Bytes per cluster|Cluster size" || true

# Salva a referência dos dispositivos para o benchmark.sh ler automaticamente
echo "$PA" > /var/tmp/benchmark_pa.txt
echo "$PB" > /var/tmp/benchmark_pb.txt

echo ""
echo "[✓] Configuração de disco concluída com sucesso!"
