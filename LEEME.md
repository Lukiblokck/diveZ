# diveZ: Diver-Office en Linux, sin complicaciones

diveZ conecta tu lector **Diver USB** con **Diver-Office** (que corre con Wine). Detecta todo solo,
usa menos de 1 MB de memoria y se cierra cuando cierras Diver-Office.

## Instalar (sin usar la terminal)

1. Descomprime el zip.
2. En el gestor de archivos, haz clic derecho sobre `install.sh` y elige **Ejecutar** (o *Ejecutar en terminal*).
3. Si te pide una contraseña, es la de tu usuario: solo sirve para dar permiso al puerto USB.
4. Si el instalador dice que añadió tu usuario a un grupo, **cierra sesión y vuelve a entrar** una vez.

Necesitas tener **Wine** instalado y **Diver-Office** instalado dentro de Wine.

## Usar

1. Conecta la unidad Diver por USB.
2. Abre **diveZ** desde el menú de aplicaciones.
3. Se abre Diver-Office. En él, elige el puerto **COM9**.

Si algo falla, diveZ abre una página sencilla que te dice qué falta (lector desconectado, Wine no
encontrado, etc.) y te deja corregirlo. Puedes volver a abrirla en cualquier momento haciendo clic en
el icono de diveZ otra vez, o con *Ajustes y estado* (clic derecho sobre el icono).

## Dónde quedan tus datos

- `~/diveZ/captures`: copia en bruto de lo que envía la unidad (por si hace falta recuperarla).
- `~/diveZ/divez.log`: registro de la última ejecución (adjúntalo si pides ayuda).
- `~/.config/divez/config`: ajustes.

## Desinstalar

`./install.sh --uninstall` (tus datos se conservan).
