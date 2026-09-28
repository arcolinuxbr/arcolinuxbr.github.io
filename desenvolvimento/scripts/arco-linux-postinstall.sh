#!/usr/bin/env bash
#
# ARCO LINUX BR - POST-INSTALL
# "Arch que instala, conecta, usa e se recupera"
# v3.6.1 - EXPERIÊNCIA DOMÉSTICA COMPLETA + SNAP OFICIAL
#
# Inclui:
# - Rede robusta + Network Guard
# - GNOME completo + extensões (Dash-to-Dock, Dash-to-Panel, AppIndicator, User Theme)
# - Codecs multimídia (VLC, Rhythmbox, GStreamer completo, VA-API)
# - LibreOffice, Thunderbird, Firefox, Wine
# - CUPS + SANE + Polkit (impressoras sem pedir senha)
# - Samba com pastas Públicas guest
# - Flatpak + Extension Manager
# - Snapd + Snap Store (oficial)  ← instalado por padrão
# - Temas Win11 + Yaru + Papirus
# - Fontes Microsoft + Noto
#
# Uso:
#   chmod +x arco-linux-postinstall.sh
#   ./arco-linux-postinstall.sh
#
# Opções:
#   --skip-aur
#   --skip-virtualization
#   --skip-fonts
#   --skip-flatpak
#   --no-firewall
#   --minimal
#

set -u
set -o pipefail

VERSION="3.6.1"
SCRIPT_NAME="$(basename "$0")"
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"

STATE_DIR="/var/lib/arco-linux"
RUN_BACKUP="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log/arco-linux"
LOG_FILE="$LOG_DIR/postinstall-$(date +%Y%m%d-%H%M%S).log"

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
            cat <<HELP
Uso: $SCRIPT_NAME [opções]

  --skip-aur              não instalar pacotes AUR
  --skip-virtualization   não instalar QEMU/libvirt/GNOME Boxes
  --skip-fonts            não instalar fontes adicionais
  --skip-flatpak          não instalar Flatpak/Flathub
  --no-firewall           não instalar/habilitar firewalld
  --minimal               omitir recursos opcionais

Após a instalação:
  sudo arco-network-guard --status
  sudo arco-network-guard --repair
  sudo arco-network-guard --rebuild
HELP
            exit 0
            ;;
        *)
            echo "Opção desconhecida: $arg" >&2
            exit 2
            ;;
    esac
done

sudo mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUN_BACKUP"
sudo touch "$LOG_FILE"
sudo chown "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_FILE"
sudo chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

PS4='\n[EXEC] ${BASH_SOURCE##*/}:${LINENO}: '
set -x

OK=0
WARN=0
FAIL=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; WARN=$((WARN+1)); }
ok()   { printf '[OK] %s\n' "$*"; OK=$((OK+1)); }
fail() { printf '[ERRO] %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
die()  { fail "$*"; echo "Log: $LOG_FILE"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

backup_item() {
    local src="$1" rel dst
    rel="${src#/}"
    dst="$RUN_BACKUP/$rel"
    if [ -e "$src" ] || [ -L "$src" ]; then
        sudo mkdir -p "$(dirname "$dst")"
        sudo cp -a "$src" "$dst" 2>/dev/null || true
    fi
}

replace_file() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    sudo install -D -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 1. DETECÇÃO
# ---------------------------------------------------------------------------

detect_environment() {
    echo
    echo "================================================================"
    echo "1/20 - DETECÇÃO DO AMBIENTE"
    echo "================================================================"

    local virt firmware kvm
    virt="none"
    firmware="BIOS/Legacy"
    kvm="não"
    command_exists systemd-detect-virt && virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    [ -d /sys/firmware/efi ] && firmware="UEFI"
    [ -e /dev/kvm ] && kvm="sim"

    echo "Arco Linux BR post-install v$VERSION"
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
    echo
    ok "Detecção concluída."
}

# ---------------------------------------------------------------------------
# 2. REDE - PRÉ-REQUISITOS
# ---------------------------------------------------------------------------

install_network_prerequisites() {
    echo
    echo "================================================================"
    echo "2/20 - PRÉ-REQUISITOS DE REDE"
    echo "================================================================"

    local pkgs=(
        networkmanager network-manager-applet nm-connection-editor
        wireless-regdb wpa_supplicant curl python iputils
    )
    info "PACMAN: instalando pré-requisitos de rede."
    sudo pacman -S --needed --noconfirm "${pkgs[@]}" || die "Não foi possível instalar a pilha de rede."

    sudo systemctl unmask NetworkManager.service || true
    sudo systemctl enable NetworkManager.service || true
    command_exists nmcli || die "nmcli não ficou disponível."
    command_exists curl || die "curl não ficou disponível."
    command_exists python || die "python não ficou disponível."
    command_exists ping || die "ping não ficou disponível."
    ok "NetworkManager e pré-requisitos de rede disponíveis."
}

backup_network_config() {
    info "Salvando configuração de rede anterior."
    backup_item /etc/NetworkManager
    backup_item /etc/systemd/network
    backup_item /etc/systemd/resolved.conf
    backup_item /etc/resolv.conf
    backup_item /etc/dhcpcd.conf
    backup_item /etc/netctl
    backup_item /etc/iwd
    backup_item /etc/wpa_supplicant
}

stop_conflicting_managers() {
    local services=(
        systemd-networkd.service
        systemd-networkd-wait-online.service
        dhcpcd.service
        connman.service
        netctl.service
        iwd.service
        wpa_supplicant.service
    )
    local svc
    for svc in "${services[@]}"; do
        sudo systemctl disable --now "$svc" || true
    done
    sudo systemctl enable --now NetworkManager.service || die "NetworkManager não iniciou."
}

write_resolved_config() {
    backup_item /etc/systemd/resolved.conf
    replace_file /etc/systemd/resolved.conf 0644 <<'CONF'
# Arco Linux BR - configuração recriada pelo post-install
[Resolve]
DNS=
FallbackDNS=1.1.1.1 9.9.9.9
Domains=
DNSSEC=allow-downgrade
DNSOverTLS=no
MulticastDNS=no
LLMNR=no
Cache=yes
DNSStubListener=yes
CONF

    sudo systemctl enable --now systemd-resolved.service || die "systemd-resolved não iniciou."
    sudo rm -f /etc/resolv.conf
    sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

write_networkmanager_config() {
    backup_item /etc/NetworkManager/NetworkManager.conf
    replace_file /etc/NetworkManager/NetworkManager.conf 0644 <<'CONF'
# Arco Linux BR - configuração recriada pelo post-install
[main]
plugins=keyfile
rc-manager=symlink
dns=systemd

[device]
wifi.scan-rand-mac-address=yes

[connection]
connection.mdns=2
connection.llmnr=0
CONF

    sudo rm -rf /etc/NetworkManager/system-connections
    sudo mkdir -p /etc/NetworkManager/system-connections
    sudo chmod 700 /etc/NetworkManager/system-connections
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

is_wifi() { [ -d "/sys/class/net/$1/wireless" ]; }

is_ethernet() {
    local type
    type="$(cat "/sys/class/net/$1/type" 2>/dev/null || echo 0)"
    [ "$type" = "1" ] && ! is_wifi "$1"
}

network_test() {
    local iface gateway ipaddr
    iface="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected" && $1!="lo" {print $1; exit}')"
    [ -n "$iface" ] || return 1
    ipaddr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
    [ -n "$ipaddr" ] || return 1
    gateway="$(ip route show default dev "$iface" 2>/dev/null | awk '/default/{print $3; exit}')"
    [ -n "$gateway" ] || return 1
    ping -c 1 -W 2 "$gateway" >/dev/null 2>&1 || return 1
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || return 1
    getent ahosts archlinux.org >/dev/null 2>&1 || return 1
    curl -fsSIL --connect-timeout 4 --max-time 10 https://archlinux.org/ >/dev/null 2>&1 || return 1
    return 0
}

create_ethernet_profile() {
    local iface="$1" name="Arco Ethernet - $iface"
    sudo nmcli connection delete "$name" || true
    sudo nmcli connection add type ethernet ifname "$iface" con-name "$name" \
        ipv4.method auto ipv6.method auto \
        connection.autoconnect yes connection.autoconnect-priority 100
    sudo nmcli connection up "$name"
}

saved_wifi_from_backup() {
    local dir="$RUN_BACKUP/etc/NetworkManager/system-connections"
    [ -d "$dir" ] || return 1
    find "$dir" -maxdepth 1 -type f -name '*.nmconnection' -print 2>/dev/null
}

restore_saved_wifi_profiles() {
    local f name
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        sudo cp -a "$f" "/etc/NetworkManager/system-connections/$name"
        sudo chmod 600 "/etc/NetworkManager/system-connections/$name"
    done < <(saved_wifi_from_backup)
}

wifi_interactive_if_needed() {
    local iface ssid password name
    for iface in $(physical_interfaces); do
        is_wifi "$iface" || continue
        sudo nmcli radio wifi on || true
        sudo nmcli device wifi rescan ifname "$iface" || true
        sleep 2
        echo
        echo "Wi-Fi disponível em $iface:"
        nmcli -f SSID,SIGNAL,SECURITY device wifi list ifname "$iface" --rescan no 2>/dev/null | head -25 || true
        echo
        read -r -p "SSID Wi-Fi (Enter para manter somente perfis salvos/pular): " ssid
        [ -n "$ssid" ] || continue
        set +x
        read -r -s -p "Senha Wi-Fi: " password
        echo
        name="Arco WiFi - $ssid"
        sudo nmcli connection delete "$name" || true
        if sudo nmcli connection add type wifi ifname "$iface" con-name "$name" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" \
            ipv4.method auto ipv6.method auto \
            connection.autoconnect yes connection.autoconnect-priority 90 >/dev/null 2>&1; then
            sudo nmcli connection up "$name" || true
        fi
        unset password
        set -x
        network_test && return 0
    done
    return 1
}

rebuild_network() {
    echo
    echo "================================================================"
    echo "3/20 - RECONSTRUÇÃO LIMPA DA REDE"
    echo "================================================================"

    backup_network_config
    stop_conflicting_managers

    sudo rm -rf /etc/systemd/network
    sudo mkdir -p /etc/systemd/network
    sudo rm -rf /etc/dhcpcd.conf /etc/netctl /etc/iwd /etc/wpa_supplicant
    sudo mkdir -p /etc/wpa_supplicant
    write_resolved_config
    write_networkmanager_config

    sudo systemctl restart NetworkManager.service || die "NetworkManager não reiniciou."
    sleep 2

    local iface
    for iface in $(physical_interfaces); do
        is_ethernet "$iface" || continue
        ip link set "$iface" up >/dev/null 2>&1 || true
        if create_ethernet_profile "$iface" && network_test; then
            ok "Internet restabelecida pela Ethernet ($iface)."
            return 0
        fi
    done

    restore_saved_wifi_profiles
    sudo nmcli connection reload || true
    for iface in $(physical_interfaces); do
        is_wifi "$iface" || continue
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            sudo nmcli connection up "$name" ifname "$iface" || continue
            sleep 3
            if network_test; then
                ok "Internet restabelecida usando Wi-Fi salvo ($name)."
                return 0
            fi
        done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')
    done

    if wifi_interactive_if_needed; then
        ok "Internet restabelecida pelo Wi-Fi informado."
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# 4. ATUALIZAÇÃO
# ---------------------------------------------------------------------------

update_system() {
    echo
    echo "================================================================"
    echo "4/20 - ATUALIZAÇÃO DO ARCH"
    echo "================================================================"
    info "PACMAN: atualização completa do sistema."
    sudo pacman -Syu --noconfirm || die "Atualização do Arch falhou."
    ok "Arch atualizado."
}

# ---------------------------------------------------------------------------
# 5. GNOME + SOFTWARE CENTER
# ---------------------------------------------------------------------------

install_gnome() {
    echo
    echo "================================================================"
    echo "5/20 - GNOME E SOFTWARE CENTER"
    echo "================================================================"

    local pkgs=(
        gnome gnome-extra gdm
        networkmanager network-manager-applet nm-connection-editor
        polkit gnome-keyring libsecret seahorse
        gnome-software appstream archlinux-appstream-data packagekit
        gvfs gvfs-mtp gvfs-smb gvfs-dnssd gvfs-wsdd
        xdg-user-dirs xdg-utils
        curl wget git rsync python
        file-roller 7zip unzip unrar
        firefox gnome-disk-utility gnome-system-monitor gnome-text-editor
        loupe baobab evince simple-scan
    )

    info "PACMAN: instalando GNOME e componentes."
    sudo pacman -S --needed --noconfirm "${pkgs[@]}" || die "Falha na instalação do GNOME."
    sudo systemctl enable gdm.service
    sudo systemctl enable --now NetworkManager.service
    ok "GNOME instalado."
}

configure_gnome_keyring() {
    echo
    echo "================================================================"
    echo "6/20 - GNOME KEYRING / PAM"
    echo "================================================================"

    local pam_gdm kr_dir backup_dir
    pam_gdm="/etc/pam.d/gdm-password"

    backup_item "$pam_gdm"

    replace_file "$pam_gdm" 0644 <<'PAM'
#%PAM-1.0

auth       include                     system-local-login
auth       optional                    pam_gnome_keyring.so

account    include                     system-local-login

password   include                     system-local-login
password   optional                    pam_gnome_keyring.so use_authtok

session    include                     system-local-login
session    optional                    pam_gnome_keyring.so auto_start
PAM

    if ! grep -qE '^[[:space:]]*password[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so([[:space:]]|$)' /etc/pam.d/passwd 2>/dev/null; then
        backup_item /etc/pam.d/passwd
        printf '\npassword    optional    pam_gnome_keyring.so\n' | sudo tee -a /etc/pam.d/passwd >/dev/null
    fi

    kr_dir="$REAL_HOME/.local/share/keyrings"
    local kr_marker="$STATE_DIR/gnome-keyring-reset-v2"
    if [ ! -e "$kr_marker" ]; then
        if [ -d "$kr_dir" ]; then
            backup_dir="$RUN_BACKUP/home/$REAL_USER/.local/share/keyrings"
            sudo mkdir -p "$(dirname "$backup_dir")"
            sudo cp -a "$kr_dir" "$backup_dir" 2>/dev/null || true
            sudo rm -rf "$kr_dir"
        fi
        sudo -u "$REAL_USER" mkdir -p "$kr_dir"
        sudo chown "$REAL_USER:$REAL_USER" "$kr_dir"
        sudo chmod 700 "$kr_dir"
        printf 'login\n' | sudo -u "$REAL_USER" tee "$kr_dir/default" >/dev/null
        chmod 600 "$kr_dir/default"
        sudo touch "$kr_marker"
        warn "Login Keyring anterior foi resetado uma vez; segredos antigos ficaram no backup."
    else
        info "Reset do Login Keyring já realizado anteriormente."
    fi

    ok "PAM/GDM recriados para desbloqueio automático do Login Keyring."
}

configure_gnome_software() {
    echo
    echo "================================================================"
    echo "7/20 - APPSTREAM / GNOME SOFTWARE"
    echo "================================================================"

    sudo pacman -S --needed --noconfirm gnome-software appstream archlinux-appstream-data packagekit || \
        die "Falha no catálogo do GNOME Software."

    if [ -x /usr/bin/appstreamcli ]; then
        sudo appstreamcli refresh-cache >/dev/null 2>&1 || true
    fi
    sudo systemctl enable --now packagekit.service 2>/dev/null || true
    sudo -u "$REAL_USER" rm -rf "$REAL_HOME/.cache/gnome-software" "$REAL_HOME/.local/share/gnome-software" 2>/dev/null || true

    ok "Catálogo AppStream do Arch recriado/atualizado."
}

# ---------------------------------------------------------------------------
# 8. APLICATIVOS, MULTIMÍDIA E EXTENSÕES GNOME
# ---------------------------------------------------------------------------

install_apps_and_extensions() {
    echo
    echo "================================================================"
    echo "8/20 - APLICATIVOS, MULTIMÍDIA E EXTENSÕES GNOME"
    echo "================================================================"

    info "PACMAN: instalando aplicativos, codecs e extensões."
    sudo pacman -S --needed --noconfirm \
        gedit \
        gnome-tweaks \
        gnome-shell-extensions \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-user-theme \
        libreoffice-fresh \
        libreoffice-fresh-pt-br \
        firefox \
        firefox-i18n-pt-br \
        thunderbird \
        cups \
        cups-pdf \
        system-config-printer \
        sane \
        sane-airscan \
        ipp-usb \
        simple-scan \
        hplip \
        python-pyqt5 \
        samba \
        cifs-utils \
        avahi \
        nss-mdns \
        bluez \
        bluez-utils \
        file-roller \
        unrar \
        7zip \
        zip \
        unzip \
        git \
        wget \
        curl \
        rsync \
        gparted \
        remmina \
        baobab \
        gnome-disk-utility \
        deja-dup \
        pavucontrol \
        bash-completion \
        fastfetch \
        htop \
        btop \
        evince \
        papirus-icon-theme \
        variety \
        wine \
        winetricks \
        vlc \
        rhythmbox \
        lame \
        gstreamer \
        gst-plugins-base \
        gst-plugins-good \
        gst-plugins-bad \
        gst-plugins-ugly \
        gst-libav \
        || die "Falha ao instalar o conjunto de aplicativos e extensões."

    install_aur_optional() {
        local pkg="$1" build
        [ "$SKIP_AUR" -eq 0 ] || { info "AUR ignorado: $pkg"; return 0; }

        command_exists makepkg || {
            warn "makepkg não está disponível; não foi possível instalar AUR: $pkg"
            return 0
        }

        build="$STATE_DIR/build/aur-$pkg"
        sudo rm -rf "$build"
        sudo mkdir -p "$STATE_DIR/build"
        sudo chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$STATE_DIR/build"

        if sudo -u "$REAL_USER" git clone --depth=1 "https://aur.archlinux.org/$pkg.git" "$build" >/dev/null 2>&1; then
            if sudo -u "$REAL_USER" bash -c "cd '$build' && makepkg -si --noconfirm"; then
                ok "AUR instalado: $pkg"
            else
                warn "AUR não pôde ser instalado: $pkg"
            fi
        else
            warn "AUR não pôde ser obtido: $pkg"
        fi
        sudo rm -rf "$build"
    }

    install_aur_optional gnome-shell-extension-dash-to-dock
    install_aur_optional gnome-shell-extension-dash-to-panel
    install_aur_optional hunspell-pt-br
    install_aur_optional yaru-gtk-theme

    # Habilita extensões
    local ext current
    for ext in \
        dash-to-dock@micxgx.gmail.com \
        dash-to-panel@jderose9.github.com \
        appindicatorsupport@rgcjonas.gmail.com \
        user-theme@gnome-shell-extensions.gcampax.github.com
    do
        current="$(sudo -u "$REAL_USER" gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")"
        case "$current" in
            *"$ext"*) continue ;;
        esac
        if [ "$current" = "[]" ] || [ -z "$current" ]; then
            sudo -u "$REAL_USER" gsettings set org.gnome.shell enabled-extensions "['$ext']" 2>/dev/null || true
        else
            local merged
            merged="$(printf '%s' "$current" | sed "s/^\[//;s/\]$//")"
            if [ -n "$merged" ]; then
                merged="[$merged, '$ext']"
            else
                merged="['$ext']"
            fi
            sudo -u "$REAL_USER" gsettings set org.gnome.shell enabled-extensions "$merged" 2>/dev/null || true
        fi
    done

    ok "Aplicativos, multimídia e extensões GNOME instalados."
}

# ---------------------------------------------------------------------------
# 9. HARDWARE / ÁUDIO / BLUETOOTH + VA-API
# ---------------------------------------------------------------------------

install_hardware() {
    echo
    echo "================================================================"
    echo "9/20 - HARDWARE, ÁUDIO, BLUETOOTH E ACELERAÇÃO DE VÍDEO"
    echo "================================================================"

    info "PACMAN: instalando pilha de hardware."
    sudo pacman -S --needed --noconfirm \
        linux-firmware sof-firmware \
        alsa-utils pipewire pipewire-alsa pipewire-pulse wireplumber \
        bluez bluez-utils bluez-obex || die "Falha na pilha de hardware."

    backup_item /etc/bluetooth/main.conf
    replace_file /etc/bluetooth/main.conf 0644 <<'CONF'
# Arco Linux BR - Bluetooth recriado pelo post-install
[General]
Name = Arco Linux BR
Class = 0x000000
DiscoverableTimeout = 0
PairableTimeout = 0

[Policy]
AutoEnable=true
CONF

    sudo systemctl enable --now bluetooth.service || warn "Bluetooth não iniciou."

    if lspci 2>/dev/null | grep -qi nvidia; then
        info "NVIDIA detectada — instalando drivers e VA-API."
        sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils libva-nvidia-driver 2>/dev/null || \
            warn "NVIDIA detectada; drivers não puderam ser instalados automaticamente."
    fi
    if lspci 2>/dev/null | grep -Eqi 'AMD.*VGA|AMD.*Display|ATI.*VGA'; then
        info "AMD detectada — instalando mesa + VA-API."
        sudo pacman -S --needed --noconfirm mesa vulkan-radeon libva-mesa-driver 2>/dev/null || true
    fi
    if lspci 2>/dev/null | grep -Eqi 'Intel.*VGA|Intel.*Display'; then
        info "Intel detectada — instalando mesa + media-driver."
        sudo pacman -S --needed --noconfirm mesa vulkan-intel intel-media-driver 2>/dev/null || true
    fi

    ok "Hardware, Bluetooth e aceleração de vídeo preparados."
}

# ---------------------------------------------------------------------------
# 10. PERIFÉRICOS - CUPS / SANE + Polkit
# ---------------------------------------------------------------------------

configure_peripherals() {
    echo
    echo "================================================================"
    echo "10/20 - IMPRESSORAS E SCANNERS"
    echo "================================================================"

    info "PACMAN: instalando pilha de impressão/scanner."
    sudo pacman -S --needed --noconfirm \
        cups cups-pk-helper system-config-printer cups-browsed hplip \
        sane sane-airscan \
        ipp-usb gutenprint foomatic-db foomatic-db-engine \
        foomatic-db-gutenprint-ppds \
        avahi nss-mdns bluez-cups acl || \
        die "Falha na pilha de impressão/scanner."

    # Polkit: permite gerenciar impressoras sem pedir senha
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/49-printer.rules >/dev/null <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.opensuse.cupspkhelper.") == 0 ||
        action.id.indexOf("org.cups.cupsd.") == 0) {
        return polkit.Result.YES;
    }
});
POLKIT

    backup_item /etc/cups/cupsd.conf
    backup_item /etc/cups/client.conf
    backup_item /etc/sane.d/saned.conf

    sudo mkdir -p /etc/cups
    replace_file /etc/cups/cupsd.conf 0644 <<'CUPS'
# Arco Linux BR - CUPS recriado pelo post-install
LogLevel warn
PageLogFormat
MaxLogSize 0
Listen localhost:631
Listen 0.0.0.0:631
Browsing Yes
BrowseLocalProtocols dnssd
DefaultShared Yes
DefaultAuthType Basic
WebInterface Yes
IdleExitTimeout 0

<Location />
  Order allow,deny
  Allow localhost
  Allow @LOCAL
</Location>

<Location /admin>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow localhost
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow localhost
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default
  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order allow,deny
    Allow @LOCAL
  </Limit>
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
    Allow @LOCAL
  </Limit>
  <Limit CUPS-Get-Document>
    Order allow,deny
    Allow @LOCAL
  </Limit>
  <Limit CUPS-Authenticate-Job>
    Order allow,deny
    Allow @LOCAL
  </Limit>
</Policy>
CUPS

    sudo rm -f /etc/cups/client.conf

    sudo tee /usr/local/sbin/arco-sane-share-sync >/dev/null <<'SYNC'
#!/usr/bin/env bash
set -u
CONF=/etc/sane.d/saned.conf
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
  echo '# Arco Linux BR - SANE recriado automaticamente'
  echo 'data_portrange = 10000 - 10100'
  echo 'localhost'
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' |     python -c 'import ipaddress,sys; [print(ipaddress.ip_interface(x.strip()).network) for x in sys.stdin if x.strip()]' 2>/dev/null | sort -u
} > "$TMP"
install -m 0644 "$TMP" "$CONF"
SYNC
    sudo chmod 755 /usr/local/sbin/arco-sane-share-sync
    sudo /usr/local/sbin/arco-sane-share-sync

    sudo rm -f /etc/systemd/system/arco-sane-share-sync.service /etc/systemd/system/arco-sane-share-sync.timer
    sudo tee /etc/systemd/system/arco-sane-share-sync.service >/dev/null <<'UNIT'
[Unit]
Description=Arco Linux BR - recria acesso LAN aos scanners SANE
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/arco-sane-share-sync
UNIT
    sudo tee /etc/systemd/system/arco-sane-share-sync.timer >/dev/null <<'TIMER'
[Unit]
Description=Arco Linux BR - atualiza redes permitidas para saned

[Timer]
OnBootSec=40s
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    sudo mkdir -p /var/spool/samba /var/lib/samba/printers
    sudo chmod 1777 /var/spool/samba

    sudo systemctl enable --now cups.service || die "CUPS não iniciou."
    sudo systemctl enable --now avahi-daemon.service || warn "Avahi não iniciou."
    sudo systemctl enable --now ipp-usb.service || warn "ipp-usb não iniciou."
    sudo systemctl enable --now cups-browsed.service || true
    sudo systemctl enable --now saned.socket || true
    sudo systemctl daemon-reload
    sudo systemctl enable --now arco-sane-share-sync.timer || true

    command_exists cups-genppdupdate && sudo cups-genppdupdate >/dev/null 2>&1 || true
    sudo systemctl restart cups.service

    ok "Impressão USB/rede/IPP e scanners USB/AirScan preparados (com Polkit)."
}

# ---------------------------------------------------------------------------
# 11. SAMBA + PÚBLICO
# ---------------------------------------------------------------------------

write_public_share_sync() {
    sudo tee /usr/local/sbin/arco-public-share-sync >/dev/null <<'SYNC'
#!/usr/bin/env bash
set -u

CONF=/etc/samba/smb.conf
GEN=/etc/samba/arco-public-shares.conf
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

mkdir -p /etc/samba /etc/skel/Público
chmod 0777 /etc/skel/Público

{
  echo '# GERADO PELO ARCO LINUX BR - NÃO EDITE'
  echo '# Cada ~/Público é guest + leitura/escrita.'
  echo
} > "$TMP"

while IFS=: read -r user home shell; do
  [ -d "$home" ] || continue
  [ -n "$user" ] || continue
  mkdir -p "$home/Público"
  chown "$user:" "$home/Público" 2>/dev/null || true
  chmod 0777 "$home/Público" 2>/dev/null || true

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:nobody:--x" "$home" 2>/dev/null || true
    setfacl -m "u:nobody:rwx" "$home/Público" 2>/dev/null || true
    setfacl -d -m u::rwx,u:nobody:rwx,g::rwx,o::rwx,m::rwx "$home/Público" 2>/dev/null || true
  fi

  cat >> "$TMP" <<SHARE_EOF
[Publico-$user]
    comment = Público de $user - SEM SENHA - LEITURA/ESCRITA
    path = $home/Público
    browseable = yes
    guest ok = yes
    guest only = yes
    read only = no
    writable = yes
    force user = $user
    create mask = 0666
    force create mode = 0666
    directory mask = 0777
    force directory mode = 0777
    inherit permissions = yes
    follow symlinks = yes
    wide links = yes

SHARE_EOF
done < <(getent passwd | awk -F: '$3>=1000 && $6 ~ /^\/home\// && $7 !~ /(nologin|false)$/ {print $1":"$6":"$7}')

install -m 0644 "$TMP" "$GEN"
testparm -s "$CONF" >/dev/null 2>&1 || exit 1
systemctl reload smb.service >/dev/null 2>&1 || systemctl restart smb.service >/dev/null 2>&1 || true
SYNC
    sudo chmod 755 /usr/local/sbin/arco-public-share-sync
}

configure_samba() {
    echo
    echo "================================================================"
    echo "11/20 - SAMBA + PASTAS PÚBLICAS"
    echo "================================================================"

    info "PACMAN: instalando Samba."
    sudo pacman -S --needed --noconfirm samba smbclient wsdd gvfs-wsdd acl || \
        die "Falha no Samba."

    backup_item /etc/samba/smb.conf
    backup_item /etc/samba/arco-public-shares.conf

    sudo rm -f /etc/samba/smb.conf /etc/samba/arco-public-shares.conf
    sudo mkdir -p /etc/samba /var/lib/samba/printers /var/spool/samba
    sudo chmod 1777 /var/spool/samba

    replace_file /etc/samba/smb.conf 0644 <<'SMB'
# Arco Linux BR - Samba recriado pelo post-install
[global]
    workgroup = WORKGROUP
    server string = Arco Linux BR
    security = user
    map to guest = Bad User
    guest account = nobody
    server min protocol = SMB2_02
    server max protocol = SMB3
    smb ports = 445
    disable netbios = yes
    load printers = yes
    printing = cups
    printcap name = cups
    cups options = raw
    show add printer wizard = no
    unix extensions = no
    wide links = yes
    include = /etc/samba/arco-public-shares.conf

[printers]
    comment = Impressoras do Arco Linux BR - sem senha
    path = /var/spool/samba
    browseable = yes
    printable = yes
    read only = yes
    guest ok = yes
    guest only = yes

[print$]
    comment = Drivers de impressoras
    path = /var/lib/samba/printers
    browseable = yes
    read only = yes
    guest ok = yes
SMB

    write_public_share_sync
    sudo mkdir -p /etc/skel/Público
    sudo chmod 0777 /etc/skel/Público
    sudo /usr/local/sbin/arco-public-share-sync || die "Configuração dos compartilhamentos Públicos inválida."
    testparm -s >/dev/null 2>&1 || die "smb.conf inválido."
    sudo systemctl enable --now smb.service || die "smb.service não iniciou."
    sudo systemctl enable --now wsdd.service || true
    sudo systemctl enable --now wsdd-discovery.service || true

    sudo rm -f /etc/systemd/system/arco-public-share-sync.service /etc/systemd/system/arco-public-share-sync.timer
    sudo tee /etc/systemd/system/arco-public-share-sync.service >/dev/null <<'UNIT'
[Unit]
Description=Arco Linux BR - recria compartilhamentos das pastas Públicas
After=network-online.target smb.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/arco-public-share-sync
UNIT

    sudo tee /etc/systemd/system/arco-public-share-sync.timer >/dev/null <<'TIMER'
[Unit]
Description=Arco Linux BR - detecta novos usuários e suas pastas Públicas

[Timer]
OnBootSec=30s
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    sudo systemctl daemon-reload
    sudo systemctl enable --now arco-public-share-sync.timer
    ok "Samba recriado: Público = convidado + leitura/escrita + symlinks."
    warn "Symlinks fora de ~/Público podem expor o alvo ao guest; isso é intencional neste projeto."
}

# ---------------------------------------------------------------------------
# 12. FONTES
# ---------------------------------------------------------------------------

install_fonts() {
    echo
    echo "================================================================"
    echo "12/20 - FONTES"
    echo "================================================================"

    [ "$SKIP_FONTS" -eq 0 ] || { info "Fontes ignoradas."; return 0; }
    info "PACMAN: instalando fontes."
    sudo pacman -S --needed --noconfirm \
        fontconfig freetype2 noto-fonts noto-fonts-cjk noto-fonts-emoji \
        ttf-dejavu ttf-liberation ttf-croscore ttf-carlito ttf-caladea || \
        die "Falha nas fontes."

    if [ "$SKIP_AUR" -eq 0 ]; then
        info "Instalando Microsoft Core Fonts via AUR..."
        sudo pacman -S --needed --noconfirm base-devel git || true
        local build="$STATE_DIR/build/ttf-ms-fonts"
        sudo rm -rf "$build"
        sudo mkdir -p "$(dirname "$build")"
        sudo chown -R "$REAL_USER:$REAL_USER" "$STATE_DIR/build"
        if sudo -u "$REAL_USER" git clone --depth=1 https://aur.archlinux.org/ttf-ms-fonts.git "$build" >/dev/null 2>&1; then
            sudo -u "$REAL_USER" bash -c "cd '$build' && makepkg -si --noconfirm" || warn "ttf-ms-fonts não pôde ser instalado."
        else
            warn "AUR ttf-ms-fonts não pôde ser obtido."
        fi
    fi
    sudo fc-cache -f >/dev/null 2>&1 || true
    ok "Fontes configuradas (incluindo Microsoft Core Fonts)."
}

# ---------------------------------------------------------------------------
# 13. APPIMAGEHUB
# ---------------------------------------------------------------------------

install_appimagehub() {
    echo
    echo "================================================================"
    echo "13/20 - APPIMAGE / APPIMAGEHUB"
    echo "================================================================"

    [ "$MINIMAL" -eq 0 ] || { info "AppImageHub ignorado no modo minimal."; return 0; }
    info "PACMAN: instalando suporte a AppImage."
    sudo pacman -S --needed --noconfirm fuse2 libappimage xdg-utils || \
        warn "Suporte base a AppImage não pôde ser instalado."

    sudo rm -f /usr/local/bin/appimage-cli-tool 2>/dev/null || true

    sudo tee /usr/share/applications/arco-appimagehub.desktop >/dev/null <<'DESKTOP'
[Desktop Entry]
Name=AppImageHub
Comment=Catálogo de aplicativos AppImage
Exec=xdg-open https://www.appimagehub.com/
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Utility;System;
Keywords=AppImage;AppImageHub;Software;
DESKTOP
    sudo chmod 644 /usr/share/applications/arco-appimagehub.desktop
    ok "AppImageHub preparado."
}

# ---------------------------------------------------------------------------
# 14. FLATPAK + Extension Manager
# ---------------------------------------------------------------------------

configure_flatpak() {
    echo
    echo "================================================================"
    echo "14/20 - FLATPAK + EXTENSION MANAGER"
    echo "================================================================"
    [ "$SKIP_FLATPAK" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || { info "Flatpak ignorado."; return 0; }
    info "PACMAN: instalando Flatpak."
    sudo pacman -S --needed --noconfirm flatpak || { warn "Flatpak não instalado."; return 0; }
    sudo -u "$REAL_USER" flatpak remote-delete flathub >/dev/null 2>&1 || true
    sudo -u "$REAL_USER" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true

    info "Instalando Extension Manager via Flatpak..."
    sudo -u "$REAL_USER" flatpak install -y flathub com.mattjakeman.ExtensionManager || \
        warn "Extension Manager não pôde ser instalado via Flatpak."

    ok "Flathub + Extension Manager recriados."
}

# ---------------------------------------------------------------------------
# 15. SNAP + SNAP STORE (instalado por padrão)
# ---------------------------------------------------------------------------

configure_snap() {
    echo
    echo "================================================================"
    echo "15/20 - SNAP + SNAP STORE (OFICIAL)"
    echo "================================================================"

    [ "$MINIMAL" -eq 0 ] || { info "Snap ignorado no modo minimal."; return 0; }

    if [ "$SKIP_AUR" -eq 1 ]; then
        warn "Snap requer AUR. Remova --skip-aur para instalar o Snap."
        return 0
    fi

    info "Instalando Snapd + Snap Store (central oficial)..."

    sudo pacman -S --needed --noconfirm base-devel git || true

    local build="$STATE_DIR/build/snapd"
    sudo rm -rf "$build"
    sudo mkdir -p "$STATE_DIR/build"
    sudo chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$STATE_DIR/build"

    if sudo -u "$REAL_USER" git clone --depth=1 https://aur.archlinux.org/snapd.git "$build" >/dev/null 2>&1; then
        if sudo -u "$REAL_USER" bash -c "cd '$build' && makepkg -si --noconfirm"; then
            sudo systemctl enable --now snapd.socket
            sudo systemctl enable --now snapd.service
            sudo ln -sf /var/lib/snapd/snap /snap

            info "Aguardando o Snapd inicializar..."
            sleep 6

            if sudo snap install snap-store; then
                ok "Snapd + Snap Store instalados com sucesso."
            else
                warn "Snapd instalado, mas a Snap Store falhou. Execute depois: sudo snap install snap-store"
            fi
        else
            warn "Falha ao compilar/instalar o snapd via AUR."
        fi
    else
        warn "Não foi possível baixar o snapd do AUR."
    fi

    sudo rm -rf "$build"
}

# ---------------------------------------------------------------------------
# 16. TEMAS WIN11
# ---------------------------------------------------------------------------

install_win11_themes() {
    echo
    echo "================================================================"
    echo "16/20 - TEMAS E ÍCONES WINDOWS 11"
    echo "================================================================"
    [ "$MINIMAL" -eq 0 ] || { info "Temas Win11 ignorados no modo minimal."; return 0; }

    local build_dir
    build_dir="$(mktemp -d)"
    cd "$build_dir" || return 0

    info "Clonando e instalando Win11 GTK Theme..."
    if sudo -u "$REAL_USER" git clone --depth=1 https://github.com/yeyushengfan258/Win11-gtk-theme.git 2>/dev/null; then
        cd Win11-gtk-theme || true
        sudo ./install.sh || warn "Falha ao instalar Win11-gtk-theme."
        cd ..
    else
        warn "Não foi possível clonar Win11-gtk-theme."
    fi

    info "Clonando e instalando Win11 Icon Theme..."
    if sudo -u "$REAL_USER" git clone --depth=1 https://github.com/yeyushengfan258/Win11-icon-theme.git 2>/dev/null; then
        cd Win11-icon-theme || true
        sudo ./install.sh || warn "Falha ao instalar Win11-icon-theme."
        cd ..
    else
        warn "Não foi possível clonar Win11-icon-theme."
    fi

    cd /
    rm -rf "$build_dir"
    ok "Temas e ícones Windows 11 instalados (aplicáveis via GNOME Tweaks)."
}

# ---------------------------------------------------------------------------
# 17. FIREWALL
# ---------------------------------------------------------------------------

configure_firewall() {
    echo
    echo "================================================================"
    echo "17/20 - FIREWALL + LAN"
    echo "================================================================"
    [ "$NO_FIREWALL" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || { info "Firewall ignorado."; return 0; }
    info "PACMAN: instalando firewalld."
    sudo pacman -S --needed --noconfirm firewalld || { warn "firewalld não instalado."; return 0; }
    sudo systemctl enable --now firewalld.service || { warn "firewalld não iniciou."; return 0; }

    backup_item /etc/firewalld/firewalld.conf
    replace_file /etc/firewalld/firewalld.conf 0644 <<'CONF'
# Arco Linux BR - firewalld recriado pelo post-install
DefaultZone=public
MinimalMark=yes
CleanupOnExit=yes
Lockdown=no
IPv6_rpfilter=yes
IndividualCalls=no
AllowZoneDrifting=no
FirewallBackend=nftables
CONF
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld configurado."
}

sync_firewall_lan() {
    command_exists firewall-cmd || return 0
    systemctl is-active --quiet firewalld.service 2>/dev/null || return 0
    local zone="arco-lan"
    sudo firewall-cmd --permanent --delete-zone="$zone" >/dev/null 2>&1 || true
    sudo mkdir -p /etc/firewalld/services
    sudo rm -f /etc/firewalld/services/arco-sane.xml
    sudo tee /etc/firewalld/services/arco-sane.xml >/dev/null <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Arco SANE</short>
  <description>Scanner sharing for the Arco Linux BR LAN</description>
  <port protocol="tcp" port="6566"/>
  <port protocol="tcp" port="10000-10100"/>
</service>
XML
    sudo firewall-cmd --reload >/dev/null 2>&1 || return 1
    sudo firewall-cmd --permanent --new-zone="$zone" >/dev/null 2>&1 || return 1
    for service in mdns samba ipp arco-sane wsdd wsdd-discovery; do
        sudo firewall-cmd --permanent --zone="$zone" --add-service="$service" >/dev/null 2>&1 || true
    done
    while IFS= read -r net; do
        [ -n "$net" ] || continue
        sudo firewall-cmd --permanent --zone="$zone" --add-source="$net" >/dev/null 2>&1 || true
    done < <(
        ip -4 -o addr show scope global 2>/dev/null |
        awk '$2 !~ /^(lo|virbr|docker|veth|br-|tun|tap|wg)/ {print $4}' |
        python -c 'import ipaddress,sys; [print(ipaddress.ip_interface(x.strip()).network) for x in sys.stdin if x.strip() and ipaddress.ip_interface(x.strip()).ip.is_private]'
        2>/dev/null | sort -u
    )
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
}

install_firewall_sync() {
    [ "$NO_FIREWALL" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || return 0
    sync_firewall_lan
    sudo tee /usr/local/sbin/arco-lan-firewall-sync >/dev/null <<'SYNC'
#!/usr/bin/env bash
set -u
command -v firewall-cmd >/dev/null 2>&1 || exit 0
systemctl is-active --quiet firewalld.service 2>/dev/null || exit 0
ZONE=arco-lan
mkdir -p /etc/firewalld/services
cat >/etc/firewalld/services/arco-sane.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>Arco SANE</short>
  <description>Scanner sharing for the Arco Linux BR LAN</description>
  <port protocol="tcp" port="6566"/>
  <port protocol="tcp" port="10000-10100"/>
</service>
XML
firewall-cmd --reload >/dev/null 2>&1 || exit 1
firewall-cmd --permanent --delete-zone="$ZONE" >/dev/null 2>&1 || true
firewall-cmd --permanent --new-zone="$ZONE" >/dev/null 2>&1 || exit 1
for service in mdns samba ipp arco-sane wsdd wsdd-discovery; do
  firewall-cmd --permanent --zone="$ZONE" --add-service="$service" >/dev/null 2>&1 || true
done
while IFS= read -r net; do
  [ -n "$net" ] || continue
  firewall-cmd --permanent --zone="$ZONE" --add-source="$net" >/dev/null 2>&1 || true
done < <(
  ip -4 -o addr show scope global 2>/dev/null |
  awk '$2 !~ /^(lo|virbr|docker|veth|br-|tun|tap|wg)/ {print $4}' |
  python -c 'import ipaddress,sys; [print(ipaddress.ip_interface(x.strip()).network) for x in sys.stdin if x.strip() and ipaddress.ip_interface(x.strip()).ip.is_private]'
  2>/dev/null | sort -u
)
firewall-cmd --reload >/dev/null 2>&1 || true
SYNC
    sudo chmod 755 /usr/local/sbin/arco-lan-firewall-sync
    sudo rm -f /etc/systemd/system/arco-lan-firewall-sync.service /etc/systemd/system/arco-lan-firewall-sync.timer
    sudo tee /etc/systemd/system/arco-lan-firewall-sync.service >/dev/null <<'UNIT'
[Unit]
Description=Arco Linux BR - firewall adaptativo da LAN
After=NetworkManager.service firewalld.service
Wants=NetworkManager.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/arco-lan-firewall-sync
UNIT
    sudo tee /etc/systemd/system/arco-lan-firewall-sync.timer >/dev/null <<'TIMER'
[Unit]
Description=Arco Linux BR - atualiza firewall da LAN

[Timer]
OnBootSec=45s
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    sudo systemctl daemon-reload
    sudo systemctl enable --now arco-lan-firewall-sync.timer
}

# ---------------------------------------------------------------------------
# 18. VIRTUALIZAÇÃO
# ---------------------------------------------------------------------------

host_networks() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | \
    python -c 'import ipaddress,sys; [print(ipaddress.ip_interface(x.strip()).network) for x in sys.stdin if x.strip()]' 2>/dev/null | sort -u
}

choose_libvirt_network() {
    local c n conflict
    for c in 10.88.0.0/24 10.89.0.0/24 10.90.0.0/24 10.91.0.0/24 10.92.0.0/24 172.30.0.0/24 172.31.0.0/24 192.168.250.0/24 192.168.251.0/24; do
        conflict=0
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if python - "$c" "$n" <<'PY' >/dev/null 2>&1
import ipaddress,sys
raise SystemExit(0 if ipaddress.ip_network(sys.argv[1], strict=False).overlaps(ipaddress.ip_network(sys.argv[2], strict=False)) else 1)
PY
            then
                conflict=1
                break
            fi
        done < <(host_networks)
        if [ "$conflict" -eq 0 ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

configure_libvirt() {
    command_exists virsh || return 0
    sudo systemctl enable --now libvirtd.service 2>/dev/null || { warn "libvirtd não iniciou."; return 0; }
    local subnet base gw start end
    subnet="$(choose_libvirt_network || true)"
    [ -n "$subnet" ] || { warn "Nenhuma sub-rede libvirt livre foi encontrada."; return 0; }
    base="${subnet%/*}"
    gw="$(python - "$base" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]+'/24',strict=False); print(n.network_address+1)
PY
)"
    start="$(python - "$base" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]+'/24',strict=False); print(n.network_address+2)
PY
)"
    end="$(python - "$base" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]+'/24',strict=False); print(n.network_address+254)
PY
)"
    sudo virsh net-destroy default >/dev/null 2>&1 || true
    sudo virsh net-undefine default >/dev/null 2>&1 || true
    replace_file /tmp/arco-libvirt-default.xml 0644 <<XML
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='$gw' netmask='255.255.255.0'>
    <dhcp><range start='$start' end='$end'/></dhcp>
  </ip>
</network>
XML
    if sudo virsh net-define /tmp/arco-libvirt-default.xml >/dev/null 2>&1; then
        sudo virsh net-autostart default >/dev/null 2>&1 || true
        sudo virsh net-start default >/dev/null 2>&1 || true
        info "Rede libvirt recriada em $subnet."
    else
        warn "Rede libvirt não pôde ser recriada."
    fi
    rm -f /tmp/arco-libvirt-default.xml
}

install_virtualization() {
    echo
    echo "================================================================"
    echo "18/20 - QEMU / KVM / GNOME BOXES / SPICE"
    echo "================================================================"
    [ "$SKIP_VIRTUALIZATION" -eq 0 ] && [ "$MINIMAL" -eq 0 ] || { info "Virtualização ignorada."; return 0; }
    info "PACMAN: instalando virtualização."
    sudo pacman -S --needed --noconfirm \
        qemu-desktop qemu-img libvirt virt-manager virt-viewer virt-install \
        gnome-boxes spice-gtk spice-protocol spice-vdagent qemu-guest-agent \
        usbredir virtiofsd edk2-ovmf swtpm || die "Falha na virtualização."
    sudo systemctl enable --now libvirtd.service || true
    sudo systemctl enable --now virtlogd.socket || true
    sudo systemctl enable qemu-guest-agent.service || true
    sudo usermod -aG libvirt "$REAL_USER" 2>/dev/null || true
    configure_libvirt
    ok "Virtualização configurada."
}

# ---------------------------------------------------------------------------
# 19. NETWORK GUARD
# ---------------------------------------------------------------------------

install_network_guard() {
    echo
    echo "================================================================"
    echo "19/20 - ARCO NETWORK GUARD"
    echo "================================================================"
    sudo mkdir -p /usr/local/libexec "$STATE_DIR/network" "$LOG_DIR"
    sudo tee /usr/local/libexec/arco-network-guard >/dev/null <<'GUARD'
#!/usr/bin/env bash
set -u
STATE=/var/lib/arco-linux/network
LOG=/var/log/arco-linux/network-guard.log
LOCK=/run/arco-network-guard.lock
mkdir -p "$STATE" "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
exec 9>"$LOCK"
flock -n 9 || exit 0
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
nm_ready(){ command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager.service 2>/dev/null && nmcli general status >/dev/null 2>&1; }
physical_interfaces(){ for d in /sys/class/net/*; do i=$(basename "$d"); case "$i" in lo|virbr*|docker*|veth*|br-*|tun*|tap*|wg*) continue;; esac; [ -e "$d/device" ] && echo "$i"; done; }
is_wifi(){ [ -d "/sys/class/net/$1/wireless" ]; }
is_eth(){ [ "$(cat "/sys/class/net/$1/type" 2>/dev/null || echo 0)" = 1 ] && ! is_wifi "$1"; }
active_iface(){ nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected" && $1!="lo"{print $1;exit}'; }
network_ok(){ local i g a; nm_ready || return 1; i=$(active_iface); [ -n "$i" ] || return 1; a=$(ip -4 -o addr show dev "$i" scope global 2>/dev/null | awk '{print $4;exit}'); [ -n "$a" ] || return 1; g=$(ip route show default dev "$i" 2>/dev/null | awk '/default/{print $3;exit}'); [ -n "$g" ] || return 1; ping -c1 -W2 "$g" >/dev/null 2>&1 || return 1; ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || return 1; getent ahosts archlinux.org >/dev/null 2>&1 || return 1; curl -fsSIL --connect-timeout 4 --max-time 10 https://archlinux.org/ >/dev/null 2>&1 || return 1; }
write_nm_config(){ rm -f /etc/NetworkManager/NetworkManager.conf; cat >/etc/NetworkManager/NetworkManager.conf <<'CONF'
# Arco Linux BR - Network Guard
[main]
plugins=keyfile
rc-manager=symlink
dns=systemd
[device]
wifi.scan-rand-mac-address=yes
[connection]
connection.mdns=2
connection.llmnr=0
CONF
rm -rf /etc/NetworkManager/system-connections; mkdir -p /etc/NetworkManager/system-connections; chmod 700 /etc/NetworkManager/system-connections; }
write_resolved_config(){ rm -f /etc/systemd/resolved.conf; cat >/etc/systemd/resolved.conf <<'CONF'
# Arco Linux BR - Network Guard
[Resolve]
DNS=
FallbackDNS=1.1.1.1 9.9.9.9
Domains=
DNSSEC=allow-downgrade
DNSOverTLS=no
MulticastDNS=no
LLMNR=no
Cache=yes
DNSStubListener=yes
CONF
systemctl enable --now systemd-resolved.service >/dev/null 2>&1 || true; rm -f /etc/resolv.conf; ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; }
rebuild(){
  log 'REBUILD: backup antes da limpeza.'
  local b=/var/lib/arco-linux/network/recovery-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$b"; cp -a /etc/NetworkManager "$b/" 2>/dev/null || true; cp -a /etc/systemd/network "$b/" 2>/dev/null || true; cp -a /etc/resolv.conf "$b/" 2>/dev/null || true; cp -a /etc/systemd/resolved.conf "$b/" 2>/dev/null || true
  systemctl disable --now systemd-networkd.service systemd-networkd-wait-online.service dhcpcd.service connman.service netctl.service iwd.service wpa_supplicant.service >/dev/null 2>&1 || true
  rm -rf /etc/systemd/network /etc/iwd /etc/netctl
  write_resolved_config; write_nm_config
  systemctl enable --now NetworkManager.service >/dev/null 2>&1 || return 1; systemctl restart NetworkManager.service >/dev/null 2>&1 || return 1; sleep 3
  local i name
  for i in $(physical_interfaces); do
    is_eth "$i" || continue; ip link set "$i" up >/dev/null 2>&1 || true; name="Arco Ethernet - $i"; nmcli connection delete "$name" >/dev/null 2>&1 || true
    nmcli connection add type ethernet ifname "$i" con-name "$name" ipv4.method auto ipv6.method auto connection.autoconnect yes connection.autoconnect-priority 100 || continue
    nmcli connection up "$name" >/dev/null 2>&1 || continue; sleep 2; network_ok && return 0
  done
  if [ -d "$b/NetworkManager/system-connections" ]; then
    cp -a "$b/NetworkManager/system-connections/." /etc/NetworkManager/system-connections/ 2>/dev/null || true; chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true; nmcli connection reload >/dev/null 2>&1 || true
    for i in $(physical_interfaces); do is_wifi "$i" || continue; while IFS= read -r name; do [ -n "$name" ] || continue; nmcli connection up "$name" ifname "$i" >/dev/null 2>&1 || continue; sleep 3; network_ok && return 0; done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}'); done
  fi
  return 1
}
repair(){
  network_ok && { echo healthy >"$STATE/state"; log 'Rede saudável; nenhuma alteração.'; return 0; }
  log 'Rede degradada; reparo progressivo.'; systemctl restart NetworkManager.service >/dev/null 2>&1 || true; sleep 3; systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
  network_ok && { echo healthy >"$STATE/state"; return 0; }; rebuild && { echo healthy >"$STATE/state"; log 'Rede reconstruída com sucesso.'; return 0; }; echo degraded >"$STATE/state"; log 'Não foi possível recuperar a Internet automaticamente.'; return 1
}
status(){ nmcli device status 2>/dev/null || true; echo; ip -br addr 2>/dev/null || true; echo; ip route 2>/dev/null || true; echo; resolvectl status 2>/dev/null | head -50 || true; echo; if network_ok; then echo 'RESULTADO: INTERNET OK'; return 0; else echo 'RESULTADO: INTERNET COM PROBLEMA'; return 1; fi; }
case "${1:---boot}" in
  --status) status;;
  --check) network_ok && echo 'REDE OK' || { echo 'REDE COM PROBLEMA'; exit 1; };;
  --repair) repair;;
  --rebuild) rebuild;;
  --boot) systemctl start NetworkManager.service >/dev/null 2>&1 || true; sleep 3; if network_ok; then echo healthy >"$STATE/state"; log 'BOOT: rede saudável; sem alterações.'; exit 0; fi; repair || true;;
  -h|--help) echo 'sudo arco-network-guard --status|--check|--repair|--rebuild|--boot';;
  *) exit 2;;
esac
GUARD
    sudo chmod 755 /usr/local/libexec/arco-network-guard
    sudo tee /usr/local/bin/arco-network-guard >/dev/null <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/libexec/arco-network-guard "$@"
WRAP
    sudo chmod 755 /usr/local/bin/arco-network-guard
    sudo rm -f /etc/systemd/system/arco-network-guard.service
    sudo tee /etc/systemd/system/arco-network-guard.service >/dev/null <<'UNIT'
[Unit]
Description=Arco Linux BR Network Guard
After=NetworkManager.service systemd-resolved.service
Wants=NetworkManager.service systemd-resolved.service
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/arco-network-guard --boot
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
UNIT
    sudo chmod 644 /etc/systemd/system/arco-network-guard.service
    sudo systemctl daemon-reload
    sudo systemctl enable arco-network-guard.service
    ok "Network Guard instalado e habilitado no boot."
}

# ---------------------------------------------------------------------------
# 20. VALIDAÇÃO FINAL
# ---------------------------------------------------------------------------

validate_configuration() {
    echo
    echo "================================================================"
    echo "20/20 - VALIDAÇÃO DAS CONFIGURAÇÕES"
    echo "================================================================"
    if command_exists testparm && testparm -s >/dev/null 2>&1; then ok "Samba: configuração válida."; else warn "Samba: testparm não passou."; fi
    if command_exists cupsd && cupsd -t >/dev/null 2>&1; then ok "CUPS: configuração válida."; else warn "CUPS: cupsd -t não passou."; fi
    if command_exists firewall-cmd && firewall-cmd --check-config >/dev/null 2>&1; then ok "firewalld: configuração válida."; fi
    if command_exists nmcli && nmcli general status >/dev/null 2>&1; then ok "NetworkManager: operacional."; else warn "NetworkManager: estado não validado."; fi
    systemctl is-enabled gdm.service >/dev/null 2>&1 && ok "GDM: habilitado." || warn "GDM não está habilitado."
    systemctl is-enabled arco-network-guard.service >/dev/null 2>&1 && ok "Network Guard: habilitado." || warn "Network Guard não está habilitado."
    [ "$NO_FIREWALL" -eq 0 ] && [ "$MINIMAL" -eq 0 ] && systemctl is-active --quiet firewalld.service 2>/dev/null && sync_firewall_lan || true
}

final_validation() {
    echo
    echo "================================================================"
    echo "VALIDAÇÃO FINAL"
    echo "================================================================"
    network_test || die "A Internet não passou na validação final. O sistema não será declarado pronto."
    ok "Internet: OK."
    echo
    echo "Interface:"; nmcli device status 2>/dev/null || true
    echo; echo "Rotas:"; ip route 2>/dev/null || true
    echo; echo "Serviços principais:"
    for s in NetworkManager systemd-resolved gdm cups avahi-daemon smb arco-network-guard; do printf '  %-24s ' "$s"; systemctl is-active "$s.service" 2>/dev/null || true; done
    echo
    echo "================================================================"
    echo "ARCO LINUX BR - INSTALAÇÃO CONCLUÍDA (v$VERSION)"
    echo "================================================================"
    echo "Rede:             NetworkManager + systemd-resolved + Network Guard"
    echo "GNOME:            completo + extensões (Dock, Panel, AppIndicator, User Theme)"
    echo "Keyring:          PAM/GDM recriado"
    echo "Aplicativos:      LibreOffice, Thunderbird, Firefox, VLC, Rhythmbox, Wine"
    echo "Multimídia:       Codecs GStreamer completos + VA-API"
    echo "GNOME Software:   AppStream Arch + Flatpak + Extension Manager"
    echo "Snap:             Snapd + Snap Store (central oficial) instalados"
    echo "Temas:            Yaru + Papirus + Win11 GTK/Ícones"
    echo "Impressão:        CUPS + IPP + Avahi + Bluetooth + Samba + Polkit"
    echo "Scanners:         SANE + AirScan + IPP-USB"
    echo "Público:          guest + leitura/escrita + symlinks"
    echo "Backups:          $RUN_BACKUP"
    echo "Log:              $LOG_FILE"
    echo
    echo "Comandos úteis:"
    echo "  sudo arco-network-guard --status"
    echo "  sudo arco-network-guard --repair"
    echo "  sudo arco-network-guard --rebuild"
    echo "  lpstat -p -d"
    echo "  scanimage -L"
    echo "  smbclient -L localhost -N"
    echo "  snap find <app>"
    echo
    echo "Reinicie o sistema para aplicar todas as extensões, temas e o Snap Store."
}

main() {
    [ "$(id -u)" -ne 0 ] || die "Execute como usuário normal; o script usa sudo."
    [ -f /etc/arch-release ] || die "Este script é destinado ao Arch Linux."
    [ -n "$REAL_USER" ] || die "Não foi possível determinar o usuário real."
    getent passwd "$REAL_USER" >/dev/null 2>&1 || die "Usuário real '$REAL_USER' não existe."
    [ "$(id -u "$REAL_USER" 2>/dev/null || echo 0)" -ge 1000 ] || die "O usuário real precisa ser uma conta normal (UID >= 1000)."
    command_exists sudo || die "sudo não está instalado."
    sudo -v || die "Não foi possível autenticar sudo."

    detect_environment
    install_network_prerequisites
    rebuild_network || die "Não foi possível estabelecer Internet após a reconstrução da rede."
    update_system
    install_gnome
    configure_gnome_keyring
    configure_gnome_software
    install_apps_and_extensions
    install_hardware
    configure_peripherals
    configure_samba
    install_fonts
    install_appimagehub
    configure_flatpak
    configure_snap
    install_win11_themes
    configure_firewall
    install_firewall_sync
    install_virtualization
    install_network_guard
    validate_configuration
    final_validation
}

main "$@"
