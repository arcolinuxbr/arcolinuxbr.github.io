#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# CALAMARES PARA ARCH LINUX
# Instalação limpa e repetível
#
# Base:
#   Calamares 3.4.2-4 / CachyOS
#
# Particularidade Arch:
#   usa initcpiocfg + initcpio
#   NÃO usa initramfs
#
# ============================================================

CALAMARes_VERSION="3.4.2-4"
CALAMARES_PKG="cachyos-calamares-${CALAMARes_VERSION}-x86_64.pkg.tar.zst"
CALAMARES_URL="https://cdn77.cachyos.org/repo/x86_64/cachyos/${CALAMARES_PKG}"

# SHA256 do pacote conhecido
CALAMARES_SHA256="26c1e60e5fb83c59696cb8f1dd6cb6e3f0801902615f33baf1b23283aa91affd0"

TMPDIR_CALAMARES="/tmp/calamares-install"

# ------------------------------------------------------------
# CORES
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    CYAN='\033[1;36m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[ OK ]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${RESET} $*"
}

error() {
    echo -e "${RED}[ERRO]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
    echo
}

# ------------------------------------------------------------
# ERRO
# ------------------------------------------------------------

trap 'error "Falha na linha $LINENO. Instalação interrompida."' ERR

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    die "Não execute este script diretamente como root."
fi

# ------------------------------------------------------------
# INTERNET
# ------------------------------------------------------------

section "VERIFICANDO INTERNET"

if ! curl -fsI --connect-timeout 10 https://cdn77.cachyos.org >/dev/null; then
    die "Não foi possível acessar o servidor do CachyOS."
fi

ok "Conexão com a Internet funcionando."

# ------------------------------------------------------------
# SUDO
# ------------------------------------------------------------

section "VERIFICANDO SUDO"

sudo -v

ok "Sudo disponível."

# ------------------------------------------------------------
# ATUALIZAÇÃO
# ------------------------------------------------------------

section "ATUALIZANDO O ARCH LINUX"

sudo pacman -Syu --noconfirm

ok "Sistema atualizado."

# ------------------------------------------------------------
# DEPENDÊNCIAS
# ------------------------------------------------------------

section "INSTALANDO DEPENDÊNCIAS"

sudo pacman -S --needed --noconfirm \
    boost-libs \
    ckbcomp \
    cryptsetup \
    dmidecode \
    gptfdisk \
    hwinfo \
    kconfig \
    kcoreaddons \
    kcrash \
    ki18n \
    kparts \
    kpmcore \
    kservice \
    kwidgetsaddons \
    libpwquality \
    mkinitcpio \
    mkinitcpio-openswap \
    networkmanager \
    polkit-qt6 \
    python \
    qt6-declarative \
    qt6-imageformats \
    qt6-svg \
    rsync \
    solid \
    squashfs-tools \
    upower \
    yaml-cpp

ok "Dependências instaladas."

# ------------------------------------------------------------
# REMOÇÃO DA INSTALAÇÃO ANTIGA
# ------------------------------------------------------------

section "REMOVENDO CALAMARES ANTIGO"

sudo pacman -Rns --noconfirm \
    calamares \
    calamares-debug \
    cachyos-calamares \
    cachyos-calamares-next \
    cachyos-calamares-deckify \
    cachyos-calamares-next-deckify \
    cachyos-calamares-qt6-systemd \
    cachyos-calamares-qt6-next-systemd \
    2>/dev/null || true

ok "Instalação anterior removida."

# ------------------------------------------------------------
# LIMPEZA DE CONFIGURAÇÕES ANTIGAS
# ------------------------------------------------------------

section "LIMPANDO CONFIGURAÇÕES ANTIGAS"

# Não apagamos /etc/calamares inteiro sem necessidade.
# Apenas fazemos backup se existir.

BACKUP_DIR="/root/calamares-backup-$(date +%Y%m%d-%H%M%S)"

if [[ -d /etc/calamares ]]; then
    info "Criando backup de /etc/calamares..."
    sudo mkdir -p "$BACKUP_DIR"
    sudo cp -a /etc/calamares "$BACKUP_DIR/"
    ok "Backup criado em: $BACKUP_DIR"
fi

# ------------------------------------------------------------
# DIRETÓRIO TEMPORÁRIO
# ------------------------------------------------------------

section "PREPARANDO DOWNLOAD"

rm -rf "$TMPDIR_CALAMARES"
mkdir -p "$TMPDIR_CALAMARES"

cd "$TMPDIR_CALAMARES"

info "Baixando:"
echo "  $CALAMARES_PKG"
echo

curl -fL \
    --retry 3 \
    --retry-delay 2 \
    -o "$CALAMARES_PKG" \
    "$CALAMARES_URL"

ok "Pacote baixado."

# ------------------------------------------------------------
# VERIFICAÇÃO SHA256
# ------------------------------------------------------------

section "VERIFICANDO INTEGRIDADE"

echo "${CALAMARES_SHA256}  ${CALAMARES_PKG}" | sha256sum -c -

ok "SHA256 confirmado."

# ------------------------------------------------------------
# INSTALAÇÃO
# ------------------------------------------------------------

section "INSTALANDO CALAMARES"

sudo pacman -U \
    --noconfirm \
    "./$CALAMARES_PKG"

ok "Calamares instalado."

# ------------------------------------------------------------
# LOCALIZAR SETTINGS.CONF
# ------------------------------------------------------------

section "LOCALIZANDO CONFIGURAÇÃO"

SETTINGS=""

for candidate in \
    /etc/calamares/settings.conf \
    /usr/share/calamares/settings.conf
do
    if [[ -f "$candidate" ]]; then
        SETTINGS="$candidate"
        break
    fi
done

if [[ -z "$SETTINGS" ]]; then
    die "settings.conf não encontrado."
fi

info "Configuração utilizada:"
echo "  $SETTINGS"

# ------------------------------------------------------------
# BACKUP DO SETTINGS
# ------------------------------------------------------------

SETTINGS_BACKUP="${SETTINGS}.backup-$(date +%Y%m%d-%H%M%S)"

sudo cp -a "$SETTINGS" "$SETTINGS_BACKUP"

ok "Backup criado:"
echo "  $SETTINGS_BACKUP"

# ------------------------------------------------------------
# CORREÇÃO DO INITRAMFS
# ------------------------------------------------------------

section "CONFIGURANDO MKINITCPIO"

info "Removendo initramfs da sequência do Calamares..."

sudo sed -i \
    -e '/^[[:space:]]*-[[:space:]]*initramfs[[:space:]]*$/d' \
    -e '/^[[:space:]]*-[[:space:]]*initramfs@initramfs[[:space:]]*$/d' \
    "$SETTINGS"

ok "initramfs removido da sequência."

# ------------------------------------------------------------
# GARANTIR INITCPIO
# ------------------------------------------------------------

if grep -Eq '^[[:space:]]*-[[:space:]]*initcpio[[:space:]]*$' "$SETTINGS"; then
    ok "initcpio já está configurado."
else
    warn "initcpio não encontrado na configuração."

    # Não tenta modificar automaticamente a sequência em uma
    # configuração desconhecida.
    warn "Será necessário verificar o settings.conf manualmente."
fi

# ------------------------------------------------------------
# VERIFICAR PLUGINS
# ------------------------------------------------------------

section "VERIFICANDO PLUGINS DO CALAMARES"

MODULE_DIR="/usr/lib/calamares/modules"

if [[ ! -d "$MODULE_DIR" ]]; then
    die "Diretório de módulos não existe: $MODULE_DIR"
fi

echo "Diretório:"
echo "  $MODULE_DIR"
echo

find "$MODULE_DIR" \
    -maxdepth 2 \
    -type f \
    -printf '%p\n' \
    2>/dev/null | sort

# ------------------------------------------------------------
# INITCPIO
# ------------------------------------------------------------

section "VERIFICANDO MÓDULO INITCPIO"

INITCPIO_FOUND=0

if find "$MODULE_DIR/initcpio" \
    -type f \
    -name '*.so' \
    2>/dev/null | grep -q .; then

    INITCPIO_FOUND=1
fi

if [[ "$INITCPIO_FOUND" -eq 1 ]]; then
    ok "Módulo initcpio encontrado."
else
    die "Módulo initcpio não foi encontrado."
fi

# ------------------------------------------------------------
# INITRAMFS
# ------------------------------------------------------------

section "VERIFICANDO INITRAMFS"

INITRAMFS_FOUND=0

if find "$MODULE_DIR" \
    -type f \
    -iname '*initramfs*.so' \
    2>/dev/null | grep -q .; then

    INITRAMFS_FOUND=1
fi

if [[ "$INITRAMFS_FOUND" -eq 1 ]]; then
    warn "Existe um módulo initramfs instalado."
    echo
    find "$MODULE_DIR" \
        -type f \
        -iname '*initramfs*.so' \
        -print
else
    ok "Nenhum módulo initramfs necessário."
fi

# ------------------------------------------------------------
# CONFIGURAÇÃO
# ------------------------------------------------------------

section "CONFIGURAÇÃO FINAL"

echo
echo "Módulos relacionados ao init:"
grep -nE 'initramfs|initcpio' "$SETTINGS" || true

echo

# ------------------------------------------------------------
# TESTE DE CONFIGURAÇÃO
# ------------------------------------------------------------

section "TESTANDO CALAMARES"

TEST_LOG="/tmp/calamares-test-$(date +%Y%m%d-%H%M%S).log"

set +e

timeout 15 calamares -d >"$TEST_LOG" 2>&1

CALAMARes_EXIT=$?

set -e

echo "Log:"
echo "  $TEST_LOG"
echo

# ------------------------------------------------------------
# ANALISAR ERROS
# ------------------------------------------------------------

if grep -q 'Module "initramfs@initramfs" not found' "$TEST_LOG"; then
    error "O módulo initramfs ainda está sendo solicitado."
    echo
    grep -n 'initramfs' "$TEST_LOG"
    exit 1
fi

if grep -q 'failed modules' "$TEST_LOG"; then
    error "O Calamares ainda possui módulos configurados que falharam."

    echo
    grep -nE \
        'ERROR: Module|failed modules|not found' \
        "$TEST_LOG" || true

    echo
    error "Consulte o log:"
    echo "$TEST_LOG"

    exit 1
fi

# timeout normalmente retorna 124.
# Isso é aceitável se o Calamares iniciou corretamente.
if [[ "$CALAMARes_EXIT" -eq 124 ]]; then
    ok "Calamares iniciou corretamente e foi encerrado pelo timeout."
elif [[ "$CALAMARes_EXIT" -ne 0 ]]; then
    warn "Calamares terminou com código $CALAMARes_EXIT."
    warn "Consulte: $TEST_LOG"
else
    ok "Calamares executado."
fi

# ------------------------------------------------------------
# VERSÃO
# ------------------------------------------------------------

section "VERSÃO INSTALADA"

calamares --version || true

# ------------------------------------------------------------
# FINAL
# ------------------------------------------------------------

section "INSTALAÇÃO CONCLUÍDA"

echo
echo "Calamares está instalado."
echo
echo "Configuração:"
echo "  $SETTINGS"
echo
echo "Plugins:"
echo "  $MODULE_DIR"
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo
echo "Log do teste:"
echo "  $TEST_LOG"
echo

ok "CALAMARES PRONTO PARA USO."

echo
echo "Para iniciar:"
echo
echo "    calamares"
echo
