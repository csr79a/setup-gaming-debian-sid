# Manual — setup-gaming-debian-sid

Explicación detallada de cada paso de `setup-gaming-debian-sid.sh` y de `cleanup-gaming-debian-sid.sh`.

---

## Requisitos previos

- **Debian Sid (Unstable)** con KDE Plasma, ya configurado con [`setup-debian-sid.sh`](https://github.com/csr79a/debian-sid-setup) o equivalente. El script no funciona con otras suites.
- Usuario con permisos de `sudo` (no ejecutar el script como root).
- Conexión a internet.
- Repos en formato deb822 (`/etc/apt/sources.list.d/debian.sources`) apuntando a `unstable`/`sid`, con el componente **`contrib`** habilitado: `steam-installer`, `winetricks`, `protontricks`, `lutris` y `gamescope` viven ahí.
- `deb-src` habilitado solo hace falta para compilar MangoHud (paso 5); el script lo activa por sí mismo si `debian.sources` solo tiene `Types: deb`.

---

## 0. Comprobación de prerrequisitos

Antes de tocar nada, el script revisa todos los ficheros de repositorios que apunten a Debian: `debian.sources`, `/etc/apt/sources.list` y el resto de `*.sources` y `*.list` de `/etc/apt/sources.list.d`. Solo acepta las suites `unstable` y `sid`.

- Si encuentra cualquier otra suite (forky, trixie, trixie-security, bookworm, testing, stable...), **se detiene sin preguntar** y muestra las entradas conflictivas. No convierte ninguna suite automáticamente: hay que corregirlas o desactivarlas a mano (`setup-debian-sid.sh` repara `unstable-updates` en `debian.sources`).
- Los repositorios de terceros (Docker, Brave...) no se marcan: una entrada solo cuenta como "de Debian" si su URI es de `debian.org` o usa `debian-archive-keyring`.
- Si falta `debian.sources`, no se puede verificar la suite: el script avisa de que la compilación de MangoHud puede fallar por falta de `deb-src` y pide confirmación. Si no hay terminal interactiva para responder, se cancela por seguridad en vez de asumir una respuesta.

Después ejecuta `apt update`; si termina con errores, también pide confirmación antes de seguir.

## 1. Steam

Instala `steam-installer`, el paquete de Steam del repositorio oficial de Debian (componente `contrib`), en vez de descargar el `.deb` de Valve. El script:

1. Si ya está instalado `steam-launcher` (el paquete de Valve), lo respeta y omite el paso: no mezcla los dos empaquetados.
2. Habilita la arquitectura `i386` si todavía no estaba (`dpkg --add-architecture i386` + `apt update`), porque Steam necesita librerías de 32 bits incluso en sistemas de 64 bits.
3. Comprueba que `steam-installer` esté disponible; si no, explica que hay que habilitar `contrib`.
4. Lo instala con `apt`. Durante la instalación Steam muestra su acuerdo de licencia (pantalla azul en la terminal): hay que leerlo y aceptarlo.

Se actualiza con `sudo apt upgrade`. El cliente de Steam y los juegos se actualizan solos desde Valve. En el primer arranque, Steam descarga el cliente; el script no lo lanza.

## 2. Flatpak + Flathub

Instala/actualiza `flatpak` vía `apt` (idempotente: si ya está en la última versión no hace nada, y si hay una nueva la aplica) y agrega el remoto `flathub`, necesario para ProtonPlus y MangoJuice.

## 3. ProtonPlus

[ProtonPlus](https://github.com/Vysp3r/ProtonPlus) es una interfaz gráfica para gestionar builds de Proton-GE, Luxtorpeda, Wine-GE, etc. En Debian no existe paquete nativo, y el propio proyecto indica que **Flathub es el método de instalación principal**. Si ya está instalado, el script corre `flatpak update` en vez de `flatpak install`, que es el comando correcto para comprobar/aplicar una versión más nueva.

## 4. Heroic Games Launcher (auto-actualización)

1. Consulta `https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest`.
2. Extrae la URL del asset que termina en `amd64.deb` (el paquete oficial de Debian/Ubuntu publicado por el proyecto).
3. Compara la versión publicada con la instalada (`dpkg-query -W -f='${Version}' heroic`) usando `dpkg --compare-versions ... ge ...` en vez de comparar strings, para evitar reinstalaciones innecesarias por diferencias de formato.
4. Si la instalada ya es igual o más nueva, no hace nada.
5. Si no, descarga el `.deb` a un archivo temporal y lo instala con `sudo apt install -y`, que actualiza sobre la instalación previa si existía.

La configuración de Heroic (cuentas, biblioteca, ajustes) vive en `~/.config/heroic`, separada del paquete, así que no se pierde nada al actualizar.

## 5. GameMode + MangoHud (compilado con NVML) + MangoJuice

### GameMode

Se instala/actualiza vía `apt`, directo desde los repos de Sid.

### MangoHud

El paquete `mangohud` de Debian es la build DFSG (Debian Free Software Guidelines), compilada **sin soporte NVML**, la librería propietaria de NVIDIA necesaria para leer % de uso, VRAM y temperatura. Con una GPU NVIDIA, ese paquete no muestra esos datos aunque el resto del overlay funcione. Por eso el script compila MangoHud desde fuente:

1. **Comprueba NVML** buscando varios símbolos característicos (`get_instant_metrics_nvml`, `nvmlDeviceGetUtilizationRates`, etc.) en la librería instalada. Se busca más de uno porque el compilador puede omitir alguno puntual según la build sin que falte NVML.
2. **Consulta el último tag estable** de upstream (formato `vX.Y.Z`, ignorando release candidates) con `git ls-remote`.
3. **Compara** la parte `X.Y.Z` de `mangohud --version` con ese tag. Si ya coincide y hay NVML, no recompila. Si falta NVML o la versión no coincide, compila.
4. **Fija siempre un tag**, nunca el `HEAD` de la rama de desarrollo: upstream ("MangoHud next") ha ido añadiendo dependencias nuevas sin aviso y el `HEAD` puede romper la compilación o traer regresiones. Con un tag solo recompila cuando sale una release nueva.
5. **Sin conectividad**: si no puede consultar el tag y ya hay una build con NVML instalada, la deja tal cual. Si no hay ninguna, omite el paso y el resto del script continúa.

Para compilar:

- Si el paquete `mangohud` de apt está instalado, lo elimina antes para que `ninja install` no choque con `dpkg`. Avisa de que, si la compilación falla, MangoHud quedará sin instalar.
- Activa `deb-src` en `debian.sources` si hace falta (solo modifica las líneas `Types: deb`), ejecuta `apt build-dep mangohud` e instala explícitamente dependencias que el `build-dep` del paquete viejo no cubre: `libcap-dev`, `libyaml-cpp-dev`, `libwayland-egl-backend-dev`, `wayland-protocols` y `libgbm-dev`.
- Clona el tag con `git clone --recursive --branch <tag>` en un directorio temporal y compila con `meson` y `ninja` (`--prefix=/usr -Dwith_nvml=enabled -Dwith_x11=enabled -Dwith_wayland=enabled`), forzando un `PKG_CONFIG_PATH` estándar de Debian.
- Si `meson` pide una dependencia que falta, usa `apt-file` para averiguar qué paquete Debian provee su `<dependencia>.pc` (solo en rutas estándar de pkg-config) y lo instala, reintentando hasta 6 veces.
- El directorio temporal se borra siempre, incluso con Ctrl+C.

Al terminar, **verifica automáticamente** que la build tenga NVML y que `mangohud --version` corresponda al tag compilado. Si el formato de versión no coincide, avisa (la consecuencia sería recompilar en cada ejecución, no un fallo).

**Limitación:** MangoHud se compila solo en 64 bits, así que no habrá overlay en juegos de 32 bits.

### MangoJuice (opcional)

Interfaz gráfica (Flatpak, `io.github.radiolamp.mangojuice`) para configurar el overlay. Es una alternativa: el script **pregunta** si quieres instalarla (`[s/N]`; sin terminal interactiva se omite). Si ya está instalada, se actualiza sin preguntar. MangoHud se puede configurar igualmente editando `~/.config/MangoHud/MangoHud.conf`.

Si MangoJuice no llegara a leer o escribir esa carpeta por el sandbox, prueba:

```
flatpak override --user --filesystem=xdg-config/MangoHud io.github.radiolamp.mangojuice
```

### Uso

En las opciones de lanzamiento de un juego en Steam (o en el comando de Heroic/Lutris):

```
gamemoderun mangohud %command%
```

## 6. Winetricks y Protontricks

Ambos están empaquetados de forma nativa en Debian, en el componente `contrib`: no hace falta Flatpak ni compilar nada. Si `contrib` no está habilitado, el script avisa antes de intentar, porque `apt` solo diría "Unable to locate package".

Después de instalarlos:

- **wineserver**: Debian (wine 10.0~repack-12 y posteriores) ya no instala un lanzador `/usr/bin/wineserver` y Winetricks falla con `wineserver not found!`. Si Wine está instalado y `wineserver` no está en el `PATH`, el script crea un enlace `/usr/local/bin/wineserver` hacia el binario real (localizado con `dpkg -L`, no con una ruta fija) y comprueba que responde. No toca nada si ya funciona ni ficheros ajenos.
- **wine32:i386**: Wine 10 ejecuta aplicaciones de 32 bits de forma nativa en amd64 (WoW64), así que no es imprescindible. Se intenta instalar, pero antes se simula: solo se instala si la simulación no da errores ni elimina paquetes. Si hay un conflicto temporal de dependencias en Sid, informa y continúa sin él.

Uso:

```
protontricks -s <nombre del juego>   # buscar el AppID
protontricks <AppID> <acción>         # ej.: vcrun2019, corefonts
```

## 7. `~/.config/gamemode.ini`

Crea el fichero con un gobernador de CPU dinámico **solo si no existe**. Es una preferencia personal, no algo con un valor correcto universal: si ya existía (con o sin la marca del script), no lo toca, para no pisar tus ajustes en cada ejecución.

El gobernador se elige leyendo `scaling_available_governors` de tu driver cpufreq:

- `schedutil` si está disponible (drivers clásicos, como `acpi-cpufreq`, o `amd_pstate` en modo passive/guided).
- `powersave` si no. Con `amd_pstate`/`intel_pstate` en modo activo, `schedutil` no existe y `powersave` ya es dinámico (el kernel lo traduce a un hint EPP y escala según la carga).

No incluye `desiredprof`: es un bug conocido y abierto en GameMode (issue #539 de FeralInteractive/gamemode) por el que se ignora incluso con el fichero de ejemplo oficial. Para comprobar qué gobernador se aplicó: `gamemoded -t`.

## 8. `pci_dev` de la GPU NVIDIA en MangoHud.conf

En portátiles con GPU híbrida (NVIDIA dedicada + integrada Intel/AMD), MangoHud —incluso con NVML— puede fallar al leer el % de uso de GPU si no sabe a cuál de las dos consultar. El script:

1. Comprueba si hay `nvidia-smi` disponible (si no, omite el paso: no hay GPU NVIDIA o falta el driver).
2. Obtiene el `pci.bus_id` vía `nvidia-smi --query-gpu=pci.bus_id` y lo convierte al formato de 4 dígitos de dominio que espera MangoHud (`0000:01:00.0`).
3. Escribe o actualiza la línea `pci_dev=` en `~/.config/MangoHud/MangoHud.conf`.
4. Si detecta una línea `gpu_list=` en ese mismo archivo, avisa de que puede entrar en conflicto con `pci_dev` (algunas herramientas, como MangoJuice, la añaden solas) y hacer que se lea la GPU equivocada. Si el % de GPU sale mal, comenta o borra esa línea a mano.

## 9. Herramientas de diagnóstico (mesa-utils)

Instala/actualiza `mesa-utils` (`glxgears`, `glxinfo`) vía `apt`. No forma parte del setup de gaming en sí; sirve para probar drivers y MangoHud rápidamente sin abrir un juego completo.

## 10. `vm.max_map_count`

Varios juegos y motores modernos necesitan un límite más alto. El script escribe:

```
vm.max_map_count=2147483642
```

en `/etc/sysctl.d/80-gamecompatibility.conf` y aplica el cambio con `sysctl --system`.

## 11. ntsync

Si `/dev/ntsync` no existe, intenta cargar el módulo con `modprobe ntsync` y espera unos segundos a que udev cree el dispositivo. La señal de que funciona es que exista `/dev/ntsync`, tanto si `ntsync` está integrado en el kernel (`CONFIG_NTSYNC=y`) como si es un módulo (`=m`).

- Si es un módulo cargable, lo deja persistente en `/etc/modules-load.d/ntsync.conf` para que cargue en cada arranque. Si está integrado, no hay nada que configurar.
- Si no se puede activar, explica la causa: módulos del kernel ausentes tras actualizar sin reiniciar, kernel sin `CONFIG_NTSYNC` (se incorporó en el kernel 6.14, hace falta uno más reciente), u otro motivo visible con `dmesg | tail`.

Solo lo aprovechan versiones de Wine/Proton con soporte ntsync. Con un juego abierto, `sudo lsof /dev/ntsync` muestra si lo está usando.

## 12. Wrapper `game-performance`

Sustituye al enfoque de alias de bash (`gaming-on`/`gaming-off`), que **no** funciona en las opciones de lanzamiento de Steam: un alias solo existe en una sesión de terminal interactiva con `~/.bashrc` cargado, y Steam ejecuta el comando directamente.

`game-performance` es un script wrapper real en `/usr/local/bin/game-performance`:

1. Instala y activa `power-profiles-daemon` si hace falta.
2. Al ejecutarse, guarda el perfil de energía activo **antes** de arrancar (solo si no puede leerlo, asume "balanced").
3. Si el perfil "performance" existe en el equipo, lo activa; si no, avisa y sigue sin tocarlo.
4. Inhibe el salvapantallas/suspensión mientras el proceso corre, vía `systemd-inhibit`.
5. Ejecuta el comando que le pases y espera a que termine.
6. Restaura el perfil anterior, tanto si el comando termina bien como si falla o se interrumpe (trap `EXIT`).

Uso en Steam, junto con GameMode (no en su lugar):

```
game-performance gamemoderun mangohud %command%
```

Uso manual en terminal (también sirve para Heroic o Lutris):

```
game-performance <comando> [argumentos...]
```

GameMode sigue siendo complementario: aporta prioridad de proceso, posible ajuste de GPU y el indicador que MangoHud muestra en el overlay, cosas que `game-performance` no cubre.

**No es "úsalo siempre" ni "no lo uses nunca":** depende del equipo y del juego. Empieza con `gamemoderun mangohud %command%` y mira el overlay; si los FPS te alcanzan y no hay stuttering, déjalo así. Forzar "performance" puede dar los mismos FPS con más temperatura y ruido de ventilador. Si notas FPS bajos o caídas, añade `game-performance` y compara.

## 13. Lutris (opcional)

Está en `contrib`, en una versión reciente, así que no hace falta Flatpak. Si ya está instalado, se actualiza sin preguntar; si no, se ofrece con una pregunta `[s/N]` (sin terminal interactiva se omite).

## 14. Gamescope (opcional)

Micro-compositor de Valve para escalado y pantalla completa, también en `contrib`. Es situacional, así que solo se instala si respondes que sí (o si ya lo tenías, en cuyo caso se actualiza). Con GPU híbrida NVIDIA puede requerir pruebas según el juego. Uso en Steam:

```
gamescope -f -- %command%
```

---

## Verificaciones finales

Al terminar, el script comprueba (sin lanzar Steam ni juegos) el estado de cada componente y lo clasifica en tres categorías:

| Estado | Significado |
|---|---|
| `OK` | Instalado/preparado |
| `ADVERTENCIA` | Requiere una acción manual, o no es lo ideal pero no rompe nada |
| `NO DISPONIBLE` | No se pudo instalar o no responde |

Ninguna de las tres cambia el código de salida del script. Comprueba Wine, wineserver, Winetricks, Protontricks, Steam, MangoHud (con NVML), MangoJuice, GameMode, `gamemode.ini`, `power-profiles-daemon`, `game-performance` y ntsync, y lista los pasos manuales pendientes si los hay.

Sobre Steam: si sus carpetas aún no existen (normal en una instalación limpia), se deja como paso manual: abre Steam una vez y deja que termine de descargarse. Si existen y Protontricks no encuentra Steam, el script crea el enlace `~/.local/share/Steam` → `~/.steam/debian-installation` como último recurso, sin tocar nada si ya existe. "Protontricks aún no lista juegos" es normal hasta que lances uno con Proton.

---

## Recomendaciones que el script no automatiza

- **Activar Steam Play para todos los títulos**: Steam → Configuración → Compatibilidad → "Habilitar Steam Play para todos los demás títulos", y elegir ahí la versión de Proton (o una de ProtonPlus) por defecto.
- **CoreCtrl / LACT** (overclock, fan curves): deliberadamente no incluidos, mismo criterio que en los proyectos de Fedora.
- Si `apt upgrade` llegara a reinstalar el paquete `mangohud` de Debian y pisar el binario compilado, basta con volver a correr el script para recompilarlo.

---

# cleanup-gaming-debian-sid

Revierte lo que instala y configura `setup-gaming-debian-sid.sh`.

## Opciones

```
./cleanup-gaming-debian-sid.sh [-n|--dry-run] [-y|--yes] [--purge-data] [-h|--help]
```

| Opción | Efecto |
|---|---|
| `-n`, `--dry-run` | Muestra lo que haría sin cambiar nada (no pide `sudo`) |
| `-y`, `--yes` | Acepta las confirmaciones normales (paquetes, Flatpak, MangoHud y ficheros del script). **Nunca** acepta el borrado de datos, el `autoremove`, la línea `pci_dev` ni el `deb-src` |
| `--purge-data` | Además ofrece borrar los datos de usuario. Es irreversible: pide escribir `BORRAR` y muestra antes lo que ocupa cada carpeta |

Cada bloque pide confirmación. Lo recomendable es empezar siempre con `--dry-run`.

## Qué elimina

1. **Paquetes de apt**: `steam-installer`, `heroic`, `gamemode`, `winetricks`, `protontricks`, `mesa-utils`, `lutris` y `gamescope`. Se purgan sin pantallas de debconf. `steam-launcher` no se elimina (el setup lo respeta si ya estaba). Después muestra la lista de `apt autoremove` y pregunta aparte, porque en Sid puede incluir paquetes ajenos a los juegos.
2. **Flatpak**: ProtonPlus, MangoJuice y GOverlay (este último, de versiones anteriores del setup).
3. **MangoHud compilado** (instalado con `ninja install`, que `dpkg` no conoce): borra sus rutas conocidas mostrando antes la lista, y solo si no pertenecen a ningún paquete de Debian. Al terminar avisa de cualquier resto llamado `mangohud` que no sea de un paquete.
4. **Ficheros creados por el script**, solo si llevan su marca o tienen exactamente el contenido que escribe el script (si los has modificado a mano, no se tocan): `/usr/local/bin/game-performance`, `~/.config/gamemode.ini`, `/etc/sysctl.d/80-gamecompatibility.conf` y `/etc/modules-load.d/ntsync.conf`. Además, la línea `pci_dev` de `MangoHud.conf` (con copia de seguridad y pregunta aparte).
5. **Enlace `/usr/local/bin/wineserver`**: solo se ofrece eliminarlo si apunta exactamente a un `wineserver` perteneciente a Wine instalado, y decides tú (puede haberlo creado el setup o tú a mano).
6. **`deb-src`** en `debian.sources`: opcional, con copia de seguridad. Se pregunta aparte porque es posible que también lo uses para otras cosas.
7. **Datos de usuario** (solo con `--purge-data`): `~/.steam`, `~/.local/share/Steam`, `~/Games`, `~/.config/heroic`, `~/.config/lutris`, `~/.config/MangoHud`, la configuración de Protontricks, la caché de Winetricks y los datos de las apps Flatpak (`~/.var/app/...`), entre otros.

## Qué NO toca

Es compartido con el resto del sistema:

- `power-profiles-daemon` (lo usa KDE), Flatpak y el remoto Flathub.
- La arquitectura i386 (la usan también las librerías de NVIDIA).
- Los paquetes de desarrollo instalados para compilar.
- Tus datos de juego, salvo con `--purge-data`.
- `vm.max_map_count`: al quitar el fichero de configuración, el valor sigue activo hasta el próximo reinicio.

Se recomienda reiniciar al terminar. Para comprobar que no quedan paquetes de juego:

```
dpkg -l | grep -Ei 'steam|heroic|gamemode|winetricks|protontricks|lutris|gamescope'
```
