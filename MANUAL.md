# Manual — setup-gaming-debian-sid

Explicación detallada de cada paso del script.

---

## Requisitos previos

- Debian Sid (Unstable) con KDE Plasma, ya configurado con [`setup-debian-sid.sh`](https://github.com/csr79a/debian-sid-setup) o equivalente.
- Usuario con permisos de `sudo` (no ejecutar el script como root).
- Conexión a internet.
- Repos en formato deb822 (`/etc/apt/sources.list.d/debian.sources`) apuntando a `unstable` o `testing`. No es estrictamente obligatorio para la mayoría de los pasos (apt resuelve dependencias solo), pero sin esto la compilación de MangoHud con NVML (paso 5) puede fallar por falta de `deb-src`. El script lo comprueba al arrancar y, si no lo detecta, pide confirmación explícita antes de seguir.

---

## 0. Comprobación de prerrequisitos

Antes de tocar nada, el script revisa si `/etc/apt/sources.list.d/debian.sources` existe y apunta a `unstable`/`testing`. Si falta el archivo o apunta a otra suite (por ejemplo Debian estable), avisa del riesgo — la compilación de MangoHud (librerías más nuevas) y ntsync (kernel reciente) pueden fallar en un sistema no-Sid — y pide confirmar si se quiere continuar de todos modos. Si no hay una terminal interactiva para responder, el script se cancela por seguridad en vez de asumir una respuesta.

## 1. Steam

Debian no tiene un repo propio con Steam empaquetado (a diferencia de RPM Fusion en Fedora), así que el script:

1. Habilita la arquitectura `i386` si todavía no estaba (`dpkg --add-architecture i386` + `apt update`) — Steam necesita librerías de 32 bits incluso en sistemas 64 bits.
2. Descarga el `.deb` **oficial** de Valve (`https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb`).
3. Lo instala con `apt install ./steam.deb`, que resuelve automáticamente todas las dependencias.

Si ya detecta `steam-launcher` o `steam-installer` instalado, omite el paso.

## 2. Flatpak + Flathub

Instala/actualiza `flatpak` vía `apt` (idempotente: si ya está en la última versión no hace nada, y si hay una nueva la aplica) y agrega el remoto `flathub` — necesario para ProtonPlus y MangoJuice más adelante.

## 3. ProtonPlus

[ProtonPlus](https://github.com/Vysp3r/ProtonPlus) es una interfaz gráfica para gestionar builds de Proton-GE, Luxtorpeda, Wine-GE, etc. En Debian no existe paquete nativo, y el propio proyecto indica en su documentación que **Flathub es el método de instalación principal** (no una alternativa de segunda categoría). Si ya está instalado, el script corre `flatpak update` en vez de `flatpak install`, que es el comando correcto para comprobar/aplicar una versión más nueva.

## 4. Heroic Games Launcher (auto-actualización)

1. Consulta `https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest`
2. Extrae la URL del asset que termina en `amd64.deb` (el paquete oficial de Debian/Ubuntu publicado por el proyecto)
3. Compara la versión ahí publicada contra la versión instalada localmente (`dpkg-query -W -f='${Version}' heroic`), usando `dpkg --compare-versions ... ge ...` en vez de comparar strings — evita reinstalaciones innecesarias por diferencias de formato entre el string de dpkg y el parseado del nombre del `.deb`
4. Si la instalada ya es igual o más nueva, no hace nada
5. Si no, descarga el `.deb` a un archivo temporal y lo instala con `sudo apt install -y`, que actualiza sobre la instalación previa si existía

La configuración de Heroic (cuentas logueadas, biblioteca, ajustes) vive en `~/.config/Heroic`, separada del paquete, así que no se pierde nada al actualizar.

## 5. GameMode + MangoHud (compilado con NVML) + MangoJuice

- **GameMode**: se instala vía `apt`, directo desde los repos de Sid.

- **MangoHud**: el paquete `mangohud` de los repos de Debian es la build DFSG (Debian Free Software Guidelines), compilada **sin soporte NVML** (la librería propietaria de NVIDIA necesaria para leer % de uso, VRAM y temperatura de GPUs NVIDIA). Si tenés una GPU NVIDIA, ese paquete jamás va a mostrar esos datos, aunque el resto del overlay funcione. Por eso el script:
  1. Comprueba si el MangoHud ya instalado tiene NVML compilado, buscando varios símbolos característicos (`get_instant_metrics_nvml`, `nvmlDeviceGetUtilizationRates`, etc.) en la librería instalada — se busca más de un símbolo porque el compilador puede omitir alguno puntual según la build sin que falte NVML.
  2. Si no lo tiene, o si hay un commit más nuevo en el repositorio de upstream que el que está instalado (comparando hashes de git), desinstala el paquete `mangohud` de apt si estaba presente y compila la última versión desde fuente (`git clone` + `meson` + `ninja`) con `-Dwith_nvml=enabled -Dwith_x11=enabled -Dwith_wayland=enabled`.
  3. Antes de compilar, activa `deb-src` en `/etc/apt/sources.list.d/debian.sources` si hace falta, corre `apt build-dep mangohud`, e instala explícitamente algunas dependencias que no siempre cubre el `build-dep` del paquete viejo de Debian (`libcap-dev`, `libyaml-cpp-dev`, `libwayland-egl-backend-dev`, `wayland-protocols`, `libgbm-dev`) porque upstream ("MangoHud next") fue agregando requisitos nuevos que el `build-dep` no conoce.
  4. Si meson sigue pidiendo alguna dependencia que falte, el script usa `apt-file` para averiguar automáticamente qué paquete Debian la provee (buscando el archivo `<dependencia>.pc` en rutas estándar de pkg-config) y la instala, reintentando hasta 6 veces.
  5. Si no hay conectividad para consultar el último commit de upstream, no recompila y deja la versión ya instalada tal cual.

- **MangoJuice**: reemplaza a GOverlay como GUI de configuración del overlay de MangoHud. Se instala/actualiza vía Flatpak (`io.github.radiolamp.mangojuice`), con permisos correctos de fábrica hacia `~/.config/MangoHud` sin necesitar `flatpak override`.

Para usarlos juntos, en las opciones de lanzamiento de un juego en Steam (o en el comando de Heroic/Lutris):

```
gamemoderun mangohud %command%
```

Y para editar la configuración de MangoHud gráficamente, abrí MangoJuice desde el menú de aplicaciones.

## 6. `pci_dev` de la GPU NVIDIA en MangoHud.conf

En portátiles con GPU híbrida (NVIDIA dedicada + integrada Intel/AMD), MangoHud —incluso con NVML— puede fallar al leer el % de uso de GPU si no sabe a cuál de las dos consultar. El script:

1. Comprueba si hay `nvidia-smi` disponible (si no, omite el paso: no hay GPU NVIDIA o falta el driver).
2. Obtiene el `pci.bus_id` de la GPU vía `nvidia-smi --query-gpu=pci.bus_id` y lo convierte al formato de 4 dígitos de dominio que espera MangoHud (`0000:01:00.0`).
3. Escribe o actualiza la línea `pci_dev=` en `~/.config/MangoHud/MangoHud.conf`.
4. Si detecta una línea `gpu_list=` en ese mismo archivo, avisa de que puede entrar en conflicto con `pci_dev` (algunas herramientas, como MangoJuice, la agregan sola) y hacer que se lea la GPU equivocada — si el % de GPU sale mal, hay que comentar o borrar esa línea a mano.

## 7. Herramientas de diagnóstico (mesa-utils)

Instala `mesa-utils` (`glxgears`, `glxinfo`) vía `apt`. No forma parte del setup de gaming en sí; sirve para probar drivers y MangoHud rápidamente sin depender de abrir un juego completo.

## 8. `vm.max_map_count`

Varios juegos y motores modernos necesitan un límite más alto. El script escribe:

```
vm.max_map_count=2147483642
```

en `/etc/sysctl.d/80-gamecompatibility.conf` y aplica el cambio con `sysctl --system`.

## 9. ntsync

Comprueba si `ntsync` ya está activo (built-in, vía `/dev/ntsync`, o como módulo cargable vía `lsmod`), lo carga con `modprobe` si el kernel lo soporta (kernel ≥ 6.14) y no está cargado, y lo deja persistente en `/etc/modules-load.d/ntsync.conf` para que cargue en cada arranque (solo si es módulo, no hace falta si está compilado como built-in). Debian Sid suele traer kernels bastante recientes, así que normalmente no debería haber problema — si tu kernel es más viejo, hay que actualizarlo primero.

## 10. Wrapper `game-performance`

Sustituye al enfoque de alias de bash (`gaming-on`/`gaming-off`) usado en versiones anteriores del script, que **no** funciona dentro de las opciones de lanzamiento de Steam: un alias solo existe en una sesión de terminal interactiva con `~/.bashrc` cargado, y Steam ejecuta el comando directamente, sin pasar por bash interactivo.

`game-performance` es un script wrapper real instalado en `/usr/local/bin/game-performance` (en el `PATH`):

1. Instala y activa `power-profiles-daemon` si hace falta.
2. Al ejecutarse, guarda el perfil de energía activo **antes** de arrancar (no asume "balanced" fijo).
3. Si el perfil "performance" existe en el equipo, lo activa; si no, avisa y sigue sin tocarlo.
4. Inhibe el salvapantallas/suspensión mientras el proceso corre, vía `systemd-inhibit`.
5. Ejecuta el comando que le pasás y espera a que termine.
6. Restaura el perfil que estaba activo antes, sea que el comando termine bien, falle, o se interrumpa (trap `EXIT`).

Uso en las opciones de lanzamiento de Steam (junto con GameMode, no en su lugar):

```
game-performance gamemoderun mangohud %command%
```

Uso manual en terminal (también sirve para Heroic o Lutris):

```
game-performance <comando> [argumentos...]
```

GameMode sigue siendo complementario: aporta prioridad de proceso, posible ajuste de GPU, y el indicador que MangoHud muestra en el overlay — cosas que `game-performance` no cubre.

---

## Recomendaciones que el script no automatiza

- **Activar Steam Play para todos los títulos**: Steam → Configuración → Compatibilidad → "Habilitar Steam Play para todos los demás títulos", y elegir ahí la versión de Proton (o una de ProtonPlus) por defecto.
- **CoreCtrl / LACT** (overclock, fan curves): deliberadamente no incluidos, mismo criterio que en los proyectos de Fedora.
- Si `apt upgrade` llegara a reinstalar el paquete `mangohud` de Debian y pisar el binario compilado, basta con volver a correr el script para recompilarlo.
