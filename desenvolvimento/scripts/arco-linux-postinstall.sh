#!/usr/bin/env bash
#
# ARCO LINUX POST-INSTALL + NETWORK GUARD
# "Arch que instala, conecta, usa e se recupera"
# v3.2.0
#
# Filosofia:
#   1. O instalador recupera/reconstrói a rede quando necessário.
#   2. Instala um Network Guard permanente no sistema.
#   3. No boot, o Guard diagnostica primeiro.
#   4. Se a rede estiver saudável, NÃO ALTERA NADA.
#   5. Se houver falha, tenta reparos progressivos.
#   6. Só faz reconstrução completa quando o diagnóstico justificar.
#
# Uso:
#   chmod +x arco-linux-postinstall-v3.2.0.sh
#   ./arco-linux-postinstall-v3.2.0.sh
#
# Depois da instalação:
#   sudo arco-network-guard --status
#   sudo arco-network-guard --repair
#   sudo systemctl status arco-network-guard.service
#

set -uo pipefail

VERSION="3.2.0"
SCRIPT_NAME="$(basename "$0")"
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"

STATE_DIR="/var/lib/arco-linux"
BACKUP_ROOT="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/arco-linux"
LOG_FILE="$LOG_DIR/postinstall-$(
    date +%Y%m%d-%H%M%S
).log"

SKIP_AUR=0
SKIP_VIRTUALIZATION=0
SKIP_FONTS=0
SKIP_FLATPAK=0
NO_FIREWALL=0
MINIMAL=0

for arg in "$@"; do
    case "$arg" in
        --skip-aur) SKIP_AUR=1 ;;
        --skip-virtualization) SKIP_VIRTUALIZATION=1 ;;
        --skip-fonts) SKIP_FONTS=1 ;;
        --skip-flatpak) SKIP_FLATPAK=1 ;;
        --no-firewall) NO_FIREWALL=1 ;;
        --minimal) MINIMAL=1 ;;
        -h|--help)
            cat <<EOF
Uso: $SCRIPT_NAME [opções]

  --skip-aur              não instalar pacote AUR
  --skip-virtualization   não instalar QEMU/libvirt/GNOME Boxes
  --skip-fonts            não instalar fontes
  --skip-flatpak          não instalar Flatpak
  --no-firewall           não habilitar firewalld
  --minimal               instalação mínima

Após a instalação:
  sudo arco-network-guard --status
  sudo arco-network-guard --repair
EOF
            exit 0
            ;;
        *)
            echo "Opção desconhecida: $arg" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

OK=0
WARN=0
FAIL=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; WARN=$((WARN+1)); }
ok()   { printf '[OK] %s\n' "$*"; OK=$((OK+1)); }
fail() { printf '[ERRO] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

die() {
    fail "$*"
    echo "Log: $LOG_FILE"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

backup_path() {
    local src="$1"
    local dst="$BACKUP_ROOT/network/$(echo "$src" | sed 's#^/##')"
    if [ -e "$src" ] || [ -L "$src" ]; then
        sudo mkdir -p "$(dirname "$dst")"
        sudo cp -a "$src" "$dst" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# DETECÇÃO
# ---------------------------------------------------------------------------

detect_environment() {
    echo
    echo "================================================================"
    echo "1/15 - DETECÇÃO DO AMBIENTE"
    echo "================================================================"

    local virt="none"
    command_exists systemd-detect-virt && \
        virt="$(systemd-detect-virt 2>/dev/null || echo none)"

    local kvm="não"
    [ -e /dev/kvm ] && kvm="sim"

    local firmware="BIOS/Legacy"
    [ -d /sys/firmware/efi ] && firmware="UEFI"

    echo "Arco Linux post-install v$VERSION"
    echo "Usuário: $REAL_USER"
    echo "Home: $REAL_HOME"
    echo "Kernel: $(uname -r)"
    echo "Arquitetura: $(uname -m)"
    echo "Firmware: $firmware"
    echo "Virtualização: $virt"
    echo "/dev/kvm: $kvm"
    echo
    ip -br link 2>/dev/null || true
    echo
    ip -br addr 2>/dev/null || true
    echo
    ip route 2>/dev/null || true

    if [ "$virt" != "none" ] && [ "$virt" != "unknown" ]; then
        info "Ambiente virtual detectado: $virt."
    else
        info "Tratando o sistema como máquina física."
    fi

    ok "Detecção concluída."
}

# ---------------------------------------------------------------------------
# REDE: FUNÇÕES COMUNS
# ---------------------------------------------------------------------------

install_network_prerequisites() {
    echo
    echo "================================================================"
    echo "2/15 - PRÉ-REQUISITOS DE REDE"
    echo "================================================================"

    if ! command_exists nmcli; then
        info "NetworkManager não encontrado. Tentando instalar."
        sudo pacman -S --needed --noconfirm networkmanager wireless-regdb iwd || \
            die "Não foi possível instalar NetworkManager."
    fi

    command_exists nmcli || die "nmcli não está disponível."

    sudo systemctl unmask NetworkManager.service 2>/dev/null || true
    sudo systemctl enable NetworkManager.service 2>/dev/null || true
    ok "NetworkManager disponível."
}

stop_conflicting_network_managers() {
    echo
    echo "================================================================"
    echo "3/15 - GERENCIADORES DE REDE CONCORRENTES"
    echo "================================================================"

    local services=(
        systemd-networkd.service
        systemd-networkd-wait-online.service
        dhcpcd.service
        connman.service
        netctl.service
        iwd.service
        wpa_supplicant.service
        wpa_supplicant@.service
    )

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Parando $svc."
            sudo systemctl stop "$svc" 2>/dev/null || true
        fi
        sudo systemctl disable "$svc" 2>/dev/null || true
    done

    if systemctl is-active --quiet libvirtd.service 2>/dev/null; then
        info "Parando libvirtd temporariamente."
        sudo systemctl stop libvirtd.service 2>/dev/null || true
    fi

    sudo systemctl enable --now NetworkManager.service || \
        die "NetworkManager não pôde ser iniciado."

    ok "NetworkManager é o gerenciador de rede principal."
}

backup_network_configuration() {
    info "Fazendo backup da configuração de rede."
    sudo mkdir -p "$BACKUP_ROOT/network"

    backup_path /etc/NetworkManager
    backup_path /etc/systemd/network
    backup_path /etc/systemd/resolved.conf
    backup_path /etc/resolv.conf
    backup_path /etc/dhcpcd.conf
    backup_path /etc/netctl
    backup_path /etc/iwd
    backup_path /etc/wpa_supplicant

    ok "Backup: $BACKUP_ROOT/network/"
}

rebuild_network_configuration() {
    echo
    echo "================================================================"
    echo "4/15 - RECONSTRUÇÃO DA CONFIGURAÇÃO DE REDE"
    echo "================================================================"

    backup_network_configuration

    # Perfis do NM: removemos somente os perfis operacionais.
    sudo mkdir -p "$BACKUP_ROOT/network/NetworkManager"
    if [ -d /etc/NetworkManager/system-connections ]; then
        sudo cp -a /etc/NetworkManager/system-connections \
            "$BACKUP_ROOT/network/NetworkManager/" 2>/dev/null || true
    fi

    sudo rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true
    sudo mkdir -p /etc/NetworkManager/system-connections
    sudo chmod 700 /etc/NetworkManager/system-connections

    # Configurações concorrentes.
    sudo rm -f /etc/systemd/network/*.network \
                /etc/systemd/network/*.netdev \
                /etc/systemd/network/*.link 2>/dev/null || true
    sudo rm -f /etc/dhcpcd.conf 2>/dev/null || true
    sudo rm -rf /etc/netctl/* 2>/dev/null || true
    sudo rm -rf /etc/iwd/* 2>/dev/null || true
    sudo rm -f /etc/wpa_supplicant/*.conf 2>/dev/null || true

    sudo nmcli networking off 2>/dev/null || true
    sleep 1
    sudo nmcli networking on 2>/dev/null || true
    sudo systemctl restart NetworkManager.service || \
        die "NetworkManager não reiniciou."

    ok "Configuração operacional antiga removida e NM reiniciado."
}

configure_dns() {
    info "Configurando systemd-resolved."

    if ! command_exists resolvectl; then
        warn "resolvectl não disponível; usando DNS do NetworkManager."
        return 0
    fi

    sudo systemctl enable --now systemd-resolved.service || {
        warn "systemd-resolved não pôde iniciar."
        return 0
    }

    backup_path /etc/resolv.conf
    sudo rm -f /etc/resolv.conf
    sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    ok "DNS configurado via systemd-resolved."
}

get_physical_interfaces() {
    for d in /sys/class/net/*; do
        local iface
        iface="$(basename "$d")"
        case "$iface" in
            lo|virbr*|docker*|veth*|br-*|tun*|tap*|wg*) continue ;;
        esac
        [ -e "$d/device" ] || continue
        echo "$iface"
    done
}

is_wifi_interface() {
    [ -d "/sys/class/net/$1/wireless" ]
}

is_ethernet_interface() {
    local t
    t="$(cat "/sys/class/net/$1/type" 2>/dev/null || echo 0)"
    [ "$t" = "1" ] && ! is_wifi_interface "$1"
}

configure_ethernet() {
    local iface="$1"
    local name="Arco Auto Ethernet"

    sudo nmcli connection delete "$name" >/dev/null 2>&1 || true

    sudo nmcli connection add \
        type ethernet \
        ifname "$iface" \
        con-name "$name" \
        ipv4.method auto \
        ipv6.method auto \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        >/dev/null 2>&1 || return 1

    sudo nmcli connection up "$name" >/dev/null 2>&1 || return 1
    return 0
}

try_saved_wifi() {
    local con
    while IFS= read -r con; do
        [ -z "$con" ] && continue
        sudo nmcli connection up "$con" >/dev/null 2>&1 && return 0
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
             awk -F: '$2=="802-11-wireless"{print $1}')
    return 1
}

configure_wifi_interactive() {
    local iface="$1"
    local ssid password name="Arco Auto WiFi"

    sudo nmcli radio wifi on >/dev/null 2>&1 || true
    sudo nmcli device wifi rescan ifname "$iface" >/dev/null 2>&1 || true
    sleep 2

    echo
    echo "Redes Wi-Fi encontradas:"
    nmcli -f IN-USE,SSID,SIGNAL,SECURITY device wifi list \
        ifname "$iface" --rescan no 2>/dev/null | head -30 || true
    echo

    read -r -p "SSID Wi-Fi (Enter para pular): " ssid
    [ -n "$ssid" ] || return 1

    read -r -s -p "Senha Wi-Fi: " password
    echo

    sudo nmcli connection delete "$name" >/dev/null 2>&1 || true

    if sudo nmcli connection add \
        type wifi \
        ifname "$iface" \
        con-name "$name" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto \
        connection.autoconnect yes \
        connection.autoconnect-priority 90 \
        >/dev/null 2>&1 &&
       sudo nmcli connection up "$name" >/dev/null 2>&1; then
        unset password
        return 0
    fi

    unset password
    return 1
}

network_test() {
    local iface ipaddr gateway

    iface="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null |
             awk -F: '$2=="connected"{print $1; exit}')"
    [ -n "$iface" ] || return 1

    ipaddr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
              awk '{print $4; exit}')"
    [ -n "$ipaddr" ] || return 1

    gateway="$(ip route show default dev "$iface" 2>/dev/null |
               awk '/default/{print $3; exit}')"
    [ -n "$gateway" ] || return 1

    ping -c 1 -W 2 "$gateway" >/dev/null 2>&1 || return 1
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || return 1
    getent ahosts archlinux.org >/dev/null 2>&1 || return 1

    if command_exists curl; then
        curl -fsSIL --connect-timeout 4 --max-time 10 \
            https://archlinux.org/ >/dev/null 2>&1 || return 1
    fi

    return 0
}

network_summary() {
    local iface gateway ip dns_state

    iface="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null |
             awk -F: '$2=="connected"{print $1; exit}')"
    ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
         awk '{print $4; exit}')"
    gateway="$(ip route show default 2>/dev/null |
               awk '/default/{print $3; exit}')"

    if command_exists resolvectl; then
        dns_state="$(resolvectl status 2>/dev/null |
            awk '/Current DNS Server:/{print $NF; exit}')"
    fi
    [ -n "${dns_state:-}" ] || dns_state="NetworkManager/auto"

    echo "Interface : ${iface:-nenhuma}"
    echo "IPv4      : ${ip:-nenhum}"
    echo "Gateway   : ${gateway:-nenhum}"
    echo "DNS       : $dns_state"
}

recover_network() {
    echo
    echo "================================================================"
    echo "5/15 - RECUPERAÇÃO AUTOMÁTICA DA REDE"
    echo "================================================================"

    configure_dns

    local eth=() wifi=() iface

    while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        if is_wifi_interface "$iface"; then
            wifi+=("$iface")
        elif is_ethernet_interface "$iface"; then
            eth+=("$iface")
        fi
    done < <(get_physical_interfaces)

    info "Ethernet: ${eth[*]:-nenhuma}"
    info "Wi-Fi: ${wifi[*]:-nenhuma}"

    # 1. Ethernet.
    for iface in "${eth[@]}"; do
        ip link set "$iface" up >/dev/null 2>&1 || true
        if configure_ethernet "$iface" && network_test; then
            ok "Internet restaurada pela Ethernet."
            network_summary
            return 0
        fi
    done

    # 2. Wi-Fi salvo.
    for iface in "${wifi[@]}"; do
        ip link set "$iface" up >/dev/null 2>&1 || true
        if try_saved_wifi && network_test; then
            ok "Internet restaurada pelo Wi-Fi salvo."
            network_summary
            return 0
        fi
    done

    # 3. Wi-Fi interativo.
    for iface in "${wifi[@]}"; do
        if configure_wifi_interactive "$iface" && network_test; then
            ok "Internet restaurada pelo Wi-Fi."
            network_summary
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# INSTALAÇÃO DO SISTEMA
# ---------------------------------------------------------------------------

update_system() {
    echo
    echo "================================================================"
    echo "6/15 - ATUALIZAÇÃO DO ARCH"
    echo "================================================================"

    sudo pacman -Syu --noconfirm || die "Atualização do Arch falhou."
    ok "Sistema atualizado."
}

install_base_desktop() {
    echo
    echo "================================================================"
    echo "7/15 - GNOME E DESKTOP"
    echo "================================================================"

    local pkgs=(
        gnome
        gnome-extra
        gdm
        networkmanager
        network-manager-applet
        nm-connection-editor
        polkit
        gnome-keyring
        gnome-settings-daemon
        gvfs
        gvfs-mtp
        gvfs-smb
        xdg-user-dirs
        xdg-utils
        file-roller
        p7zip
        unzip
        curl
        wget
        git
        rsync
        base-devel
    )

    if [ "$MINIMAL" -eq 0 ]; then
        pkgs+=(
            firefox
            gnome-disk-utility
            gnome-system-monitor
            gnome-text-editor
            loupe
            baobab
            evince
            simple-scan
            cups
            cups-pk-helper
            avahi
            nss-mdns
        )
    fi

    sudo pacman -S --needed --noconfirm "${pkgs[@]}" || \
        die "Falha no desktop GNOME."

    sudo systemctl enable gdm.service
    sudo systemctl enable --now NetworkManager.service

    systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1 &&
        sudo systemctl enable --now avahi-daemon.service 2>/dev/null || true

    ok "GNOME instalado."
}

configure_desktop() {
    echo
    echo "================================================================"
    echo "8/15 - GNOME, KEYRING E POLKIT"
    echo "================================================================"

    sudo systemctl enable gdm.service

    if command_exists xdg-user-dirs-update; then
        sudo -u "$REAL_USER" xdg-user-dirs-update >/dev/null 2>&1 || true
    fi

    # Não desabilitamos polkit.
    # Não gravamos senha do usuário para desbloquear keyring automaticamente.
    # Isso evita transformar "corrigir prompt" em uma vulnerabilidade.
    ok "GNOME configurado preservando polkit e GNOME Keyring."
}

install_hardware() {
    echo
    echo "================================================================"
    echo "9/15 - HARDWARE, FIRMWARE, ÁUDIO E BLUETOOTH"
    echo "================================================================"

    sudo pacman -S --needed --noconfirm \
        linux-firmware \
        sof-firmware \
        alsa-utils \
        pipewire \
        pipewire-alsa \
        pipewire-pulse \
        wireplumber \
        bluez \
        bluez-utils || die "Falha no suporte de hardware."

    sudo systemctl enable --now bluetooth.service 2>/dev/null || true

    if lspci 2>/dev/null | grep -qi NVIDIA; then
        sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils 2>/dev/null || \
            warn "NVIDIA detectada, mas o driver nvidia-open não pôde ser instalado automaticamente."
    fi

    if lspci 2>/dev/null | grep -Eqi 'AMD.*VGA|AMD.*Display|ATI.*VGA'; then
        sudo pacman -S --needed --noconfirm \
            mesa vulkan-radeon libva-mesa-driver 2>/dev/null || true
    fi

    if lspci 2>/dev/null | grep -Eqi 'Intel.*VGA|Intel.*Display'; then
        sudo pacman -S --needed --noconfirm \
            mesa vulkan-intel intel-media-driver 2>/dev/null || true
    fi

    ok "Hardware configurado."
}

# ---------------------------------------------------------------------------
# VIRTUALIZAÇÃO
# ---------------------------------------------------------------------------

ipv4_networks_in_use() {
    ip -4 -o addr show scope global 2>/dev/null |
        awk '{print $4}' |
        while read -r cidr; do
            python - "$cidr" <<'PY' 2>/dev/null || true
import ipaddress, sys
try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except Exception:
    pass
PY
        done
}

network_conflicts_with_host() {
    local candidate="$1" n
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        python - "$candidate" "$n" <<'PY' >/dev/null 2>&1
import ipaddress, sys
a=ipaddress.ip_network(sys.argv[1], strict=False)
b=ipaddress.ip_network(sys.argv[2], strict=False)
raise SystemExit(0 if a.overlaps(b) else 1)
PY
        [ "$?" -eq 0 ] && return 0
    done < <(ipv4_networks_in_use)
    return 1
}

choose_libvirt_subnet() {
    local candidates=(
        10.88.0.0/24
        10.89.0.0/24
        10.90.0.0/24
        10.91.0.0/24
        10.92.0.0/24
        172.30.0.0/24
        172.31.0.0/24
        192.168.250.0/24
        192.168.251.0/24
    )
    local c
    for c in "${candidates[@]}"; do
        if ! network_conflicts_with_host "$c"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

configure_libvirt_network() {
    command_exists virsh || return 0

    sudo systemctl start libvirtd.service 2>/dev/null || {
        warn "libvirtd não iniciou."
        return 0
    }

    local subnet gateway dhcp_start dhcp_end netaddr
    subnet="$(choose_libvirt_subnet || true)"

    [ -n "$subnet" ] || {
        warn "Nenhuma sub-rede libvirt segura foi encontrada."
        return 0
    }

    netaddr="${subnet%/*}"
    gateway="$(python - "$netaddr" <<'PY'
import ipaddress,sys
print(ipaddress.ip_network(sys.argv[1]+'/24', strict=False).network_address + 1)
PY
)"
    dhcp_start="$(python - "$netaddr" <<'PY'
import ipaddress,sys
print(ipaddress.ip_network(sys.argv[1]+'/24', strict=False).network_address + 2)
PY
)"
    dhcp_end="$(python - "$netaddr" <<'PY'
import ipaddress,sys
print(ipaddress.ip_network(sys.argv[1]+'/24', strict=False).network_address + 254)
PY
)"

    sudo virsh net-destroy default >/dev/null 2>&1 || true
    sudo virsh net-undefine default >/dev/null 2>&1 || true

    sudo tee /tmp/arco-libvirt-default.xml >/dev/null <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='$gateway' netmask='255.255.255.0'>
    <dhcp>
      <range start='$dhcp_start' end='$dhcp_end'/>
    </dhcp>
  </ip>
</network>
EOF

    if sudo virsh net-define /tmp/arco-libvirt-default.xml >/dev/null 2>&1; then
        sudo virsh net-autostart default >/dev/null 2>&1 || true
        sudo virsh net-start default >/dev/null 2>&1 || true
        info "Rede libvirt criada em $subnet."
    else
        warn "Falha ao definir rede libvirt."
    fi

    rm -f /tmp/arco-libvirt-default.xml
}

install_virtualization() {
    echo
    echo "================================================================"
    echo "10/15 - QEMU, LIBVIRT, GNOME BOXES E SPICE"
    echo "================================================================"

    if [ "$SKIP_VIRTUALIZATION" -eq 1 ] || [ "$MINIMAL" -eq 1 ]; then
        info "Virtualização ignorada."
        return 0
    fi

    sudo pacman -S --needed --noconfirm \
        qemu-desktop \
        qemu-img \
        libvirt \
        virt-manager \
        virt-viewer \
        virt-install \
        gnome-boxes \
        spice-gtk \
        spice-protocol \
        spice-vdagent \
        qemu-guest-agent \
        usbredir \
        virtiofsd \
        edk2-ovmf \
        swtpm || die "Falha na pilha de virtualização."

    sudo systemctl enable libvirtd.service 2>/dev/null || true
    sudo systemctl enable --now virtlogd.socket 2>/dev/null || true
    sudo usermod -aG libvirt "$REAL_USER" 2>/dev/null || true
    sudo systemctl enable qemu-guest-agent.service 2>/dev/null || true

    configure_libvirt_network

    ok "Virtualização instalada."
}

# ---------------------------------------------------------------------------
# FONTES
# ---------------------------------------------------------------------------

install_microsoft_core_fonts() {
    pacman -Q ttf-ms-fonts >/dev/null 2>&1 && {
        ok "Microsoft Core Fonts já instaladas."
        return 0
    }

    [ "$SKIP_AUR" -eq 0 ] || return 0
    command_exists git && command_exists makepkg || {
        warn "Ferramentas AUR indisponíveis para ttf-ms-fonts."
        return 0
    }

    local build="$STATE_DIR/build/ttf-ms-fonts"
    sudo mkdir -p "$STATE_DIR/build"
    sudo chown -R "$REAL_USER:$REAL_USER" "$STATE_DIR/build"
    rm -rf "$build"

    info "Instalando ttf-ms-fonts a partir do AUR."
    sudo -u "$REAL_USER" git clone --depth=1 \
        https://aur.archlinux.org/ttf-ms-fonts.git "$build" >/dev/null 2>&1 || {
        warn "Não foi possível obter ttf-ms-fonts."
        return 0
    }

    sudo -u "$REAL_USER" bash -c \
        "cd '$build' && makepkg -si --noconfirm" || {
        warn "Falha no ttf-ms-fonts."
        return 0
    }

    ok "Microsoft Core Fonts instaladas."
}

install_fonts() {
    echo
    echo "================================================================"
    echo "11/15 - FONTES"
    echo "================================================================"

    [ "$SKIP_FONTS" -eq 0 ] || {
        info "Fontes ignoradas."
        return 0
    }

    sudo pacman -S --needed --noconfirm \
        fontconfig \
        freetype2 \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji \
        ttf-dejavu \
        ttf-liberation \
        ttf-croscore \
        ttf-carlito \
        ttf-caladea || die "Falha nas fontes."

    install_microsoft_core_fonts
    sudo fc-cache -f >/dev/null 2>&1 || true

    ok "Fontes configuradas."
}

configure_flatpak() {
    echo
    echo "================================================================"
    echo "12/15 - FLATPAK"
    echo "================================================================"

    [ "$SKIP_FLATPAK" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || {
        info "Flatpak ignorado."
        return 0
    }

    sudo pacman -S --needed --noconfirm flatpak || {
        warn "Flatpak não pôde ser instalado."
        return 0
    }

    sudo -u "$REAL_USER" flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo || true

    ok "Flatpak configurado."
}

configure_firewall() {
    echo
    echo "================================================================"
    echo "13/15 - FIREWALL"
    echo "================================================================"

    [ "$NO_FIREWALL" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || {
        info "Firewall ignorado."
        return 0
    }

    sudo pacman -S --needed --noconfirm firewalld || {
        warn "firewalld não pôde ser instalado."
        return 0
    }

    sudo systemctl enable --now firewalld.service || {
        warn "firewalld não iniciou."
        return 0
    }

    ok "firewalld habilitado."
}

# ---------------------------------------------------------------------------
# NETWORK GUARD PERMANENTE
# ---------------------------------------------------------------------------

install_network_guard() {
    echo
    echo "================================================================"
    echo "14/15 - INSTALAÇÃO DO ARCO NETWORK GUARD"
    echo "================================================================"

    local guard="/usr/local/libexec/arco-network-guard"

    sudo mkdir -p /usr/local/libexec "$STATE_DIR/network" "$LOG_DIR"

    sudo tee "$guard" >/dev/null <<'GUARD'
#!/usr/bin/env bash
#
# Arco Network Guard
# Executado no boot e manualmente.
#
# Regra principal:
#   REDE OK -> não altera configuração.
#   REDE COM PROBLEMA -> reparo progressivo.
#   Somente reconstrução completa quando necessário.
#

set -u

STATE_DIR="/var/lib/arco-linux/network"
LOG_FILE="/var/log/arco-linux/network-guard.log"
LOCK_FILE="/run/arco-network-guard.lock"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*"; }

usage() {
    cat <<EOF
Arco Network Guard

Uso:
  sudo arco-network-guard --status
  sudo arco-network-guard --check
  sudo arco-network-guard --repair
  sudo arco-network-guard --rebuild
  sudo arco-network-guard --boot

Modos:
  --status    mostra estado sem modificar rede
  --check     testa a rede sem modificar configuração
  --repair    tenta reparos progressivos
  --rebuild   reconstrução completa
  --boot      modo usado pelo systemd
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || {
        echo "Execute como root." >&2
        exit 1
    }
}

lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
}

nm_ready() {
    command -v nmcli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet NetworkManager.service 2>/dev/null || return 1
    nmcli general status >/dev/null 2>&1 || return 1
}

physical_interfaces() {
    for d in /sys/class/net/*; do
        local iface
        iface="$(basename "$d")"
        case "$iface" in
            lo|virbr*|docker*|veth*|br-*|tun*|tap*|wg*) continue ;;
        esac
        [ -e "$d/device" ] || continue
        echo "$iface"
    done
}

is_wifi() {
    [ -d "/sys/class/net/$1/wireless" ]
}

is_eth() {
    local t
    t="$(cat "/sys/class/net/$1/type" 2>/dev/null || echo 0)"
    [ "$t" = "1" ] && ! is_wifi "$1"
}

active_interface() {
    nmcli -t -f DEVICE,STATE device status 2>/dev/null |
        awk -F: '$2=="connected"{print $1; exit}'
}

network_ok() {
    local iface gateway ip

    nm_ready || return 1

    iface="$(active_interface)"
    [ -n "$iface" ] || return 1

    ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
          awk '{print $4; exit}')"
    [ -n "$ip" ] || return 1

    gateway="$(ip route show default dev "$iface" 2>/dev/null |
               awk '/default/{print $3; exit}')"
    [ -n "$gateway" ] || return 1

    ping -c 1 -W 2 "$gateway" >/dev/null 2>&1 || return 1
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || return 1
    getent ahosts archlinux.org >/dev/null 2>&1 || return 1

    if command -v curl >/dev/null 2>&1; then
        curl -fsSIL --connect-timeout 4 --max-time 10 \
            https://archlinux.org/ >/dev/null 2>&1 || return 1
    fi

    return 0
}

status() {
    echo "ARCO NETWORK GUARD"
    echo
    echo "NetworkManager:"
    systemctl is-active NetworkManager.service 2>/dev/null || true
    echo
    echo "Dispositivos:"
    nmcli device status 2>/dev/null || true
    echo
    echo "Endereços:"
    ip -br addr 2>/dev/null || true
    echo
    echo "Rotas:"
    ip route 2>/dev/null || true
    echo
    echo "DNS:"
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status 2>/dev/null | head -60 || true
    else
        cat /etc/resolv.conf 2>/dev/null || true
    fi
    echo
    if network_ok; then
        echo "RESULTADO: INTERNET OK"
        echo "Estado: healthy" > "$STATE_DIR/state"
        return 0
    fi
    echo "RESULTADO: INTERNET COM PROBLEMA"
    echo "Estado: degraded" > "$STATE_DIR/state"
    return 1
}

ensure_dns() {
    command -v resolvectl >/dev/null 2>&1 || return 0

    systemctl is-active --quiet systemd-resolved.service 2>/dev/null ||
        systemctl start systemd-resolved.service 2>/dev/null || true

    if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
        if [ ! -L /etc/resolv.conf ] ||
           [ "$(readlink -f /etc/resolv.conf 2>/dev/null)" != \
             "/run/systemd/resolve/stub-resolv.conf" ]; then
            cp -a /etc/resolv.conf \
                "$STATE_DIR/resolv.conf.$(date +%s).bak" 2>/dev/null || true
            rm -f /etc/resolv.conf
            ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        fi
    fi
}

try_existing_connections() {
    local con
    while IFS= read -r con; do
        [ -z "$con" ] && continue
        nmcli connection up "$con" >/dev/null 2>&1 && {
            sleep 2
            network_ok && return 0
        }
    done < <(nmcli -t -f NAME connection show 2>/dev/null)
    return 1
}

try_ethernet() {
    local iface name="Arco Auto Ethernet"

    while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        is_eth "$iface" || continue

        ip link set "$iface" up >/dev/null 2>&1 || true
        nmcli connection up "$name" >/dev/null 2>&1 || {
            nmcli connection add \
                type ethernet \
                ifname "$iface" \
                con-name "$name" \
                ipv4.method auto \
                ipv6.method auto \
                connection.autoconnect yes \
                connection.autoconnect-priority 100 \
                >/dev/null 2>&1 || continue
            nmcli connection up "$name" >/dev/null 2>&1 || continue
        }

        sleep 2
        network_ok && return 0
    done < <(physical_interfaces)

    return 1
}

try_saved_wifi() {
    local iface con

    nmcli radio wifi on >/dev/null 2>&1 || true

    while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        is_wifi "$iface" || continue
        ip link set "$iface" up >/dev/null 2>&1 || true

        while IFS= read -r con; do
            [ -z "$con" ] && continue
            nmcli connection up "$con" ifname "$iface" >/dev/null 2>&1 || continue
            sleep 3
            network_ok && return 0
        done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null |
                 awk -F: '$2=="802-11-wireless"{print $1}')
    done < <(physical_interfaces)

    return 1
}

save_last_good_state() {
    local iface ip gateway
    iface="$(active_interface)"
    ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
         awk '{print $4; exit}')"
    gateway="$(ip route show default 2>/dev/null |
               awk '/default/{print $3; exit}')"

    printf '%s\n' "$iface" > "$STATE_DIR/last-good-interface"
    printf '%s\n' "$ip" > "$STATE_DIR/last-good-ip"
    printf '%s\n' "$gateway" > "$STATE_DIR/last-good-gateway"
    date '+%s' > "$STATE_DIR/last-good-time"
    echo "healthy" > "$STATE_DIR/state"
}

repair_progressive() {
    log "Iniciando diagnóstico/reparo."

    if network_ok; then
        log "Rede já está saudável. Nenhuma alteração será feita."
        save_last_good_state
        return 0
    fi

    # Reparos leves primeiro.
    systemctl restart NetworkManager.service 2>/dev/null || true
    sleep 3
    ensure_dns

    if network_ok; then
        log "Rede recuperada após reinício do NetworkManager."
        save_last_good_state
        return 0
    fi

    # Tenta conexões existentes.
    if try_existing_connections; then
        log "Rede recuperada usando conexão existente."
        save_last_good_state
        return 0
    fi

    # Tenta Ethernet.
    if try_ethernet; then
        log "Rede recuperada pela Ethernet."
        save_last_good_state
        return 0
    fi

    # Tenta Wi-Fi salvo.
    if try_saved_wifi; then
        log "Rede recuperada pelo Wi-Fi salvo."
        save_last_good_state
        return 0
    fi

    log "Reparos progressivos falharam."
    echo "degraded" > "$STATE_DIR/state"
    return 1
}

backup_network() {
    local root="$STATE_DIR/recovery-backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$root"

    cp -a /etc/NetworkManager "$root/" 2>/dev/null || true
    cp -a /etc/systemd/network "$root/" 2>/dev/null || true
    cp -a /etc/resolv.conf "$root/" 2>/dev/null || true
    cp -a /etc/systemd/resolved.conf "$root/" 2>/dev/null || true
    cp -a /etc/dhcpcd.conf "$root/" 2>/dev/null || true
    cp -a /etc/netctl "$root/" 2>/dev/null || true
    cp -a /etc/iwd "$root/" 2>/dev/null || true

    echo "$root" > "$STATE_DIR/last-recovery-backup"
    log "Backup da recuperação: $root"
}

full_rebuild() {
    log "INICIANDO RECONSTRUÇÃO COMPLETA."

    backup_network

    systemctl stop libvirtd.service 2>/dev/null || true

    # Não apagamos arquivos pessoais. Somente configuração de rede.
    rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true
    mkdir -p /etc/NetworkManager/system-connections
    chmod 700 /etc/NetworkManager/system-connections

    rm -f /etc/systemd/network/*.network \
          /etc/systemd/network/*.netdev \
          /etc/systemd/network/*.link 2>/dev/null || true

    rm -f /etc/dhcpcd.conf 2>/dev/null || true
    rm -rf /etc/netctl/* 2>/dev/null || true
    rm -rf /etc/iwd/* 2>/dev/null || true
    rm -f /etc/wpa_supplicant/*.conf 2>/dev/null || true

    systemctl enable NetworkManager.service 2>/dev/null || true
    systemctl restart NetworkManager.service || return 1
    sleep 2

    ensure_dns

    if try_ethernet; then
        save_last_good_state
        log "Reconstrução completa concluída pela Ethernet."
        return 0
    fi

    if try_saved_wifi; then
        save_last_good_state
        log "Reconstrução completa concluída pelo Wi-Fi salvo."
        return 0
    fi

    log "Reconstrução completa terminou sem Internet."
    echo "degraded" > "$STATE_DIR/state"
    return 1
}

boot_mode() {
    # Espera o NetworkManager, mas não exige network-online.
    systemctl start NetworkManager.service 2>/dev/null || true

    local i
    for i in {1..15}; do
        nm_ready && break
        sleep 1
    done

    if network_ok; then
        log "BOOT: rede saudável. Nenhuma alteração."
        save_last_good_state
        return 0
    fi

    repair_progressive || {
        log "BOOT: reparos leves falharam. Tentando reconstrução."
        full_rebuild || log "BOOT: recuperação automática não conseguiu Internet."
    }

    return 0
}

main() {
    require_root
    lock

    case "${1:---boot}" in
        --status)
            status
            ;;
        --check)
            network_ok && echo "REDE OK" || {
                echo "REDE COM PROBLEMA"
                exit 1
            }
            ;;
        --repair)
            repair_progressive
            ;;
        --rebuild)
            full_rebuild
            ;;
        --boot)
            boot_mode
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
GUARD

    sudo chmod 755 "$guard"

    sudo tee /etc/systemd/system/arco-network-guard.service >/dev/null <<'SERVICE'
[Unit]
Description=Arco Linux Network Guard
Documentation=man:arco-network-guard
After=NetworkManager.service systemd-resolved.service
Wants=NetworkManager.service systemd-resolved.service
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/arco-network-guard --boot
RemainAfterExit=yes
TimeoutStartSec=90
Restart=no

[Install]
WantedBy=multi-user.target
SERVICE

    sudo chmod 644 /etc/systemd/system/arco-network-guard.service

    # Wrapper amigável.
    sudo tee /usr/local/bin/arco-network-guard >/dev/null <<'WRAPPER'
#!/usr/bin/env bash
exec /usr/local/libexec/arco-network-guard "$@"
WRAPPER
    sudo chmod 755 /usr/local/bin/arco-network-guard

    sudo systemctl daemon-reload
    sudo systemctl enable arco-network-guard.service

    ok "Arco Network Guard instalado e habilitado no boot."
}

final_validation() {
    echo
    echo "================================================================"
    echo "15/15 - VALIDAÇÃO FINAL"
    echo "================================================================"

    echo
    echo "--- rede ---"
    network_summary
    echo

    if ! network_test; then
        die "A validação final da Internet falhou."
    fi

    echo
    echo "--- Network Guard ---"
    sudo systemctl is-enabled arco-network-guard.service
    sudo systemctl status arco-network-guard.service --no-pager \
        -l 2>/dev/null | head -30 || true

    echo
    echo "--- libvirt ---"
    command_exists virsh && sudo virsh net-list --all 2>/dev/null || true

    echo
    echo "================================================================"
    echo "ARCO LINUX: INSTALAÇÃO CONCLUÍDA"
    echo "================================================================"
    echo
    echo "Internet:       OK"
    echo "DNS:            OK"
    echo "Network Guard:  habilitado no boot"
    echo "Log instalação: $LOG_FILE"
    echo "Backups:        $BACKUP_ROOT"
    echo
    echo "Comandos úteis:"
    echo "  sudo arco-network-guard --status"
    echo "  sudo arco-network-guard --check"
    echo "  sudo arco-network-guard --repair"
    echo "  sudo arco-network-guard --rebuild"
    echo "  sudo systemctl status arco-network-guard"
    echo
    echo "O Guard NÃO reconstrói a rede quando ela está funcionando."
    echo "Ele só altera a configuração quando os testes de conectividade falham."
    echo
    echo "Se este Arch estiver rodando como guest KVM/QEMU:"
    echo "  - qemu-guest-agent foi preparado."
    echo "  - spice-vdagent foi instalado."
    echo "  - clipboard/redimensionamento dependem da VM usar SPICE."
}

main() {
    [ "$(id -u)" -ne 0 ] || die "Execute como usuário normal; o script usa sudo."
    [ -f /etc/arch-release ] || die "Este script é para Arch Linux."
    command_exists sudo || die "sudo não está instalado."
    sudo -v || die "Não foi possível autenticar sudo."

    detect_environment
    install_network_prerequisites
    stop_conflicting_network_managers
    rebuild_network_configuration
    recover_network || die "Não foi possível estabelecer Internet."
    update_system
    install_base_desktop
    configure_desktop
    install_hardware
    install_virtualization
    install_fonts
    configure_flatpak
    configure_firewall
    install_network_guard
    final_validation
}

main "$@"
