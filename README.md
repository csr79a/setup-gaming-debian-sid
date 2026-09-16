# setup-gaming-debian-sid

Script para dejar **Debian Sid (Unstable) / KDE Plasma** listo para jugar: instala Steam, ProtonPlus, Heroic Games Launcher (con auto-actualización), GameMode, MangoHud (compilado desde fuente con soporte NVML) + MangoJuice como GUI de configuración, herramientas de diagnóstico, y aplica ajustes del sistema recomendados para juegos modernos.

Equivalente a [`setup-gaming-fedora`](https://github.com/csr79a/setup-gaming-fedora), adaptado a las herramientas reales disponibles en Debian — complementario a [`debian-sid-setup`](https://github.com/csr79a/debian-sid-setup).

## Estructura

```
setup-gaming-debian-sid/
├── setup-gaming-debian-sid.sh   # Script principal
├── README.md
└── MANUAL.md                    # Explicación detallada de cada paso
```

## Qué hace `setup-gaming-debian-sid.sh`

0. Comprueba que los repos estén en formato deb822 apuntando a `unstable`/`testing` (necesario para compilar MangoHud más adelante); si no, pide confirmación antes de seguir
1. Instala **Steam** desde el `.deb` oficial de Valve (habilitando arquitectura i386 si hace falta)
2. Instala/actualiza **Flatpak** y configura el remoto **Flathub**
3. Instala/actualiza **ProtonPlus** vía Flatpak
4. Descarga automáticamente el último `.deb` de **Heroic Games Launcher** publicado en GitHub y lo instala/actualiza (compara versión instalada vs. disponible)
5. Instala **GameMode** vía `apt`, **compila MangoHud desde fuente con soporte NVML** (necesario para leer % de uso, VRAM y temperatura en GPUs NVIDIA — el paquete de Debian no lo trae) e instala **MangoJuice** vía Flatpak como GUI de configuración
6. En equipos con GPU NVIDIA, detecta el `pci_dev` correcto vía `nvidia-smi` y lo configura en `MangoHud.conf` (evita lecturas erróneas en gráficas híbridas)
7. Instala **mesa-utils** (`glxgears`, `glxinfo`) como herramientas rápidas de diagnóstico
8. Ajusta `vm.max_map_count` a un valor alto, recomendado por varios juegos/motores modernos
9. Verifica si el kernel soporta **ntsync** y lo activa (persistente en cada arranque) si es posible
10. Instala `power-profiles-daemon` si hace falta y agrega el wrapper **`game-performance`** (`/usr/local/bin/game-performance`), que activa el perfil de energía "performance" mientras corre el proceso que le pasás y restaura el perfil anterior al terminar

El script es **idempotente**: se puede correr varias veces sin romper nada, y de hecho está pensado para volver a correrse periódicamente (actualiza Heroic, ProtonPlus, MangoJuice y recompila MangoHud si hay un commit nuevo en upstream).

## Por qué esta combinación de apt / .deb / Flatpak / compilación

No es un criterio parejo por sistema, sino "la mejor fuente real para cada herramienta" en Debian:

| Herramienta | Fuente | Por qué |
|---|---|---|
| Steam | `.deb` oficial de Valve | Es la vía estándar en Debian/Ubuntu, no hay repo propio como RPM Fusion en Fedora |
| ProtonPlus | Flatpak | El propio proyecto indica que **Flathub es su método principal de instalación**; no existe paquete nativo para Debian |
| Heroic Games Launcher | `.deb` oficial, auto-descargado desde GitHub | Heroic publica un `.deb` oficial en cada release — mismo mecanismo de auto-actualización que se usa en el proyecto de Fedora (ahí con `.rpm`) |
| GameMode | `apt` (repos de Sid) | Va razonablemente al día en Debian Unstable, sin necesidad de nada externo |
| MangoHud | **Compilado desde fuente** (`meson`/`ninja`, con `-Dwith_nvml=enabled`) | El paquete `mangohud` de Debian es la build DFSG, compilada **sin soporte NVML**: en GPUs NVIDIA nunca muestra % de uso, VRAM ni temperatura. El script detecta esto, desinstala el paquete de apt si estaba presente, y compila la última versión de upstream con NVML habilitado |
| MangoJuice | Flatpak | GUI de configuración para MangoHud con permisos correctos de fábrica hacia `~/.config/MangoHud`, sin necesitar `flatpak override` |
| mesa-utils | `apt` | Herramientas de diagnóstico estándar (`glxgears`, `glxinfo`) para probar drivers/MangoHud sin abrir un juego |

## Uso rápido

```
git clone https://github.com/csr79a/setup-gaming-debian-sid.git
cd setup-gaming-debian-sid

chmod +x setup-gaming-debian-sid.sh
./setup-gaming-debian-sid.sh
```

Ver `MANUAL.md` para el detalle de cada paso.
