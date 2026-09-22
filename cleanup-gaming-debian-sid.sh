#!/usr/bin/env bash
# =============================================================================
# cleanup-gaming-debian-sid.sh
# =============================================================================
#
# Revierte lo que instala y configura setup-gaming-debian-sid.sh en Debian
# Sid, y deja el sistema limpio en lo relativo a los paquetes de juego.
#
# Uso:
#   ./cleanup-gaming-debian-sid.sh --dry-run      # solo muestra lo que haría
#   ./cleanup-gaming-debian-sid.sh                # pregunta bloque a bloque
#   ./cleanup-gaming-debian-sid.sh -y             # acepta las preguntas normales
#   ./cleanup-gaming-debian-sid.sh --purge-data   # además ofrece borrar datos
#
# Qué SÍ elimina (cada bloque pide confirmación):
#   1. Paquetes de apt: steam-installer, heroic, gamemode, winetricks,
#      protontricks, mesa-utils, lutris y gamescope. Se purgan sin pantallas
#      de debconf. steam-launcher no se elimina: el setup actual lo respeta
#      si ya estaba instalado.
#   2. Flatpak: ProtonPlus, MangoJuice y GOverlay (este último, de versiones
#      anteriores del setup que lo instalaban), si están instalados.
#   3. MangoHud compilado (instalado con "ninja install", que dpkg no
#      conoce): se borran sus rutas conocidas, mostrando antes la lista, y
#      solo si no pertenecen a ningún paquete de Debian.
#   4. Ficheros creados por el script (solo si llevan su marca):
#      /usr/local/bin/game-performance, ~/.config/gamemode.ini,
#      /etc/sysctl.d/80-gamecompatibility.conf y
#      /etc/modules-load.d/ntsync.conf. Además, la línea pci_dev de
#      MangoHud.conf (con pregunta aparte) y el deb-src que se activó para
#      compilar MangoHud (con pregunta aparte).
#   5. El enlace /usr/local/bin/wineserver solo se ofrece para eliminarlo
#      si apunta exactamente a un wineserver perteneciente a Wine instalado.
#
# Qué NO toca (es compartido con el resto del sistema):
#   - power-profiles-daemon (lo usa KDE), flatpak y el remoto Flathub.
#   - La arquitectura i386 (la usan también las librerías de NVIDIA).
#   - Los paquetes de desarrollo instalados para compilar.
#   - Tus datos de juego: ~/.steam, ~/.local/share/Steam, ~/Games, prefijos
#     de Proton, datos de Heroic/Lutris... Borrarlos es irreversible y solo
#     se ofrece con --purge-data, con confirmación escrita y mostrando antes
#     lo que ocupa cada carpeta. -y nunca los borra.
#   - vm.max_map_count: al quitar el fichero de configuración, el valor sigue
#     activo hasta el próximo reinicio.
#
# =============================================================================

VERSION="1.0.0"

set -uo pipefail

DRY_RUN=0
ASSUME_YES=0
PURGE_DATA=0
FAILURES=()

# ---------------------------------------------------------------------------
# Mensajes
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log_step() { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
log_ok()   { printf '%s  ✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
log_info() { printf '  • %s\n' "$*"; }
log_warn() { printf '%s  ⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
log_err()  { printf '%s  ✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

usage() {
    cat <<EOF
cleanup-gaming-debian-sid.sh ${VERSION}

Uso: $0 [-n|--dry-run] [-y|--yes] [--purge-data] [-h|--help]

  -n, --dry-run   Muestra lo que haría sin cambiar nada (no pide sudo).
  -y, --yes       Acepta las confirmaciones normales (paquetes, Flatpak,
                  MangoHud y ficheros del script). NO acepta nunca el borrado
                  de datos, el autoremove, la línea pci_dev ni el deb-src.
      --purge-data  Además ofrece borrar los datos de usuario (Steam, Heroic,
                  Lutris, Games...). Es irreversible: pide escribir BORRAR y
                  muestra antes lo que ocupa cada carpeta.
  -h, --help      Muestra esta ayuda.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)  DRY_RUN=1 ;;
            -y|--yes)      ASSUME_YES=1 ;;
            --purge-data)  PURGE_DATA=1 ;;
            -h|--help)     usage; exit 0 ;;
            *)             log_err "Opción desconocida: $1"; usage; exit 2 ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

# Ejecuta el comando, o solo lo muestra con --dry-run.
run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '  [simulación] %s\n' "$*"
        return 0
    fi
    "$@"
}

# Confirmación normal: --dry-run y -y la aceptan. Sin terminal se omite.
confirm() {
    local question="$1" answer
    [[ "$DRY_RUN" -eq 1 || "$ASSUME_YES" -eq 1 ]] && return 0
    if [[ ! -t 0 ]]; then
        log_info "Sin terminal interactiva: se omite (${question})"
        return 1
    fi
    read -rp "  ${question} [s/N]: " answer
    [[ "$answer" =~ ^[sS]$ ]]
}

# Confirmación que -y NUNCA acepta: siempre pregunta. Sin terminal se omite;
# con --dry-run solo indica que se preguntaría.
confirm_always() {
    local question="$1" answer
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[simulación] Se preguntaría: ${question}"
        return 1
    fi
    if [[ ! -t 0 ]]; then
        log_info "Sin terminal interactiva: se omite (${question})"
        return 1
    fi
    read -rp "  ${question} [s/N]: " answer
    [[ "$answer" =~ ^[sS]$ ]]
}

# 0 si el paquete está instalado o con restos de configuración (rc/pc).
pkg_present() {
    local status
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" || return 1
    [[ -n "$status" && "${status:1:1}" != "n" ]]
}

check_user() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No ejecutes este script como root. Ejecútalo como tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
        exit 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'."
        exit 1
    fi
    if ! sudo -v; then
        log_err "No se pudieron obtener privilegios sudo."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Paquetes de apt
# ---------------------------------------------------------------------------
step_packages() {
    log_step "1/7 · Paquetes de apt"

    local candidates=(steam-installer heroic gamemode winetricks protontricks mesa-utils lutris gamescope)
    local found=() pkg
    for pkg in "${candidates[@]}"; do
        pkg_present "$pkg" && found+=("$pkg")
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        log_ok "No hay paquetes de juego del script instalados"
        return 0
    fi

    log_info "Se purgarán: ${found[*]}"
    if ! confirm "¿Purgar estos paquetes?"; then
        log_info "Se omite este bloque"
        return 0
    fi

    # DEBIAN_FRONTEND=noninteractive evita que la purga se quede esperando
    # una pantalla de debconf (le pasó a steam-installer).
    if run sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${found[@]}"; then
        log_ok "Paquetes purgados: ${found[*]}"
    else
        log_err "Falló la purga de paquetes. Revisa el error de arriba."
        FAILURES+=("purga de paquetes apt")
        return 1
    fi

    # autoremove: solo se muestra la lista y se pregunta. En Sid puede
    # incluir paquetes ajenos a los juegos, así que -y nunca lo aplica.
    local orphans
    orphans="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}')"
    if [[ -n "$orphans" ]]; then
        log_warn "'apt autoremove' eliminaría estos paquetes (revisa la lista antes de aceptar):"
        sed 's/^/      · /' <<<"$orphans"
        if confirm_always "¿Ejecutar 'apt autoremove --purge' ahora?"; then
            run sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y \
                || FAILURES+=("apt autoremove")
        else
            log_info "No se ejecuta autoremove"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 2. Flatpak (ProtonPlus, MangoJuice y GOverlay heredado)
# ---------------------------------------------------------------------------
step_flatpak() {
    log_step "2/7 · Flatpak (ProtonPlus, MangoJuice y GOverlay)"

    if ! command -v flatpak &>/dev/null; then
        log_ok "Flatpak no está instalado; no hay nada que quitar"
        return 0
    fi

    # El ID de MangoJuice es el mismo que instala setup-gaming-debian-sid.sh.
    # GOverlay se mantiene porque versiones anteriores del setup lo instalaban.
    local ids=(com.vysp3r.ProtonPlus io.github.radiolamp.mangojuice io.github.benjamimgois.goverlay)
    local listing id scope found=()
    listing="$(flatpak list --app --columns=application,installation 2>/dev/null)"

    for id in "${ids[@]}"; do
        scope="$(awk -v id="$id" '$1 == id { print $2; exit }' <<<"$listing")"
        [[ -n "$scope" ]] && found+=("${id}:${scope}")
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        log_ok "Ninguna de las apps Flatpak del script está instalada"
        return 0
    fi

    log_info "Se desinstalarán: ${found[*]}"
    log_info "Flatpak y el remoto Flathub se dejan tal cual. Los datos de estas apps (~/.var/app/...) solo se ofrecen borrar con --purge-data."
    if ! confirm "¿Desinstalar estas apps Flatpak?"; then
        log_info "Se omite este bloque"
        return 0
    fi

    local entry
    for entry in "${found[@]}"; do
        id="${entry%%:*}"
        scope="${entry##*:}"
        if [[ "$scope" == "user" ]]; then
            run flatpak uninstall --user -y "$id" \
                && log_ok "$id desinstalado" \
                || { log_err "No se pudo desinstalar $id"; FAILURES+=("flatpak $id"); }
        else
            run sudo flatpak uninstall --system -y "$id" \
                && log_ok "$id desinstalado" \
                || { log_err "No se pudo desinstalar $id"; FAILURES+=("flatpak $id"); }
        fi
    done
}

# ---------------------------------------------------------------------------
# 3. MangoHud compilado (instalado con "ninja install")
# ---------------------------------------------------------------------------
#
# dpkg no conoce estos ficheros, así que no se quitan con apt. Se borran solo
# las rutas conocidas, y solo si NO pertenecen a ningún paquete de Debian (si
# algún día instalas el mangohud de Debian, sus ficheros no se tocan).
step_mangohud() {
    log_step "3/7 · MangoHud compilado desde fuente"

    local candidates=(
        /usr/bin/mangohud
        /usr/bin/mangoplot
        /usr/bin/mangohudctl
        /usr/lib/x86_64-linux-gnu/mangohud
        /usr/share/doc/mangohud
        /usr/share/vulkan/implicit_layer.d/MangoHud*.json
        /usr/share/man/man1/mangohud.1*
    )
    local path found=() owned=()
    for path in "${candidates[@]}"; do
        [[ -e "$path" || -L "$path" ]] || continue
        if dpkg -S "$path" &>/dev/null; then
            owned+=("$path")
        else
            found+=("$path")
        fi
    done

    if [[ ${#owned[@]} -gt 0 ]]; then
        log_info "Pertenecen a un paquete de Debian; NO se tocan: ${owned[*]}"
    fi

    if [[ ${#found[@]} -eq 0 ]]; then
        log_ok "No hay ficheros de MangoHud compilado a mano"
        return 0
    fi

    log_info "Se borrarán estas rutas (instaladas con ninja, sin paquete):"
    printf '      · %s\n' "${found[@]}"
    if ! confirm "¿Borrar estos ficheros de MangoHud?"; then
        log_info "Se omite este bloque"
        return 0
    fi

    if run sudo rm -rf -- "${found[@]}"; then
        log_ok "MangoHud compilado eliminado"
    else
        log_err "No se pudieron borrar todos los ficheros de MangoHud"
        FAILURES+=("ficheros de MangoHud")
        return 1
    fi

    # Aviso informativo: restos con nombre mangohud que no son de ningún paquete.
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local leftover f
        leftover="$(find /usr -xdev -iname '*mangohud*' 2>/dev/null | while read -r f; do
            dpkg -S "$f" &>/dev/null || printf '%s\n' "$f"
        done)"
        if [[ -n "$leftover" ]]; then
            log_warn "Quedan estos ficheros con nombre 'mangohud' que no son de ningún paquete (revísalos a mano):"
            sed 's/^/      · /' <<<"$leftover"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 4. Ficheros de configuración creados por el script
# ---------------------------------------------------------------------------
#
# Cada fichero solo se borra si lleva la marca (o el contenido exacto) que
# escribe setup-gaming-debian-sid.sh. Si lo has modificado a mano, no se toca.
step_config_files() {
    log_step "4/7 · Ficheros de configuración del script"

    local wrapper="/usr/local/bin/game-performance"
    local wrapper_marker="# game-performance v2 -- instalado por setup-gaming-debian-sid.sh"
    local gamemode_ini="${HOME}/.config/gamemode.ini"
    local gamemode_marker="# gamemode.ini -- configurado por setup-gaming-debian-sid.sh"
    local sysctl_file="/etc/sysctl.d/80-gamecompatibility.conf"
    local ntsync_file="/etc/modules-load.d/ntsync.conf"

    local to_remove_sudo=() to_remove_user=() ntsync_found=0 sysctl_found=0

    if [[ -f "$wrapper" ]]; then
        if grep -qF "$wrapper_marker" "$wrapper" 2>/dev/null; then
            to_remove_sudo+=("$wrapper")
        else
            log_info "$wrapper existe pero no lleva la marca del script: se deja intacto"
        fi
    fi

    if [[ -f "$gamemode_ini" ]]; then
        if grep -qF "$gamemode_marker" "$gamemode_ini" 2>/dev/null; then
            to_remove_user+=("$gamemode_ini")
        else
            log_info "$gamemode_ini existe pero no lleva la marca del script: se deja intacto (es tu configuración)"
        fi
    fi

    if [[ -f "$sysctl_file" ]]; then
        if [[ "$(grep -vE '^[[:space:]]*(#|$)' "$sysctl_file")" == "vm.max_map_count=2147483642" ]]; then
            to_remove_sudo+=("$sysctl_file")
            sysctl_found=1
        else
            log_info "$sysctl_file tiene contenido distinto al del script: se deja intacto"
        fi
    fi

    if [[ -f "$ntsync_file" ]]; then
        if [[ "$(grep -vE '^[[:space:]]*(#|$)' "$ntsync_file")" == "ntsync" ]]; then
            to_remove_sudo+=("$ntsync_file")
            ntsync_found=1
        else
            log_info "$ntsync_file tiene contenido distinto al del script: se deja intacto"
        fi
    fi

    if [[ ${#to_remove_sudo[@]} -eq 0 && ${#to_remove_user[@]} -eq 0 ]]; then
        log_ok "No hay ficheros de configuración del script que quitar"
    else
        log_info "Se borrarán:"
        printf '      · %s\n' "${to_remove_sudo[@]}" "${to_remove_user[@]}"
        if confirm "¿Borrar estos ficheros?"; then
            local f
            for f in "${to_remove_sudo[@]}"; do
                run sudo rm -f -- "$f" && log_ok "Borrado $f" \
                    || { log_err "No se pudo borrar $f"; FAILURES+=("$f"); }
            done
            for f in "${to_remove_user[@]}"; do
                run rm -f -- "$f" && log_ok "Borrado $f" \
                    || { log_err "No se pudo borrar $f"; FAILURES+=("$f"); }
            done

            if [[ "$sysctl_found" -eq 1 ]]; then
                log_info "vm.max_map_count sigue activo con el valor anterior hasta el próximo reinicio."
            fi

            # ntsync: se descarga solo si es un módulo cargado y sin uso.
            if [[ "$ntsync_found" -eq 1 ]]; then
                local refs
                refs="$(lsmod 2>/dev/null | awk '$1 == "ntsync" { print $3 }')"
                if [[ -z "$refs" ]]; then
                    log_info "El módulo ntsync no está cargado (o está integrado en el kernel): nada que descargar"
                elif [[ "$refs" == "0" ]]; then
                    run sudo modprobe -r ntsync && log_ok "Módulo ntsync descargado" \
                        || log_warn "No se pudo descargar el módulo ntsync; se irá solo al reiniciar"
                else
                    log_warn "ntsync está en uso ahora mismo; se descargará solo al reiniciar"
                fi
            fi
        else
            log_info "Se omite la eliminación de ficheros"
        fi
    fi

    # --- pci_dev en MangoHud.conf (pregunta aparte; -y no la acepta) ---
    local mh_conf="${HOME}/.config/MangoHud/MangoHud.conf"
    if [[ -f "$mh_conf" ]] && grep -q '^pci_dev=' "$mh_conf"; then
        log_info "MangoHud.conf contiene: $(grep -m1 '^pci_dev=' "$mh_conf")"
        if confirm_always "¿Quitar solo la línea pci_dev de ${mh_conf}? (el resto de tu configuración se conserva)"; then
            run cp -- "$mh_conf" "${mh_conf}.bak.$(date +%Y%m%d%H%M%S)"
            run sed -i '/^pci_dev=/d' "$mh_conf" \
                && log_ok "Línea pci_dev eliminada (copia de seguridad creada)" \
                || FAILURES+=("pci_dev de MangoHud.conf")
        fi
    fi
}

# ---------------------------------------------------------------------------
# 5. Enlace de compatibilidad de wineserver (opcional)
# ---------------------------------------------------------------------------
#
# setup-gaming-debian-sid.sh puede crear /usr/local/bin/wineserver porque
# Wine 10 de Debian dejó de instalar el lanzador en /usr/bin. No se elimina
# automáticamente: puede haber sido creado manualmente. Solo se ofrece si
# es un symlink que apunta exactamente a un wineserver perteneciente a
# libwine/wine64 instalado.
step_wineserver_link() {
    log_step "5/7 · Enlace de compatibilidad wineserver"

    local link="/usr/local/bin/wineserver"

    if [[ ! -L "$link" ]]; then
        if [[ -e "$link" ]]; then
            log_info "$link existe pero no es un enlace simbólico: se deja intacto"
        else
            log_ok "No hay enlace de compatibilidad wineserver que quitar"
        fi
        return 0
    fi

    local target
    target="$(readlink -f -- "$link" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
        log_info "$link es un enlace roto: se deja intacto"
        return 0
    fi

    # Sin "cmd | grep -q" / "cmd | awk ... exit": con 'set -o pipefail', si el
    # consumidor sale antes de que termine dpkg -L (que en libwine lista miles
    # de ficheros), dpkg muere por SIGPIPE y la comprobación daba un falso
    # negativo (probado: el enlace válido casi nunca se ofrecía). Se captura
    # primero la salida completa y se busca sobre ella.
    local pkg real_wineserver="" pkg_status pkg_files
    for pkg in libwine wine64; do
        pkg_status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null)"
        [[ "$pkg_status" == "ii "* ]] || continue
        pkg_files="$(dpkg -L "$pkg" 2>/dev/null)"
        if grep -qxF -- "$target" <<<"$pkg_files"; then
            real_wineserver="$target"
            break
        fi
    done

    if [[ -z "$real_wineserver" ]]; then
        log_info "$link no apunta a un wineserver perteneciente a libwine/wine64: se deja intacto"
        return 0
    fi

    log_info "$link -> $real_wineserver"
    if confirm_always "¿Eliminar este enlace de wineserver? (puede haberlo creado el setup o tú a mano; decide tú)"; then
        run sudo rm -f -- "$link" \
            && log_ok "Enlace de compatibilidad eliminado" \
            || { log_err "No se pudo eliminar $link"; FAILURES+=("enlace wineserver"); }
    else
        log_info "Se conserva el enlace de wineserver"
    fi
}

# ---------------------------------------------------------------------------
# 6. deb-src activado para compilar MangoHud (opcional)
# ---------------------------------------------------------------------------
step_deb_src() {
    log_step "6/7 · deb-src en debian.sources (opcional)"

    local sources_file="/etc/apt/sources.list.d/debian.sources"
    if [[ ! -f "$sources_file" ]] || ! grep -qE '^Types: deb deb-src$' "$sources_file"; then
        log_ok "No hay líneas 'Types: deb deb-src' que revertir"
        return 0
    fi

    log_info "setup-gaming-debian-sid.sh activó deb-src para poder compilar MangoHud, pero es posible que tú también lo uses. Por eso -y no lo revierte."
    if confirm_always "¿Volver a 'Types: deb' (desactivar deb-src) en ${sources_file}?"; then
        run sudo cp -- "$sources_file" "${sources_file}.bak.$(date +%Y%m%d%H%M%S)"
        if run sudo sed -i 's/^Types: deb deb-src$/Types: deb/' "$sources_file"; then
            log_ok "deb-src desactivado (copia de seguridad creada). Ejecuta 'sudo apt update' para refrescar los índices."
        else
            FAILURES+=("deb-src en debian.sources")
        fi
    fi
}

# ---------------------------------------------------------------------------
# 7. Datos de usuario (solo con --purge-data)
# ---------------------------------------------------------------------------
#
# Aquí viven las bibliotecas de juegos, los prefijos de Proton y, a veces,
# partidas guardadas locales que no estén en la nube. Borrarlo es
# irreversible: por eso solo se ofrece con --purge-data, se muestra antes lo
# que ocupa cada carpeta y hay que escribir BORRAR. -y no lo acepta.
step_user_data() {
    log_step "7/7 · Datos de usuario"

    local paths=(
        "${HOME}/.steam"
        "${HOME}/.steampath"
        "${HOME}/.steampid"
        "${HOME}/.local/share/Steam"
        "${HOME}/Games"
        "${HOME}/.config/heroic"
        "${HOME}/.config/lutris"
        "${HOME}/.local/share/lutris"
        "${HOME}/.cache/lutris"
        "${HOME}/.config/MangoHud"
        "${HOME}/.config/goverlay"
        "${HOME}/.config/protontricks"
        "${HOME}/.cache/winetricks"
        "${HOME}/.var/app/com.vysp3r.ProtonPlus"
        "${HOME}/.var/app/io.github.radiolamp.mangojuice"
        "${HOME}/.var/app/io.github.benjamimgois.goverlay"
    )

    local existing=() p size
    for p in "${paths[@]}"; do
        [[ -e "$p" || -L "$p" ]] && existing+=("$p")
    done

    if [[ ${#existing[@]} -eq 0 ]]; then
        log_ok "No hay datos de juego en tu carpeta personal"
        return 0
    fi

    log_info "Datos de juego encontrados:"
    for p in "${existing[@]}"; do
        size="$(du -sh -- "$p" 2>/dev/null | cut -f1)"
        printf '      · %-8s %s\n' "${size:-?}" "$p"
    done

    if [[ "$PURGE_DATA" -ne 1 ]]; then
        log_info "Se CONSERVAN (contienen tus juegos y posibles partidas locales). Para ofrecer borrarlos, ejecuta con --purge-data."
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[simulación] Se pediría escribir BORRAR para eliminarlos."
        return 0
    fi

    log_warn "Borrar estos datos es IRREVERSIBLE: juegos instalados, prefijos de Proton y posibles partidas guardadas locales."
    if [[ ! -t 0 ]]; then
        log_info "Sin terminal interactiva: no se borra nada"
        return 0
    fi

    local answer
    read -rp "  Escribe BORRAR (en mayúsculas) para eliminarlos, o pulsa Enter para conservarlos: " answer
    if [[ "$answer" != "BORRAR" ]]; then
        log_info "Se conservan los datos"
        return 0
    fi

    for p in "${existing[@]}"; do
        # Solo se borra dentro de la carpeta personal y nunca la propia carpeta.
        if [[ "$p" == "${HOME}/"* && "$p" != "${HOME}/" && "$p" != *".."* ]]; then
            rm -rf -- "$p" && log_ok "Borrado $p" \
                || { log_err "No se pudo borrar $p"; FAILURES+=("$p"); }
        else
            log_warn "Ruta fuera de la carpeta personal, se omite: $p"
        fi
    done
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_ok "Simulación terminada: no se ha cambiado nada."
        return 0
    fi

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        log_warn "Algunos pasos fallaron:"
        printf '      · %s\n' "${FAILURES[@]}"
    else
        log_ok "Limpieza terminada sin errores."
    fi

    cat <<EOF

  Se ha dejado intacto a propósito:
    - power-profiles-daemon, Flatpak y el remoto Flathub.
    - La arquitectura i386 y los paquetes de desarrollo.
    - Tus datos de juego (salvo que hayas usado --purge-data).

  Se recomienda reiniciar para que dejen de estar activos los valores del
  kernel que ya estaban cargados (por ejemplo vm.max_map_count).

  Para comprobar que no quedan paquetes de juego:
      dpkg -l | grep -Ei 'steam|heroic|gamemode|winetricks|protontricks|lutris|gamescope'
EOF
}

# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_user

    printf 'cleanup-gaming-debian-sid.sh %s\n' "$VERSION"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "Modo simulación: no se cambia nada."
    fi

    step_packages
    step_flatpak
    step_mangohud
    step_config_files
    step_wineserver_link
    step_deb_src
    step_user_data
    step_summary
}

main "$@"
